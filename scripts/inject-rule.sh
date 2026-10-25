#!/usr/bin/env bash
# remote-harness / inject-rule.sh — RUN WHERE THE AGENT LAUNCHES.
# The launched agent works in an sshfs mount of the project host's code. This machine may lack that
# project's toolchain/runtime, so this injects a session rule: run builds/tests/linters/installs on
# the project host reached by the supplied SSH alias. The rule is SCOPED TO THIS SESSION/PROJECT (no
# global instructions file → other sessions are unaffected). Per agent it uses that CLI's cleanest
# scoped channel:
#   claude   → --append-system-prompt-file <rule>   (session-only flag; nothing on disk to clean up
#              beyond the box-side rule file; never touches the mounted repo)
#   opencode → OPENCODE_CONFIG=<session config with instructions and tool hook plugin>
#              (env; never touches the mounted repo)
#   codex    → -c developer_instructions=<rule>  (session-only CLI config; avoids changing
#              CODEX_HOME, because modern Codex can store ChatGPT credentials in an encrypted
#              keyring keyed by the real home and would prompt for login under a synthetic home).
#              Also passes `-s workspace-write -c sandbox_workspace_write.network_access=true` and
#              a writable root for the session-owned ~/.remote-harness/.sessions dirs because codex's
#              default sandbox blocks network and otherwise prevents ssh from writing its temp
#              known_hosts there. It never makes ~/.ssh writable.
#              The project's own AGENTS.md is still read additively; the mounted repo is never touched.
#
#   inject-rule.sh on  <agent> <project_path_on_host> <host_alias> <mountpoint> [approval] [ssh_config] [session_id]
#              approval: 0|normal, 1|yolo, or auto = the agent's automatic approval review when this CLI
#              supports it (claude --permission-mode auto, codex --approve-for-me), else normal.
#   inject-rule.sh off <agent> <mountpoint> [session_id]
#
# 'on'  prints: RH_STATUS=INJECTED  RH_LAUNCH_ENV=<env prefix>  RH_LAUNCH_FLAGS=<trailing flags>
#               RH_APPROVAL=<normal|auto|yolo> (the approval mode the flags actually select)
#               RH_RESUME_AVAILABLE=<reason>,<epoch> when the last session of this mountpoint and
#               agent ended on a lost connection (offered once; the marker is consumed), and
#               RH_RESUME_ARGS=<agent arguments that continue the last conversation>
#               RH_READY_FILE=<opencode marker>  RH_LAUNCH_PREFIX=<session launcher for the final launch>
# 'off' prints: RH_STATUS=RESTORED | NOOP        (RH_STATUS=ERROR on failure)
# Per-session artifacts live under $RH_HOME/.sessions/<key> on the agent machine. The key is derived
# from the mountpoint plus the caller's session_id, so 'on'/'off' agree without extra state, and a
# second launch (or a stale launch's cleanup) for the same mountpoint never deletes the hook/runner of
# a session that is still running. Without session_id the key is the mountpoint alone (legacy).
set -uo pipefail

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)"

safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

valid_session_id() {
  case "${1:-}" in
    ""|.|..|*[!A-Za-z0-9._-]*) return 1;;
    *) return 0;;
  esac
}

session_dir() {  # $1 = mountpoint, $2 = optional session id -> box-side per-session dir
  key="$(printf '%s' "${1:-default}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  case "$key" in ""|.|..) key=default;; esac   # never let the key escape $RH_HOME/.sessions/ (e.g. "..")
  [ -z "${2:-}" ] || key="$key.$2"
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

