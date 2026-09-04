#!/usr/bin/env bash
# remote-harness / inject-rule.sh — RUN WHERE THE AGENT LAUNCHES.
# The launched agent works in an sshfs mount of the project host's code. This machine may lack that
# project's toolchain/runtime, so this injects a session rule: run builds/tests/linters/installs on
# the project host reached by the supplied SSH alias. The rule is SCOPED TO THIS SESSION/PROJECT (no
# global instructions file → other sessions are unaffected). Per agent it uses that CLI's cleanest
# scoped channel:
#   claude   → --append-system-prompt-file <rule>   (session-only flag; nothing on disk to clean up
#              beyond the box-side rule file; never touches the mounted repo)
#   opencode → OPENCODE_CONFIG=<session config: instructions[+permission=allow if yolo]>  (env;
#              never touches the mounted repo)
#   codex    → -c developer_instructions=<rule>  (session-only CLI config; avoids changing
#              CODEX_HOME, because modern Codex can store ChatGPT credentials in an encrypted
#              keyring keyed by the real home and would prompt for login under a synthetic home).
#              Also passes `-s workspace-write -c sandbox_workspace_write.network_access=true` and
#              a writable root for the session-owned ~/.remote-harness/.sessions dirs because codex's
#              default sandbox blocks network and otherwise prevents ssh from writing its temp
#              known_hosts there. It never makes ~/.ssh writable.
#              The project's own AGENTS.md is still read additively; the mounted repo is never touched.
#
#   inject-rule.sh on  <agent> <project_path_on_host> <host_alias> <mountpoint> [yolo:0|1] [ssh_config]
#   inject-rule.sh off <agent> <mountpoint>
#
# 'on'  prints: RH_STATUS=INJECTED  RH_LAUNCH_ENV=<env prefix>  RH_LAUNCH_FLAGS=<trailing flags>
# 'off' prints: RH_STATUS=RESTORED | NOOP        (RH_STATUS=ERROR on failure)
# Per-session artifacts live under $RH_HOME/.sessions/<key> on the agent machine (key derived from
# mountpoint), so 'on'/'off' agree without extra state and concurrent harness sessions don't clash.
set -uo pipefail

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)"

safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

session_dir() {  # $1 = mountpoint (session key) -> box-side per-session dir
  key="$(printf '%s' "${1:-default}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  case "$key" in ""|.|..) key=default;; esac   # never let the key escape $RH_HOME/.sessions/ (e.g. "..")
  printf '%s/.sessions/%s' "${RH_HOME:-$HOME/.remote-harness}" "$key"
}

