#!/usr/bin/env sh
# Route an encoded command to the project host, or execute its internal dispatch mode there.
set -eu

fail() {
  printf 'remote-harness: %s\n' "$*" >&2
  exit 2
}

BASE64_DECODE_FLAG=""

decode_b64() {
  if [ -z "$BASE64_DECODE_FLAG" ]; then
    if base64 --decode </dev/null >/dev/null 2>&1; then
      BASE64_DECODE_FLAG=--decode
    elif base64 -d </dev/null >/dev/null 2>&1; then
      BASE64_DECODE_FLAG=-d
    else
      BASE64_DECODE_FLAG=-D
    fi
  fi
  printf '%s' "$1" | base64 "$BASE64_DECODE_FLAG"
}

encode_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

safe_relative_dir() {
  case "$1" in
    ""|.) return 0 ;;
    /*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

reject_direct_agent_launch() {
  printf '%s\n' "$1" | grep -Eq '(^|[;&|()]|[[:space:]])(command[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)*[[:space:]]+|exec[[:space:]]+|nohup[[:space:]]+|sudo[[:space:]]+|time[[:space:]]+)?([^;&|()[:space:]]*/)?(claude|codex|opencode)([[:space:];&|()]|$)'
}

make_agent_guard_path() {
  _mag_dir=$(mktemp -d "${TMPDIR:-/tmp}/remote-harness-no-agent.XXXXXX") \
    || fail "could not create the local no-agent guard"
  for _mag_name in claude codex opencode; do
    cat > "$_mag_dir/$_mag_name" <<'EOF'
#!/usr/bin/env sh
printf 'remote-harness: Agent processes must run on the remote agent host.\n' >&2
exit 126
EOF
    chmod +x "$_mag_dir/$_mag_name"
  done
  printf '%s' "$_mag_dir"
}

