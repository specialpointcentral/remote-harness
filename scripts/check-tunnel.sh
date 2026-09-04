#!/usr/bin/env bash
# remote-harness / check-tunnel.sh
# Verify the reverse tunnel: is the loopback listener up, and does `ssh <alias>` reach
# the laptop? Read-only. Prints KEY=VALUE lines. Pass --ssh-config FILE to resolve the
# alias through a session-local config instead of ~/.ssh/config.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}
safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

# Listening TCP ports, across environments: ss → netstat (GNU/BSD) → lsof.
listening_ports() {
  { if   command -v ss      >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print $4}'
    elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print $4}'
    elif command -v lsof    >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
    fi; } | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
}

ALIAS="" PORT="" SSH_CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)      need_arg "$1" "${2-}"; ALIAS="$2"; shift 2;;
    --port)       need_arg "$1" "${2-}"; PORT="$2"; shift 2;;
    --ssh-config) need_arg "$1" "${2-}"; SSH_CONFIG="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$ALIAS" ] || { printf 'usage: check-tunnel.sh --alias NAME [--port PORT] [--ssh-config FILE]\n' >&2; exit 2; }
safe_ssh_token "$ALIAS" || { printf 'unsafe ssh alias: %s\n' "$ALIAS" >&2; exit 2; }
[ -z "$PORT" ] || printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { printf 'port must be numeric: %s\n' "$PORT" >&2; exit 2; }
[ -z "$PORT" ] || { [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || { printf 'port out of range: %s\n' "$PORT" >&2; exit 2; }
case "$SSH_CONFIG" in *'
'*) printf 'ssh config path contains a newline\n' >&2; exit 2;; esac
RH_HOME="${RH_HOME:-$HOME/.remote-harness}"
mkdir -p "$RH_HOME/.sessions" 2>/dev/null || true
SSH_ARGS=()
if [ -n "$SSH_CONFIG" ]; then
  SSH_ARGS=(-F "$SSH_CONFIG")
else
  SSH_ARGS=(-o "UserKnownHostsFile=$RH_HOME/.sessions/check-tunnel-known_hosts" \
            -o GlobalKnownHostsFile=/dev/null \
            -o StrictHostKeyChecking=accept-new \
            -o ControlMaster=no -o ControlPath=none)
fi

# Derive the port from ssh -G if not supplied.
if [ -z "$PORT" ]; then
  PORT=$(ssh "${SSH_ARGS[@]}" -G "$ALIAS" 2>/dev/null | awk '$1=="port"{print $2}')
fi
emit ALIAS "$ALIAS"
emit PORT "${PORT:-}"

# Is something listening on that loopback port? (best-effort diagnostic; the login test below is
# the authoritative check, so a tool-less box that reports "down" here still proceeds.)
if [ -n "$PORT" ] && listening_ports | grep -qx "$PORT"; then
  emit LISTENER up
else
  emit LISTENER down
fi

# Try an actual login through the tunnel. Use `timeout` only if present (absent on stock macOS);
# ssh's own ConnectTimeout + ServerAlive bound the call either way.
err="$(mktemp "$RH_HOME/.sessions/rh-check-tunnel.XXXXXX" 2>/dev/null)" || err="$RH_HOME/.sessions/rh-check-tunnel.$$"
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
out=$($TO ssh "${SSH_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$ALIAS" \
        remote-harness-health 2>"$err") || true
if printf '%s' "$out" | grep -q '^RH_OK'; then
  emit SSH up
  emit LAPTOP_HOSTNAME "$(printf '%s' "$out" | awk '{print $2}')"
  emit LAPTOP_USER "$(printf '%s' "$out" | awk '{print $3}')"
else
  emit SSH down
  emit ERROR "$(tr '\n' ' ' < "$err" 2>/dev/null | sed 's/  */ /g' | cut -c1-300)"
fi
rm -f "$err" 2>/dev/null || true
