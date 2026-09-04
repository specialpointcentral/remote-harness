#!/usr/bin/env sh
# Forced-command SSH gateway for reverse remote-harness sessions.
set -eu

fail() {
  printf 'remote-harness gateway: %s\n' "$*" >&2
  exit 2
}

safe_token() {
  case "${1:-}" in ""|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac
}

safe_b64() {
  case "${1:-}" in ""|*[!A-Za-z0-9+/=]*) return 1;; *) return 0;; esac
}

find_sftp_server() {
  for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  command -v sftp-server 2>/dev/null || return 1
}

[ "$#" -eq 1 ] || fail "missing session tag"
tag=$1
safe_token "$tag" || fail "invalid session tag"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) \
  || fail "cannot resolve gateway directory"
rh_home=$(CDPATH= cd -- "$script_dir/.." 2>/dev/null && pwd -P) \
  || fail "cannot resolve remote-harness home"
session_dir="$rh_home/.sessions/gateways/$tag"
root_file="$session_dir/project-root.b64"
dispatcher="$rh_home/bin/run-on-project-host.sh"
original=${SSH_ORIGINAL_COMMAND:-}

case "$original" in
  remote-harness-health)
    printf 'RH_OK %s %s' "$(hostname 2>/dev/null || printf unknown)" "$(id -un 2>/dev/null || printf unknown)"
    ;;
  remote-harness-exec\ *)
    set -- $original
    [ "$#" -eq 4 ] && [ "$1" = remote-harness-exec ] || fail "invalid execution request"
    safe_b64 "$2" && safe_b64 "$3" && safe_b64 "$4" || fail "invalid execution encoding"
    [ -r "$root_file" ] || fail "session project root is unavailable"
    expected_root=$(cat "$root_file")
    [ "$2" = "$expected_root" ] || fail "project root does not match this session"
    [ -x "$dispatcher" ] || fail "project-host dispatcher is unavailable"
    exec "$dispatcher" --dispatch "$2" "$3" "$4"
    ;;
  internal-sftp|internal-sftp\ *|sftp-server|sftp-server\ *|/usr/libexec/sftp-server|/usr/libexec/sftp-server\ *|/usr/lib/openssh/sftp-server|/usr/lib/openssh/sftp-server\ *)
    set -- $original
    sftp_server=$(find_sftp_server) || fail "no external sftp-server executable is available"
    shift
    exec "$sftp_server" "$@"
    ;;
  *)
    fail "unsupported SSH command"
    ;;
esac