resolve_target() {  # $1=project root b64 $2=relative cwd b64 -> target_physical
  project_root=$(decode_b64 "$1") || fail "could not decode project root"
  relative_cwd=$(decode_b64 "$2") || fail "could not decode relative working directory"
  case "$project_root" in /*) ;; *) fail "project root must be absolute" ;; esac
  safe_relative_dir "$relative_cwd" || fail "invalid relative working directory"
  root_physical=$(cd "$project_root" 2>/dev/null && pwd -P) || fail "project root is unavailable"
  if [ -n "$relative_cwd" ]; then
    target_physical=$(cd "$root_physical/$relative_cwd" 2>/dev/null && pwd -P) \
      || fail "mapped working directory is unavailable"
  else
    target_physical=$root_physical
  fi
  case "$target_physical" in
    "$root_physical"|"$root_physical"/*) ;;
    *) fail "mapped working directory escapes the project root" ;;
  esac
}

scrub_agent_credentials() {
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR \
    OPENAI_API_KEY CODEX_API_KEY CODEX_HOME 2>/dev/null || true
}

# Start "$@" in its own process group when the host offers a way to (setsid on Linux, perl on
# macOS); otherwise it shares ours and only the process-tree walk below can reach its children.
run_in_new_group() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  elif [ -x /usr/bin/perl ]; then
    exec /usr/bin/perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' "$@"
  fi
  exec "$@"
}

process_tree() {  # $1=root pid -> root and every current descendant
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2; seen[NR] = $1 }
    END {
      found[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i in seen) {
          pid = seen[i]
          if (!(pid in found) && (parent[pid] in found)) { found[pid] = 1; changed = 1 }
        }
      }
      for (pid in found) print pid
    }'
}

# Stop a command and everything it started: TERM to its process group and process tree, then KILL
# whatever is still there after five seconds.
terminate_tree() {  # $1=root pid
  _tt_targets=$(process_tree "$1")
  kill -s TERM -- "-$1" 2>/dev/null || true
  for _tt_pid in $_tt_targets; do kill -s TERM "$_tt_pid" 2>/dev/null || true; done
  _tt_i=0
  while [ "$_tt_i" -lt 5 ]; do
    _tt_alive=0
    for _tt_pid in $_tt_targets; do kill -0 "$_tt_pid" 2>/dev/null && _tt_alive=1; done
    [ "$_tt_alive" = 1 ] || return 0
    sleep 1
    _tt_i=$((_tt_i + 1))
  done
  _tt_targets="$_tt_targets $(process_tree "$1")"
  kill -s KILL -- "-$1" 2>/dev/null || true
  for _tt_pid in $_tt_targets; do kill -s KILL "$_tt_pid" 2>/dev/null || true; done
}

stdin_is_channel() { [ -p /dev/stdin ] || [ -S /dev/stdin ]; }

# Run "$@" with stdin from /dev/null while the SSH channel (our stdin) stays open. The caller holds
# the channel open for exactly as long as it wants the command; EOF means it was cancelled, timed
# out, or lost the connection, so the command's whole process tree is stopped. Exits with the
# command's status.
run_watched() {
  exec 3<&0
  ( run_in_new_group "$@" ) </dev/null 3<&- &
  watched_pid=$!
  ( cat <&3 >/dev/null 2>&1; terminate_tree "$watched_pid" ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!
  exec 3<&-
  watched_status=0
  wait "$watched_pid" || watched_status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  return "$watched_status"
}

dispatch() {
  [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || fail "internal dispatch needs project root, cwd, and command"
  watch_mode=0
  if [ "$#" -eq 4 ]; then
    [ "$4" = watch ] || fail "unsupported dispatch mode"
    watch_mode=1
  fi
  command=$(decode_b64 "$3") || fail "could not decode command"
  if reject_direct_agent_launch "$command"; then
    fail "Agent processes must run on the remote agent host"
  fi
  resolve_target "$1" "$2"

  shell=${SHELL:-/bin/sh}
  case "$shell" in /*) ;; *) shell=/bin/sh ;; esac
  [ -x "$shell" ] || shell=/bin/sh
  export GIT_OPTIONAL_LOCKS=0
  scrub_agent_credentials
  guard_path=$(make_agent_guard_path)
  trap 'rm -rf "$guard_path"' EXIT HUP INT TERM
  cd "$target_physical"
  guarded_command="PATH=$(sq "$guard_path"):\$PATH; export PATH; $command"
  status=0
  if [ "$watch_mode" = 1 ] && stdin_is_channel; then
    run_watched "$shell" -lc "$guarded_command" || status=$?
  else
    "$shell" -lc "$guarded_command" || status=$?
  fi
  rm -rf "$guard_path"
  trap - EXIT HUP INT TERM
  exit "$status"
}

# Fixed tool search path for direct tool dispatch. A forced-command SSH session has a minimal PATH and
# no login shell, so look in the usual package-manager locations instead of sourcing user profiles.
find_project_tool() {  # $1=tool name
  for _fpt_dir in /opt/homebrew/bin /usr/local/bin /usr/bin /bin /home/linuxbrew/.linuxbrew/bin \
      /nix/var/nix/profiles/default/bin /run/current-system/sw/bin \
      "$HOME/.nix-profile/bin" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [ -x "$_fpt_dir/$1" ] && [ ! -d "$_fpt_dir/$1" ] || continue
    # macOS /usr/bin/git is a stub that only works once the Command Line Tools are installed.
    if [ "$_fpt_dir/$1" = /usr/bin/git ] && [ "$(uname -s)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then
      continue
    fi
    printf '%s' "$_fpt_dir/$1"
    return 0
  done
  return 1
}

# Run one allowlisted read-heavy tool (git or rg) directly, without a shell or login profile. Each
# argument arrives as base64("x" + arg), comma-separated, so empty arguments and trailing newlines
# survive. When stdin is the SSH channel, closing it (the agent-side caller was cancelled or the
# connection dropped) terminates the tool instead of leaving it scanning the project.
dispatch_tool() {
  [ "$#" -eq 4 ] || fail "internal tool dispatch needs project root, cwd, tool, and arguments"
  resolve_target "$1" "$2"
  tool=$3
  case "$tool" in git|rg) ;; *) fail "unsupported project tool" ;; esac
  spec=$4
  case "$spec" in -) ;; ""|*[!A-Za-z0-9+/=,]*) fail "invalid tool argument encoding" ;; esac

  set -f
  set --
  if [ "$spec" != - ]; then
    saved_ifs=$IFS
    IFS=,
    for encoded in $spec; do
      IFS=$saved_ifs
      [ -n "$encoded" ] || fail "invalid tool argument encoding"
      value=$(decode_b64 "$encoded"; printf .)
      value=${value%.}
      case "$value" in x*) value=${value#x} ;; *) fail "invalid tool argument framing" ;; esac
      set -- "$@" "$value"
      IFS=,
    done
    IFS=$saved_ifs
  fi
  set +f

  tool_path=$(find_project_tool "$tool") || {
    printf 'remote-harness: %s is not installed on the project host\n' "$tool" >&2
    exit 127
  }
  export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  scrub_agent_credentials
  guard_path=$(make_agent_guard_path)
  trap 'rm -rf "$guard_path"' EXIT HUP INT TERM
  PATH="$guard_path:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  cd "$target_physical"

  status=0
  if stdin_is_channel; then
    run_watched "$tool_path" "$@" || status=$?
  else
    "$tool_path" "$@" </dev/null || status=$?
  fi
  rm -rf "$guard_path"
  trap - EXIT HUP INT TERM
  exit "$status"
}

# Launch-time preflight on the project host: report where the tool verb would find $2.
if [ "${1:-}" = "--find-tool" ]; then
  [ "$#" -eq 2 ] || fail "--find-tool needs a tool name"
  find_project_tool "$2"
  exit
fi
if [ "${1:-}" = "--dispatch" ]; then
  shift
  dispatch "$@"
fi
if [ "${1:-}" = "--dispatch-tool" ]; then
  shift
  dispatch_tool "$@"
fi

# Multiplexing socket paths must stay short (Unix sockets allow ~104-108 bytes and OpenSSH appends a
# 17-byte temporary suffix while creating the master) and must not contain ssh_config tokens.
control_path_usable() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ "${#1}" -le 86 ]
}

ssh_config=""
alias_name=""
project_root=""
relative_cwd=""
command_b64=""
tool=""
tool_args=""
control_path=""
use_mux=1
watch_command=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-config) [ "$#" -ge 2 ] || fail "missing --ssh-config value"; ssh_config=$2; shift 2 ;;
    --alias) [ "$#" -ge 2 ] || fail "missing --alias value"; alias_name=$2; shift 2 ;;
    --project-root) [ "$#" -ge 2 ] || fail "missing --project-root value"; project_root=$2; shift 2 ;;
    --cwd-relative-b64) [ "$#" -ge 2 ] || fail "missing --cwd-relative-b64 value"; relative_cwd=$2; shift 2 ;;
    --command-b64) [ "$#" -ge 2 ] || fail "missing --command-b64 value"; command_b64=$2; shift 2 ;;
    --tool) [ "$#" -ge 2 ] || fail "missing --tool value"; tool=$2; shift 2 ;;
    --args-b64) [ "$#" -ge 2 ] || fail "missing --args-b64 value"; tool_args=$2; shift 2 ;;
    --control-path) [ "$#" -ge 2 ] || fail "missing --control-path value"; control_path=$2; shift 2 ;;
    --no-mux) use_mux=0; shift ;;
    --watch) watch_command=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -f "$ssh_config" ] || fail "session SSH config is unavailable"
case "$alias_name" in ""|-*|*[!A-Za-z0-9._-]*) fail "unsafe SSH alias" ;; esac
case "$project_root" in /*) ;; *) fail "project root must be absolute" ;; esac
relative_decoded=$(decode_b64 "$relative_cwd") || fail "could not decode relative working directory"
safe_relative_dir "$relative_decoded" || fail "invalid relative working directory"

project_root_b64=$(encode_b64 "$project_root")
if [ -n "$tool" ]; then
  case "$tool" in git|rg) ;; *) fail "unsupported project tool" ;; esac
  case "$tool_args" in -) ;; ""|*[!A-Za-z0-9+/=,]*) fail "invalid tool argument encoding" ;; esac
  remote_command="remote-harness-tool $project_root_b64 $relative_cwd $tool $tool_args"
else
  [ -n "$command_b64" ] || command_b64=$(encode_b64 "")
  remote_command="remote-harness-exec $project_root_b64 $relative_cwd $command_b64"
  # The caller (channel-guard.py) holds stdin open for the command's lifetime; ask the project host
  # to stop the command tree when that channel closes.
  [ "$watch_command" = 0 ] || remote_command="$remote_command watch"
fi

# Per-connection tuning. Command-line -o values take precedence over the session ssh_config.
# ServerAlive detects a dead reverse tunnel in ~30s, so a wedged multiplexing master exits instead of
# hanging every later call; ControlPersist lets an idle master exit on its own even if session cleanup
# never runs (cleanup stops it at session end; an hour keeps it across normal pauses, since reopening
# it costs a full SSH handshake on every first call after the idle period). A stale socket left by a killed master is unlinked automatically by ControlMaster=auto.
set -- -F "$ssh_config" -T \
  -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 \
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o Compression=yes
if [ "$use_mux" = 1 ] && [ -n "$control_path" ] && control_path_usable "$control_path"; then
  set -- "$@" -o ControlMaster=auto -o "ControlPath=$control_path" -o ControlPersist=3600
else
  set -- "$@" -o ControlMaster=no -o ControlPath=none
fi
exec ssh "$@" "$alias_name" "$remote_command"