write_session_runner() {  # $1=session dir $2=alias $3=project root $4=ssh config $5=control path $6=python3
  _wsr_runner="$1/bin/rh-run"
  _wsr_mux=""
  [ -z "${5:-}" ] || _wsr_mux=" --control-path $(sq "$5")"
  # With python3, channel-guard.py holds the SSH channel open for the command's lifetime so the
  # project host stops the command tree when this call is cancelled or the connection drops.
  _wsr_guard=""
  if [ -n "${6:-}" ] && [ -f "$SCRIPT_DIR/channel-guard.py" ]; then
    _wsr_guard="$(sq "$6") -I $(sq "$SCRIPT_DIR/channel-guard.py") -- "
    _wsr_mux="$_wsr_mux --watch"
  fi
  mkdir -p "$1/bin" 2>/dev/null || return 1
  {
    printf '#!/usr/bin/env sh\n'
    printf 'exec %s%s --ssh-config %s --alias %s --project-root %s%s --cwd-relative-b64 "${1:?}" --command-b64 "${2:?}"\n' \
      "$_wsr_guard" "$(sq "$SCRIPT_DIR/run-on-project-host.sh")" "$(sq "$4")" "$(sq "$2")" "$(sq "$3")" "$_wsr_mux"
  } > "$_wsr_runner" || return 1
  chmod +x "$_wsr_runner" 2>/dev/null || return 1
  printf '%s' "$_wsr_runner"
}

