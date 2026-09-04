#!/usr/bin/env sh
# Route an encoded command to the project host, or execute its internal dispatch mode there.
set -eu

fail() {
  printf 'remote-harness: %s\n' "$*" >&2
  exit 2
}

decode_b64() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    printf '%s' "$1" | base64 --decode
  elif base64 -d </dev/null >/dev/null 2>&1; then
    printf '%s' "$1" | base64 -d
  else
    printf '%s' "$1" | base64 -D
  fi
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

dispatch() {
  [ "$#" -eq 3 ] || fail "internal dispatch needs project root, cwd, and command"
  project_root=$(decode_b64 "$1") || fail "could not decode project root"
  relative_cwd=$(decode_b64 "$2") || fail "could not decode relative working directory"
  command=$(decode_b64 "$3") || fail "could not decode command"
  if reject_direct_agent_launch "$command"; then
    fail "Agent processes must run on the remote agent host"
  fi

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

  shell=${SHELL:-/bin/sh}
  case "$shell" in /*) ;; *) shell=/bin/sh ;; esac
  [ -x "$shell" ] || shell=/bin/sh
  export GIT_OPTIONAL_LOCKS=0
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR \
    OPENAI_API_KEY CODEX_API_KEY CODEX_HOME 2>/dev/null || true
  guard_path=$(make_agent_guard_path)
  trap 'rm -rf "$guard_path"' EXIT HUP INT TERM
  cd "$target_physical"
  guarded_command="PATH=$(sq "$guard_path"):\$PATH; export PATH; $command"
  "$shell" -lc "$guarded_command"
  status=$?
  rm -rf "$guard_path"
  trap - EXIT HUP INT TERM
  exit "$status"
}

if [ "${1:-}" = "--dispatch" ]; then
  shift
  dispatch "$@"
fi

ssh_config=""
alias_name=""
project_root=""
relative_cwd=""
command_b64=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-config) [ "$#" -ge 2 ] || fail "missing --ssh-config value"; ssh_config=$2; shift 2 ;;
    --alias) [ "$#" -ge 2 ] || fail "missing --alias value"; alias_name=$2; shift 2 ;;
    --project-root) [ "$#" -ge 2 ] || fail "missing --project-root value"; project_root=$2; shift 2 ;;
    --cwd-relative-b64) [ "$#" -ge 2 ] || fail "missing --cwd-relative-b64 value"; relative_cwd=$2; shift 2 ;;
    --command-b64) [ "$#" -ge 2 ] || fail "missing --command-b64 value"; command_b64=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -f "$ssh_config" ] || fail "session SSH config is unavailable"
case "$alias_name" in ""|-*|*[!A-Za-z0-9._-]*) fail "unsafe SSH alias" ;; esac
case "$project_root" in /*) ;; *) fail "project root must be absolute" ;; esac
relative_decoded=$(decode_b64 "$relative_cwd") || fail "could not decode relative working directory"
safe_relative_dir "$relative_decoded" || fail "invalid relative working directory"
[ -n "$command_b64" ] || command_b64=$(encode_b64 "")

project_root_b64=$(encode_b64 "$project_root")
remote_command="remote-harness-exec $project_root_b64 $relative_cwd $command_b64"
exec ssh -F "$ssh_config" -T \
  -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=15 \
  "$alias_name" "$remote_command"