# Emit a few concrete example commands (one per line) for the project at $1 (mountpoint), by
# sniffing its manifest files. Falls back to generic placeholders if the stack is unknown.
detect_cmds() {
  m="$1"
  if   [ -n "$m" ] && [ -f "$m/package.json" ]; then
    pm=npm
    [ -f "$m/yarn.lock" ]      && pm=yarn
    [ -f "$m/pnpm-lock.yaml" ] && pm=pnpm
    [ -f "$m/bun.lockb" ]      && pm=bun
    printf '%s install\n%s run build\n%s test\n%s run lint\n%s run format\n' "$pm" "$pm" "$pm" "$pm" "$pm"
  elif [ -n "$m" ] && [ -f "$m/Cargo.toml" ]; then
    printf 'cargo build\ncargo test\ncargo run\ncargo clippy\ncargo fmt --check\n'
  elif [ -n "$m" ] && [ -f "$m/go.mod" ]; then
    printf 'go build ./...\ngo test ./...\ngo vet ./...\ngofmt -l .\n'
  elif [ -n "$m" ] && { [ -f "$m/pyproject.toml" ] || [ -f "$m/requirements.txt" ] || [ -f "$m/setup.py" ]; }; then
    if [ -f "$m/requirements.txt" ]; then printf 'pip install -r requirements.txt\n'; else printf 'pip install -e .\n'; fi
    printf 'pytest\n'
    { [ -f "$m/ruff.toml" ] || [ -f "$m/.ruff.toml" ] || grep -qs 'ruff' "$m/pyproject.toml" 2>/dev/null; } && printf 'ruff check .\n' || true
    [ -f "$m/mypy.ini" ] || grep -qsE '\[(tool\.)?mypy\]' "$m/setup.cfg" "$m/pyproject.toml" 2>/dev/null && printf 'mypy .\n' || true
  elif [ -n "$m" ] && [ -f "$m/pom.xml" ]; then
    if [ -f "$m/mvnw" ]; then mvn=./mvnw; else mvn=mvn; fi
    printf '%s -q compile\n%s test\n%s package\n' "$mvn" "$mvn" "$mvn"
  elif [ -n "$m" ] && { [ -f "$m/build.gradle" ] || [ -f "$m/build.gradle.kts" ] || [ -f "$m/settings.gradle" ] || [ -f "$m/settings.gradle.kts" ]; }; then
    if [ -f "$m/gradlew" ]; then gr=./gradlew; else gr=gradle; fi
    printf '%s build\n%s test\n%s run\n' "$gr" "$gr" "$gr"
  elif [ -n "$m" ] && { ls "$m"/*.sln >/dev/null 2>&1 || ls "$m"/*.csproj >/dev/null 2>&1; }; then
    printf 'dotnet restore\ndotnet build\ndotnet test\n'
  elif [ -n "$m" ] && [ -f "$m/Gemfile" ]; then
    printf 'bundle install\nbundle exec rake test\n'
  elif [ -n "$m" ] && { [ -f "$m/Makefile" ] || [ -f "$m/makefile" ]; }; then
    printf 'make\nmake test\n'
  else
    printf '<install deps>\n<build>\n<test>\n'
  fi
}

toml_basic_string_file() {
  awk '
    BEGIN { printf "\"" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      printf "%s%s", sep, $0
      sep="\\n"
    }
    END { printf "\"" }
  ' "$1"
}

toml_escape_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

codex_writable_roots_cfg() {
  _cwr_ssh_config="${1:-}"
  [ -n "$_cwr_ssh_config" ] || return 1
  _cwr_runtime_dir="$(dirname "$_cwr_ssh_config" 2>/dev/null)/runtime"
  mkdir -p "$_cwr_runtime_dir" 2>/dev/null || return 1
  chmod 700 "$_cwr_runtime_dir" 2>/dev/null || true
  printf 'sandbox_workspace_write.writable_roots=["%s"]' "$(toml_escape_value "$_cwr_runtime_dir")"
}

write_ssh_wrapper() {  # $1=session dir  $2=alias  $3=ssh config path
  sd="$1"; alias_name="$2"; cfg="$3"
  safe_ssh_token "$alias_name" || return 1
  case "$cfg" in ""|*'
'*) return 1;; esac
  real_ssh="$(command -v ssh 2>/dev/null || true)"
  [ -n "$real_ssh" ] || return 1
  bin="$sd/bin"
  mkdir -p "$bin" 2>/dev/null || return 1
  wrapper="$bin/ssh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'real_ssh=%s\n' "$(sq "$real_ssh")"
    printf 'alias_name=%s\n' "$(sq "$alias_name")"
    printf 'cfg=%s\n' "$(sq "$cfg")"
    printf 'need_value=0\n'
    printf 'target=""\n'
    printf 'for arg in "$@"; do\n'
    printf '  if [ "$need_value" = 1 ]; then need_value=0; continue; fi\n'
    printf '  case "$arg" in\n'
    printf '    -F|-F*) exec "$real_ssh" "$@" ;;\n'
    printf '    -b|-c|-D|-E|-e|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w) need_value=1; continue ;;\n'
    printf '    -b*|-c*|-D*|-E*|-e*|-I*|-i*|-J*|-L*|-l*|-m*|-O*|-o*|-p*|-Q*|-R*|-S*|-W*|-w*) continue ;;\n'
    printf '    -*) continue ;;\n'
    printf '    *) target="$arg"; break ;;\n'
    printf '  esac\n'
    printf 'done\n'
    printf 'if [ "$target" = "$alias_name" ]; then\n'
    printf '  exec "$real_ssh" -F "$cfg" "$@"\n'
    printf 'fi\n'
    printf 'exec "$real_ssh" "$@"\n'
  } > "$wrapper" || return 1
  chmod +x "$wrapper" 2>/dev/null || return 1
  return 0
}

write_session_runner() {  # $1=session dir $2=alias $3=project root $4=ssh config
  _wsr_runner="$1/bin/rh-run"
  mkdir -p "$1/bin" 2>/dev/null || return 1
  {
    printf '#!/usr/bin/env sh\n'
    printf 'exec %s --ssh-config %s --alias %s --project-root %s --cwd-relative-b64 "${1:?}" --command-b64 "${2:?}"\n' \
      "$(sq "$SCRIPT_DIR/run-on-project-host.sh")" "$(sq "$4")" "$(sq "$2")" "$(sq "$3")"
  } > "$_wsr_runner" || return 1
  chmod +x "$_wsr_runner" 2>/dev/null || return 1
  printf '%s' "$_wsr_runner"
}

write_claude_worktree_blocker() {  # $1=session dir
  _wcw_blocker="$1/bin/deny-worktree"
  mkdir -p "$1/bin" 2>/dev/null || return 1
  {
    printf '#!/usr/bin/env sh\n'
    printf 'printf %s >&2\n' "$(sq 'remote-harness: Claude worktrees are unavailable in an SSHFS session; use a separate remote-harness session for isolated parallel work.\n')"
    printf 'exit 2\n'
  } > "$_wcw_blocker" || return 1
  chmod +x "$_wcw_blocker" 2>/dev/null || return 1
  printf '%s' "$_wcw_blocker"
}

write_claude_settings() {  # $1=outfile $2=tool hook command $3=worktree blocker
  _wcs_command=$("$PYTHON3" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2") || return 1
  _wcs_worktree=$("$PYTHON3" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$(sq "$3")") || return 1
  cat > "$1" <<EOF
{
  "permissions": {
    "deny": ["EnterWorktree", "ExitWorktree"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Agent",
        "hooks": [
          {
            "type": "command",
            "command": $_wcs_command,
            "timeout": 5
          }
        ]
      }
    ],
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": $_wcs_worktree,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
}

write_rule() {  # $1=outfile $2=code path $3=host alias $4=mountpoint $5=agent
  cmds="$(detect_cmds "$4")"
  lpq="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"   # path with single quotes escaped, for the 'cd ...' examples
  if [ "${5:-}" = opencode ]; then
    {
      printf '# IMPORTANT - Remote dev harness rule\n\n'
      printf 'This working directory is an SSHFS mount of `%s` on `%s`.\n' "$2" "$3"
      printf 'File reads and edits may use the mount, but project commands must run on `%s`:\n\n' "$3"
      printf '    ssh %s '\''cd %s && <command>'\''\n\n' "$3" "$lpq"
      printf 'Do not install dependencies, build, test, format, lint, or mutate Git on this machine.\n'
    } > "$1"
    return
  fi
  {
    printf '# IMPORTANT - Remote dev harness strict routing rule\n\n'
    printf 'Your working directory is an SSHFS mount of `%s` on `%s`. File tools operate on the\n' "$2" "$3"
    printf 'mount, while a session `PreToolUse` hook routes every Bash command to `%s`.\n\n' "$3"
    printf 'Run ordinary relative commands. Do not wrap them in `ssh`, and do not replace the routing\n'
    printf 'runner. The hook maps the current mount-relative directory to the project host. Examples:\n\n'
    printf '%s\n' "$cmds" | while IFS= read -r c; do
      [ -n "$c" ] && printf '    %s\n' "$c"
    done
    printf '\n'
    printf 'All Git commands are routed too, with `GIT_OPTIONAL_LOCKS=0` to avoid SSHFS index refreshes.\n'
    printf 'Use relative project paths in Bash commands; absolute mount paths name the agent host and\n'
    printf 'are not portable to `%s`. Interactive PTY commands are not supported by strict routing.\n\n' "$3"
    printf 'Safe local work is file-oriented: use the agent read/edit/write/patch tools on the mount.\n'
    printf 'If routing is unavailable or the cwd is outside the mount, the Bash call is denied. Never\n'
    printf 'work around that failure by executing the project command on this machine.\n'
    if [ "${5:-}" = claude ]; then
      printf '\nClaude ordinary and nested subagents are supported and inherit this session hook.\n'
      printf 'Agent Teams are disabled because independent teammate sessions do not have a documented\n'
      printf 'guarantee that temporary `--settings` hooks are inherited. Do not request Agent\n'
      printf '`isolation: worktree`; use a separate remote-harness session for isolated parallel work.\n'
    fi
  } > "$1"
}

case "${1:-}" in
  on)
    agent="${2:-}"; lp="${3:-}"; ba="${4:-}"; mp="${5:-}"; yolo="${6:-0}"; ssh_config="${7:-}"
    case "$agent" in claude|codex|opencode) ;; *) echo "RH_STATUS=ERROR"; exit 2;; esac
    [ -n "$lp" ] && [ -n "$ba" ] || { echo "RH_STATUS=ERROR"; exit 2; }
    SD="$(session_dir "$mp")"
    rm -rf "$SD" 2>/dev/null || true
    mkdir -p "$SD" 2>/dev/null || { echo "RH_STATUS=ERROR"; exit 1; }
    RULE="$SD/rule.md"
    write_rule "$RULE" "$lp" "$ba" "$mp" "$agent" || { echo "RH_STATUS=ERROR"; exit 1; }

    env_out=""; flags_out=""
    if [ -n "$ssh_config" ]; then
      if write_ssh_wrapper "$SD" "$ba" "$ssh_config"; then
        env_out="PATH=$(sq "$SD/bin"):\$PATH"
      fi
    fi
    if [ "$agent" = claude ] || [ "$agent" = codex ]; then
      [ -n "$ssh_config" ] && [ -f "$ssh_config" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      PYTHON3=$(command -v python3 2>/dev/null || true)
      [ -n "$PYTHON3" ] && [ -x "$PYTHON3" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      [ -x "$SCRIPT_DIR/route-command.py" ] && [ -x "$SCRIPT_DIR/run-on-project-host.sh" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      runner=$(write_session_runner "$SD" "$ba" "$lp" "$ssh_config") \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      hook_command="$(sq "$PYTHON3") $(sq "$SCRIPT_DIR/route-command.py") --runner $(sq "$runner") --mount-root $(sq "$mp")"
    fi
    case "$agent" in
      claude)
        CLAUDE_SETTINGS="$SD/claude-settings.json"
        worktree_blocker=$(write_claude_worktree_blocker "$SD") \
          || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
        write_claude_settings "$CLAUDE_SETTINGS" "$hook_command" "$worktree_blocker" \
          || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
        env_out="${env_out:+$env_out }CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0"
        flags_out="--append-system-prompt-file $(sq "$RULE") --settings $(sq "$CLAUDE_SETTINGS")"
        ;;
      opencode)
        # OPENCODE_CONFIG is merged ADDITIVELY on top of the user's global + project configs, so we
        # only write a minimal session layer (instructions + permission on yolo). No jq, no copying
        # the user's config — that avoided a crash on a non-array `instructions` and a stale config
        # snapshot overriding a project-local opencode.json.
        CFG="$SD/opencode.json"
        [ "$yolo" = 1 ] && perm='"permission": "allow", ' || perm=''
        # JSON-escape the rule path: escape \ then " (both legal in Unix paths; rare but correct).
        rule_json="$(printf '%s' "$RULE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{ "$schema": "https://opencode.ai/config.json", %s"instructions": ["%s"] }\n' "$perm" "$rule_json" > "$CFG"
        env_out="${env_out:+$env_out }OPENCODE_CONFIG=$(sq "$CFG")"
        ;;
      codex)
        dev_cfg="developer_instructions=$(toml_basic_string_file "$RULE")"
        hook_cfg="hooks.PreToolUse=[{matcher=\"^Bash\$\",hooks=[{type=\"command\",command=\"$(toml_escape_value "$hook_command")\",timeout=5,statusMessage=\"Routing command to project host\"}]}]"
        flags_out="-c $(sq "$dev_cfg") -c $(sq "$hook_cfg") --dangerously-bypass-hook-trust"
        # codex's default sandbox gates network, which blocks the rule's `ssh <host> ...`. The
        # `[sandbox_workspace_write]` sub-table only merges when workspace-write is EXPLICITLY
        # selected, so `-s workspace-write` is required — `network_access` alone at the implicit
        # default is IGNORED. Under --yolo, --dangerously-bypass-approvals-and-sandbox already drops
        # the sandbox entirely, so DON'T add -s there (it would conflict).
        # workspace-write needs explicit network access for the rule's `ssh <host> ...`, plus write
        # access to the session-owned directories where the wrapper/config put temporary known_hosts.
        # Do not add ~/.ssh; user SSH files remain read-only/user-managed.
        if [ "$yolo" != 1 ]; then
          roots_cfg="$(codex_writable_roots_cfg "$ssh_config")" \
            || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
          flags_out="$flags_out -s workspace-write -c sandbox_workspace_write.network_access=true -c $(sq "$roots_cfg")"
        fi
        ;;
    esac
    printf 'RH_STATUS=INJECTED\n'
    printf 'RH_LAUNCH_ENV=%s\n'   "$env_out"
    printf 'RH_LAUNCH_FLAGS=%s\n' "$flags_out"
    ;;
  off)
    mp="${3:-}"; SD="$(session_dir "$mp")"
    # All agents' artifacts (the rule file, and for opencode its session config) live in the session
    # dir; none of them touched the mounted repo — so cleanup is just removing that dir.
    if [ -d "$SD" ]; then
      rm -rf "$SD" 2>/dev/null && echo "RH_STATUS=RESTORED" || echo "RH_STATUS=ERROR"
    else
      echo "RH_STATUS=NOOP"
    fi
    ;;
  *)
    echo "usage: inject-rule.sh on <agent> <laptop_path> <box_alias> <box_mountpoint> [yolo] | off <agent> <box_mountpoint>" >&2
    echo "RH_STATUS=ERROR"; exit 2;;
esac