b64_value() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Short, token-free multiplexing socket beside the session SSH runtime (already the Codex writable
# root). Empty when the path would exceed the Unix socket limit; callers then connect directly.
session_control_path() {  # $1=ssh config
  _scp_runtime="$(dirname "$1" 2>/dev/null)/runtime"
  mkdir -p "$_scp_runtime" 2>/dev/null || return 0
  chmod 700 "$_scp_runtime" 2>/dev/null || true
  _scp_path="$_scp_runtime/mux"
  case "$_scp_path" in /*) ;; *) return 0;; esac
  case "$_scp_path" in *[!A-Za-z0-9._/-]*) return 0;; esac
  [ "${#_scp_path}" -le 86 ] || return 0
  printf '%s' "$_scp_path"
}

# Session metadata for session-reaper.sh (values base64-encoded; never sourced or evaluated).
write_session_meta() {  # $1=session dir $2=agent $3=mountpoint $4=alias $5=ssh config $6=control path
  {
    printf 'AGENT=%s\n' "$(b64_value "$2")"
    if [ -n "${SESSION_LEASE:-}" ]; then
      printf 'MOUNTPOINT=%s\n' "$(sed -n 's/^MOUNTPOINT=//p' "$SESSION_LEASE/lease.env")"
    else
      printf 'MOUNTPOINT=%s\n' "$(b64_value "$3")"
    fi
    printf 'ALIAS=%s\n' "$(b64_value "$4")"
    printf 'SSH_CONFIG=%s\n' "$(b64_value "$5")"
    printf 'CONTROL_PATH=%s\n' "$(b64_value "$6")"
    if [ -n "${SESSION_LEASE:-}" ]; then
      printf 'LEASE_DIR=%s\n' "$(b64_value "$SESSION_LEASE")"
      printf 'MOUNT_SSH_CONFIG=%s\n' "$(sed -n 's/^MOUNT_SSH_CONFIG=//p' "$SESSION_LEASE/lease.env")"
    fi
  } > "$1/session.env" || return 1
  chmod 600 "$1/session.env" 2>/dev/null || true
}

# Session launcher: records the agent's pid/start time/terminal, starts the detached server-side
# watcher, then execs the agent (same pid). Used only for the final interactive launch.
write_session_launcher() {  # $1=session dir
  _wsl_launcher="$1/bin/rh-session"
  mkdir -p "$1/bin" 2>/dev/null || return 1
  {
    printf '#!/usr/bin/env sh\n'
    printf 'sd=%s\n' "$(sq "$1")"
    printf 'reaper=%s\n' "$(sq "$SCRIPT_DIR/session-reaper.sh")"
    printf 'rh_home=%s\n' "$(sq "${RH_HOME:-$HOME/.remote-harness}")"
    printf 'lease=%s\n' "$(sq "${SESSION_LEASE:-}")"
    cat <<'EOS'
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
start=$(ps -p "$$" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
term=$(tty 2>/dev/null) || term=""
if [ -d "$sd" ]; then
  printf 'OWNER_PID=%s\nOWNER_START=%s\nOWNER_TTY=%s\n' "$$" "$(b64 "$start")" "$(b64 "$term")" \
    > "$sd/owner.env.tmp" && mv "$sd/owner.env.tmp" "$sd/owner.env"
  if [ -n "$lease" ] && [ -d "$lease" ]; then
    cp "$sd/owner.env" "$lease/owner.env.tmp" && mv "$lease/owner.env.tmp" "$lease/owner.env"
  fi
  if [ -x "$reaper" ]; then
    if command -v setsid >/dev/null 2>&1; then
      RH_HOME="$rh_home" setsid "$reaper" watch "$sd" </dev/null >/dev/null 2>&1 &
    else
      RH_HOME="$rh_home" nohup "$reaper" watch "$sd" </dev/null >/dev/null 2>&1 &
    fi
  fi
fi
exec "$@"
EOS
  } > "$_wsl_launcher" || return 1
  chmod +x "$_wsl_launcher" 2>/dev/null || return 1
  printf '%s' "$_wsl_launcher"
}

# PATH shims that send IO-heavy git/rg work-tree scans to the project host (project-host-tool.py).
write_tool_shim() {  # $1=session dir $2=tool $3=real tool $4=alias $5=project root $6=mountpoint $7=ssh config $8=control path [$9=real argv0]
  _wts_shim="$1/bin/$2"
  _wts_slots="$(dirname "$7" 2>/dev/null)/runtime/tool-slots"
  mkdir -p "$1/bin" 2>/dev/null || return 1
  {
    printf '#!/usr/bin/env sh\n'
    printf 'exec %s -I %s --tool %s --real %s --real-argv0 %s --runner %s --ssh-config %s --alias %s --project-root %s --mount-root %s --control-path %s --slots-dir %s --concurrency %s -- "$@"\n' \
      "$(sq "$PYTHON3")" "$(sq "$SCRIPT_DIR/project-host-tool.py")" "$2" "$(sq "$3")" "$(sq "${9:-}")" \
      "$(sq "$SCRIPT_DIR/run-on-project-host.sh")" "$(sq "$7")" "$(sq "$4")" "$(sq "$5")" \
      "$(sq "$6")" "$(sq "$8")" "$(sq "$_wts_slots")" "$(sq "${RH_TOOL_CONCURRENCY:-6}")"
  } > "$_wts_shim" || return 1
  chmod +x "$_wts_shim" 2>/dev/null || return 1
}

write_opencode_plugin() {  # $1=session dir $2=runner $3=mountpoint $4=ready marker
  _wop_dir="$1/plugins"
  _wop_file="$_wop_dir/remote-harness.js"
  _wop_runner_b64="$(printf '%s' "$2" | base64 | tr -d '\n')" || return 1
  _wop_mount_b64="$(printf '%s' "$3" | base64 | tr -d '\n')" || return 1
  _wop_ready_b64="$(printf '%s' "$4" | base64 | tr -d '\n')" || return 1
  mkdir -p "$_wop_dir" 2>/dev/null || return 1
  cat > "$_wop_file" <<EOF
import fs from "node:fs"
import path from "node:path"

const runner = Buffer.from("$_wop_runner_b64", "base64").toString("utf8")
const configuredMount = Buffer.from("$_wop_mount_b64", "base64").toString("utf8")
const readyFile = Buffer.from("$_wop_ready_b64", "base64").toString("utf8")
const mountRoot = fs.realpathSync(configuredMount)

const encode = (value) => Buffer.from(value, "utf8").toString("base64")
const apostrophe = String.fromCharCode(39)
const doubleQuote = String.fromCharCode(34)
const shellQuote = (value) =>
  apostrophe +
  value.split(apostrophe).join(apostrophe + doubleQuote + apostrophe + doubleQuote + apostrophe) +
  apostrophe

export const RemoteHarness = async ({ directory }) => {
  fs.writeFileSync(readyFile, String(process.pid) + "\\n", { mode: 0o600 })
  return {
    "tool.execute.before": async (input, output) => {
      if (String(input.tool).toLowerCase() !== "bash") return
      const command = output.args?.command
      if (typeof command !== "string" || command.trim() === "") {
        throw new Error("remote-harness: opencode Bash input has no command")
      }

      const requested = output.args.workdir || directory || mountRoot
      const candidate = path.resolve(directory || mountRoot, requested)
      let cwd
      try {
        cwd = fs.realpathSync(candidate)
      } catch {
        throw new Error("remote-harness: opencode working directory is unavailable")
      }
      const relative = path.relative(mountRoot, cwd)
      if (relative === ".." || relative.startsWith(".." + path.sep) || path.isAbsolute(relative)) {
        throw new Error("remote-harness: denied an opencode Bash command outside the SSHFS mount")
      }

      output.args.command = [runner, encode(relative || "."), encode(command)]
        .map(shellQuote)
        .join(" ")
      output.args.workdir = mountRoot
    },
  }
}
EOF
  chmod 600 "$_wop_file" 2>/dev/null || true
  printf '%s' "$_wop_file"
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
  {
    printf '# IMPORTANT - Remote dev harness strict routing rule\n\n'
    # laptop-setup.sh passes RH_LANG=zh for a Chinese session (normalized by _common.sh is_zh).
    if [ "${RH_LANG:-}" = zh ]; then
      printf 'Always reply to the user in Simplified Chinese (简体中文), even though these instructions,\n'
      printf 'tool output, and project files are in English. Keep code, commands, paths, identifiers, and\n'
      printf 'quoted output unchanged.\n\n'
    fi
    printf 'Your working directory is an SSHFS mount of `%s` on `%s`. File tools operate on the\n' "$2" "$3"
    printf 'mount, while a session router sends every Bash command to `%s`.\n\n' "$3"
    printf 'Run ordinary relative commands. Do not wrap them in `ssh`, and do not replace the routing\n'
    printf 'runner. The router maps the current mount-relative directory to the project host. Examples:\n\n'
    printf '%s\n' "$cmds" | while IFS= read -r c; do
      [ -n "$c" ] && printf '    %s\n' "$c"
    done
    printf '\n'
    printf 'Git commands you run through the Bash tool are routed with the rest of the command. Git\n'
    printf 'and ripgrep calls that the agent makes internally (status snapshots, file search) go through\n'
    printf 'session shims: work-tree scans and read-only lookups such as `git rev-parse` run on `%s`;\n' "$3"
    printf 'git calls that write stay on this host. If such a call reports that the project host is\n'
    printf 'unreachable, do not retry it against the mount with another tool; report the connection\n'
    printf 'problem instead.\n'
    printf 'Use relative project paths in Bash commands; absolute mount paths name the agent host and\n'
    printf 'are not portable to `%s`. Interactive PTY commands are not supported by strict routing.\n' "$3"
    printf 'Commands read stdin from /dev/null. Stopping a command, its timeout, or the end of this\n'
    printf 'session stops its whole process tree on `%s`, including background tasks.\n\n' "$3"
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
    agent="${2:-}"; lp="${3:-}"; ba="${4:-}"; mp="${5:-}"; approval="${6:-0}"; ssh_config="${7:-}"; sid="${8:-}"
    case "$agent" in claude|codex|opencode) ;; *) echo "RH_STATUS=ERROR"; exit 2;; esac
    case "$approval" in 1|yolo) yolo=1; approval=yolo;; auto) yolo=0;; *) yolo=0; approval=normal;; esac
    [ -n "$lp" ] && [ -n "$ba" ] || { echo "RH_STATUS=ERROR"; exit 2; }
    [ -z "$sid" ] || valid_session_id "$sid" || { echo "RH_STATUS=ERROR"; exit 2; }
    SD="$(session_dir "$mp" "$sid")"
    # Reap sessions whose launcher died without cleanup (detached; never delays this launch).
    if [ -x "$SCRIPT_DIR/session-reaper.sh" ]; then
      if command -v setsid >/dev/null 2>&1; then
        setsid "$SCRIPT_DIR/session-reaper.sh" gc </dev/null >/dev/null 2>&1 &
      else
        nohup "$SCRIPT_DIR/session-reaper.sh" gc </dev/null >/dev/null 2>&1 &
      fi
    fi
    if [ -f "$SD/session.env" ]; then
      echo 'RH_STATUS=ERROR'
      printf 'remote-harness: refusing to overwrite an existing session\n' >&2
      exit 1
    fi
    mkdir -p "$SD" 2>/dev/null || { echo "RH_STATUS=ERROR"; exit 1; }
    SESSION_LEASE=""
    if [ -n "$sid" ] && [ -f "${RH_HOME:-$HOME/.remote-harness}/.sessions/lease.$sid/lease.env" ]; then
      SESSION_LEASE="${RH_HOME:-$HOME/.remote-harness}/.sessions/lease.$sid"
    fi
    # Generated entry points only reference this per-session implementation snapshot. Mutable
    # SSH sockets/known_hosts remain under the separate config runtime, outside this directory.
    source_scripts="$SCRIPT_DIR"
    mkdir "$SD/impl" || { echo RH_STATUS=ERROR; exit 1; }
    for impl_file in inject-rule.sh _common.sh route-command.py channel-guard.py run-on-project-host.sh project-host-tool.py session-reaper.sh mount-project.sh; do
      cp "$source_scripts/$impl_file" "$SD/impl/$impl_file" || { rm -rf "$SD"; echo RH_STATUS=ERROR; exit 1; }
      chmod 500 "$SD/impl/$impl_file" || { echo RH_STATUS=ERROR; exit 1; }
    done
    SCRIPT_DIR="$SD/impl"
    if [ -n "$SESSION_LEASE" ]; then
      RH_REAPER_LIBRARY=1 . "$SCRIPT_DIR/session-reaper.sh" || { echo RH_STATUS=ERROR; exit 1; }
      unset RH_REAPER_LIBRARY
      resource_lock || { echo RH_STATUS=ERROR; exit 1; }
      mount_meta=$(mount_record "$(kv_b64 "$SESSION_LEASE/lease.env" MOUNTPOINT)")
      if [ -f "$mount_meta" ] && [ -z "$(kv_b64 "$mount_meta" IMPLEMENTATION)" ]; then
        printf 'IMPLEMENTATION=%s\n' "$(b64_value "$SD/impl")" >> "$mount_meta"
      fi
      resource_unlock
    fi
    RULE="$SD/rule.md"

    env_out=""; flags_out=""; ready_file=""; prefix_out=""; control_path=""
    [ -z "$ssh_config" ] || control_path="$(session_control_path "$ssh_config")"
    write_session_meta "$SD" "$agent" "$mp" "$ba" "$ssh_config" "$control_path" \
      || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
    write_rule "$RULE" "$lp" "$ba" "$mp" "$agent" || { echo "RH_STATUS=ERROR"; exit 1; }
    if [ -n "$ssh_config" ]; then
      if write_ssh_wrapper "$SD" "$ba" "$ssh_config"; then
        env_out="PATH=$(sq "$SD/bin"):\$PATH"
      fi
    fi
    if [ "$agent" = claude ] || [ "$agent" = codex ] || [ "$agent" = opencode ]; then
      [ -n "$ssh_config" ] && [ -f "$ssh_config" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      [ -x "$SCRIPT_DIR/run-on-project-host.sh" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      # Command guard and tool shims need python3 on this host; without it, routed commands are not
      # watched and git/rg simply keep their SSHFS behavior.
      PYTHON3=$(command -v python3 2>/dev/null || true)
      runner=$(write_session_runner "$SD" "$ba" "$lp" "$ssh_config" "$control_path" "$PYTHON3") \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      launcher=$(write_session_launcher "$SD") \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      prefix_out="$(sq "$launcher")"
      rg_shim=0
      if [ -n "$PYTHON3" ] && [ -f "$SCRIPT_DIR/project-host-tool.py" ]; then
        real_git=$(command -v git 2>/dev/null || true)
        write_tool_shim "$SD" git "$real_git" "$ba" "$lp" "$mp" "$ssh_config" "$control_path" \
          || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
        # Only shim rg when a real one exists here, so calls outside the project keep working. A
        # native Claude install embeds ripgrep and serves it when invoked with argv0 `rg`.
        real_rg=$(command -v rg 2>/dev/null || true)
        rg_argv0=""
        case "$real_rg" in /*) ;; *) real_rg="";; esac
        # Standalone Codex ships rg beside bin/ in codex-path/, but that directory need not be in
        # the SSH login shell's PATH yet. Resolve the CLI symlink without changing its installation.
        if [ -z "$real_rg" ] && [ "$agent" = codex ]; then
          codex_bin=$(command -v codex 2>/dev/null || true)
          case "$codex_bin" in
            /*)
              codex_real=$("$PYTHON3" -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$codex_bin")
              codex_rg="$(dirname "$(dirname "$codex_real")")/codex-path/rg"
              if [ -x "$codex_rg" ] && "$codex_rg" --version </dev/null 2>/dev/null | grep -q '^ripgrep '; then
                real_rg="$codex_rg"
              fi
              ;;
          esac
        fi
        if [ -z "$real_rg" ] && [ "$agent" = claude ]; then
          claude_bin=$(command -v claude 2>/dev/null || true)
          case "$claude_bin" in
            /*)
              if (exec -a rg "$claude_bin" --version </dev/null 2>/dev/null) | grep -q '^ripgrep '; then
                real_rg="$claude_bin"; rg_argv0=rg
              fi
              ;;
          esac
        fi
        if [ -n "$real_rg" ]; then
          write_tool_shim "$SD" rg "$real_rg" "$ba" "$lp" "$mp" "$ssh_config" "$control_path" "$rg_argv0" \
            || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
          rg_shim=1
        fi
      fi
    fi
    if [ "$agent" = claude ] || [ "$agent" = codex ]; then
      PYTHON3=$(command -v python3 2>/dev/null || true)
      [ -n "$PYTHON3" ] && [ -x "$PYTHON3" ] \
        || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
      [ -x "$SCRIPT_DIR/route-command.py" ] \
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
        # Grep/Glob/file suggestions use the PATH rg (the session shim) instead of the bundled one.
        [ "$rg_shim" = 1 ] && env_out="$env_out USE_BUILTIN_RIPGREP=0"
        flags_out="--append-system-prompt-file $(sq "$RULE") --settings $(sq "$CLAUDE_SETTINGS")"
        if [ "$approval" = auto ]; then
          if claude --help 2>/dev/null | grep -q '"auto"'; then
            flags_out="$flags_out --permission-mode auto"
          else
            approval=normal
          fi
        fi
        ;;
      opencode)
        # OPENCODE_CONFIG is merged ADDITIVELY on top of the user's global + project configs, so we
        # only write a minimal session layer (instructions + permission on yolo). No jq, no copying
        # the user's config — that avoided a crash on a non-array `instructions` and a stale config
        # snapshot overriding a project-local opencode.json.
        CFG="$SD/opencode.json"
        ready_file="$SD/opencode-plugin.ready"
        rm -f "$ready_file" 2>/dev/null || true
        opencode_plugin=$(write_opencode_plugin "$SD" "$runner" "$mp" "$ready_file") \
          || { rm -rf "$SD" 2>/dev/null || true; echo "RH_STATUS=ERROR"; exit 1; }
        [ "$yolo" = 1 ] && perm='"permission": "allow", ' || perm=''
        [ "$approval" = yolo ] || approval=normal  # opencode has no automatic approval review
        # JSON-escape session paths: escape \ then " (both legal in Unix paths; rare but correct).
        rule_json="$(printf '%s' "$RULE" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        plugin_json="$(printf '%s' "$opencode_plugin" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{ "$schema": "https://opencode.ai/config.json", %s"plugin": ["%s"], "instructions": ["%s"] }\n' \
          "$perm" "$plugin_json" "$rule_json" > "$CFG"
        env_out="${env_out:+$env_out }OPENCODE_CONFIG=$(sq "$CFG")"
        ;;
      codex)
        dev_cfg="developer_instructions=$(toml_basic_string_file "$RULE")"
        hook_cfg="hooks.PreToolUse=[{matcher=\"^Bash\$\",hooks=[{type=\"command\",command=\"$(toml_escape_value "$hook_command")\",timeout=5,statusMessage=\"Routing command to project host\"}]}]"
        flags_out="-c $(sq "$dev_cfg") -c $(sq "$hook_cfg") --dangerously-bypass-hook-trust"
        # Pin the shell-tool PATH after Codex builds its subprocess environment. Login/profile
        # initialization could otherwise move a bundled rg or system git ahead of the shims.
        tool_path_cfg="shell_environment_policy.set.PATH=\"$(toml_escape_value "$SD/bin:$PATH")\""
        flags_out="$flags_out -c $(sq "$tool_path_cfg") -c allow_login_shell=false -c shell_environment_policy.experimental_use_profile=false"
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
        if [ "$approval" = auto ]; then
          # Automatic review keeps the workspace-write sandbox selected above.
          if codex --help 2>/dev/null | grep -q -- '--approve-for-me'; then
            flags_out="$flags_out --approve-for-me"
          else
            approval=normal
          fi
        fi
        ;;
    esac
    resume_out=$("$SCRIPT_DIR/session-reaper.sh" resume-take "$SD" 2>/dev/null | sed -n 's/^RESUME=//p')
    case "$agent" in codex) resume_args="resume --last";; *) resume_args="--continue";; esac
    printf 'RH_STATUS=INJECTED\n'
    printf 'RH_RESUME_AVAILABLE=%s\n' "$resume_out"
    printf 'RH_RESUME_ARGS=%s\n' "$resume_args"
    printf 'RH_LAUNCH_ENV=%s\n'   "$env_out"
    printf 'RH_LAUNCH_FLAGS=%s\n' "$flags_out"
    printf 'RH_APPROVAL=%s\n' "$approval"
    printf 'RH_READY_FILE=%s\n'   "$ready_file"
    printf 'RH_LAUNCH_PREFIX=%s\n' "$prefix_out"
    printf 'RH_SESSION_DIR=%s\n' "$SD"
    ;;
  off)
    mp="${3:-}"; sid="${4:-}"
    [ -z "$sid" ] || valid_session_id "$sid" || { echo "RH_STATUS=ERROR"; exit 2; }
    SD="$(session_dir "$mp" "$sid")"
    # All agents' artifacts (the rule file, and for opencode its session config) live in the session
    # dir; none of them touched the mounted repo — so cleanup is just removing that dir.
    if [ -d "$SD" ]; then
      # Stop the session's multiplexing master and leftover routed processes, then drop the dir.
      reaper="$SD/impl/session-reaper.sh"
      [ -x "$reaper" ] || reaper="$SCRIPT_DIR/session-reaper.sh"
      if [ -x "$reaper" ]; then
        RH_HOME="${RH_HOME:-$HOME/.remote-harness}" "$reaper" reap "$SD" --session-only \
          >/dev/null 2>&1 || { echo RH_STATUS=ERROR; exit 1; }
      fi
      [ ! -d "$SD" ] && echo "RH_STATUS=RESTORED" || echo "RH_STATUS=ERROR"
    else
      echo "RH_STATUS=NOOP"
    fi
    ;;
  *)
    echo "usage: inject-rule.sh on <agent> <laptop_path> <box_alias> <box_mountpoint> [0|1|auto] [ssh_config] [session_id] | off <agent> <box_mountpoint> [session_id]" >&2
    echo "RH_STATUS=ERROR"; exit 2;;
esac
