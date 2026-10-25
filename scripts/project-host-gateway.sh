#!/usr/bin/env sh
# Forced-command SSH gateway for reverse remote-harness sessions.
set -eu
set -f

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
if [ -r "$rh_home/project-root.b64" ]; then
  session_dir="$rh_home"
  dispatcher="$script_dir/run-on-project-host.sh"
else
  session_dir="$rh_home/.sessions/gateways/$tag"
  dispatcher="$rh_home/bin/run-on-project-host.sh"
fi
root_file="$session_dir/project-root.b64"
original=${SSH_ORIGINAL_COMMAND:-}

# Every exec/tool request must name this session's registered project root, and the dispatcher that
# re-validates it on the project host must be in place.
require_session_root() {  # $1 = requested project root (base64)
  [ -r "$root_file" ] || fail "session project root is unavailable"
  expected_root=$(cat "$root_file")
  [ "$1" = "$expected_root" ] || fail "project root does not match this session"
  [ -x "$dispatcher" ] || fail "project-host dispatcher is unavailable"
}

case "$original" in
  remote-harness-health)
    printf 'RH_OK %s %s' "$(hostname 2>/dev/null || printf unknown)" "$(id -un 2>/dev/null || printf unknown)"
    ;;
  remote-harness-exec\ *)
    set -- $original
    [ "$1" = remote-harness-exec ] || fail "invalid execution request"
    if [ "$#" -eq 5 ]; then
      [ "$5" = watch ] || fail "invalid execution mode"
    else
      [ "$#" -eq 4 ] || fail "invalid execution request"
    fi
    safe_b64 "$2" && safe_b64 "$3" && safe_b64 "$4" || fail "invalid execution encoding"
    require_session_root "$2"
    exec "$dispatcher" --dispatch "$2" "$3" "$4" ${5:+"$5"}
    ;;
  remote-harness-tool\ *)
    set -- $original
    [ "$#" -eq 5 ] && [ "$1" = remote-harness-tool ] || fail "invalid tool request"
    safe_b64 "$2" && safe_b64 "$3" || fail "invalid tool encoding"
    case "$4" in git|rg) ;; *) fail "unsupported project tool" ;; esac
    case "$5" in -) ;; ""|*[!A-Za-z0-9+/=,]*) fail "invalid tool argument encoding" ;; esac
    require_session_root "$2"
    exec "$dispatcher" --dispatch-tool "$2" "$3" "$4" "$5"
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
