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

dispatch() {
  [ "$#" -eq 3 ] || fail "internal dispatch needs project root, cwd, and command"
  project_root=$(decode_b64 "$1") || fail "could not decode project root"
  relative_cwd=$(decode_b64 "$2") || fail "could not decode relative working directory"
  command=$(decode_b64 "$3") || fail "could not decode command"

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
  cd "$target_physical"
  exec "$shell" -lc "$command"
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
remote_command="sh -s -- --dispatch $(sq "$project_root_b64") $(sq "$relative_cwd") $(sq "$command_b64")"
exec ssh -F "$ssh_config" -T \
  -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=15 \
  "$alias_name" "$remote_command" < "$0"
