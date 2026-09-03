#!/usr/bin/env bash
# remote-harness / setup-tunnel.sh
# Write a session-local ssh config so that `ssh <alias>` reaches the laptop over the
# reverse tunnel that the laptop opens with `RemoteForward <port> 127.0.0.1:22`.
# Idempotent (re-runnable). Requires --config PATH and never writes ~/.ssh/config,
# ~/.ssh/config.rh-bak.*, ~/.ssh/known_hosts_<alias>, or any other file under ~/.ssh.
# Generates an ed25519 key under $RH_HOME/keys if asked.
# Prints KEY=VALUE lines on stdout; human notes on stderr.
set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_arg() { [ -n "${2+x}" ] && [ -n "$2" ] || die "missing value for $1"; }
ssh_config_value() {
  case "$1" in
    *[[:space:]\"\\]*)
      printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      ;;
    *) printf '%s' "$1";;
  esac
}

RH_HOME="${RH_HOME:-$HOME/.remote-harness}"

# Serialize first-time key generation on a shared account. The generated identity is remote-harness
# owned and lives under $RH_HOME/keys; user-managed ~/.ssh keys are never created or modified.
LOCK="$RH_HOME/.locks/keygen.lock"
rh_lock() {
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" 2>/dev/null && flock -w 10 9 2>/dev/null || true
  else
    # No flock (e.g. macOS): atomic mkdir spin-lock. Integer sleep only (BSD sleep rejects fractions).
    _n=0; while ! mkdir "$LOCK.d" 2>/dev/null; do _n=$((_n+1)); [ "$_n" -ge 15 ] && break; sleep 1; done
  fi
}
rh_unlock() {
  if command -v flock >/dev/null 2>&1; then flock -u 9 2>/dev/null || true; exec 9>&- 2>/dev/null || true
  else rmdir "$LOCK.d" 2>/dev/null || true; fi
}

# Listening TCP ports on THIS box (ss -> netstat [GNU/BSD] -> lsof), for free-port probing.
listening_ports() {
  { if   command -v ss      >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print $4}'
    elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print $4}'
    elif command -v lsof    >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
    fi; } | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
}

ALIAS="" PORT="" LUSER="" IDENTITY="" GEN_KEY=0 NAMESPACE="" CFG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)     need_arg "$1" "${2-}"; ALIAS="$2"; shift 2;;
    --port)      need_arg "$1" "${2-}"; PORT="$2"; shift 2;;
    --namespace) need_arg "$1" "${2-}"; NAMESPACE="$2"; shift 2;;   # real-user namespace -> stable port when --port omitted
    --user)      need_arg "$1" "${2-}"; LUSER="$2"; shift 2;;
    --identity)  need_arg "$1" "${2-}"; IDENTITY="$2"; shift 2;;
    --config)    need_arg "$1" "${2-}"; CFG_OVERRIDE="$2"; shift 2;;
    --gen-key)   GEN_KEY=1; shift;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$ALIAS" ] && [ -n "$LUSER" ] && [ -n "$CFG_OVERRIDE" ] \
  || die "usage: setup-tunnel.sh --config ABS_PATH --alias NAME --user LAPTOP_USER (--port PORT | --namespace RU) [--identity KEYFILE] [--gen-key]"

# Derive a STABLE reverse port from the confirmed namespace when no explicit --port was
# given: hash RU -> a port in [20002,29992] (step 10, ends in 2, below the ephemeral floor; 1000 slots
# so distinct users rarely collide), then probe for a free slot.
if [ -z "$PORT" ]; then
  [ -n "$NAMESPACE" ] || die "need --port PORT or --namespace RU"
  _ns="$(printf '%s' "$NAMESPACE" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//; s/[._-]*$//')"
  _inuse="$(listening_ports)"
  _low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true)
  [ -z "$_low" ] && _low=$(sysctl -n net.inet.ip.portrange.first 2>/dev/null || true)
  _low=${_low:-32768}
  if [ "$_low" -gt 29992 ]; then
    _bb=$(( $(printf '%s' "$_ns" | cksum | awk '{print $1}') % 1000 ))
    _i=0
    while [ "$_i" -lt 256 ]; do
      _p=$(( 20002 + ((_bb + _i) % 1000) * 10 ))
      printf '%s\n' "$_inuse" | grep -qx "$_p" || { PORT="$_p"; break; }
      _i=$(( _i + 1 ))
    done
  fi
  [ -n "$PORT" ] || die "could not derive a free stable port for namespace '$NAMESPACE'"
  note "Derived stable reverse port $PORT for namespace '$NAMESPACE'."
fi
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || die "port must be numeric: $PORT"
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "port out of range: $PORT"
printf '%s' "$ALIAS" | grep -qE '^[A-Za-z0-9._-]+$' || die "alias has unsafe characters: $ALIAS"
case "$LUSER" in ""|-*|*[[:space:]]*) die "user has unsafe characters: $LUSER";; esac
case "$IDENTITY" in *'
'*) die "identity path contains a newline";; esac

case "$CFG_OVERRIDE" in /*) ;; *) die "--config must be an absolute path: $CFG_OVERRIDE";; esac
case "$CFG_OVERRIDE" in *'
'*) die "--config contains a newline";; esac
CFG="$CFG_OVERRIDE"
mkdir -p "$(dirname "$CFG")" 2>/dev/null || true
touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
RUNTIME_DIR="$(dirname "$CFG")/runtime"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || die "could not create SSH runtime directory"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
KH="$RUNTIME_DIR/known_hosts_${ALIAS}"

# --- pick / create an identity key -----------------------------------------
if [ -z "$IDENTITY" ]; then
  [ -f "$RH_HOME/keys/id_ed25519" ] && IDENTITY="$RH_HOME/keys/id_ed25519"
fi
if [ -z "$IDENTITY" ] && [ "$GEN_KEY" = 1 ]; then
  IDENTITY="$RH_HOME/keys/id_ed25519"
  # Serialize keygen on a SHARED box account: two concurrent first-time runs must not both write
  # the same remote-harness keypair. Under the lock, generate only if it still doesn't exist;
  # otherwise reuse the one the other run created.
  rh_lock
  if [ ! -f "$IDENTITY" ]; then
    note "No SSH key found; generating $IDENTITY (no passphrase)."
    mkdir -p "$(dirname "$IDENTITY")" 2>/dev/null || true
    chmod 700 "$(dirname "$IDENTITY")" 2>/dev/null || true
    ssh-keygen -t ed25519 -N "" -f "$IDENTITY" -C "remote-harness@$(hostname 2>/dev/null || echo host)" >/dev/null
  else
    note "SSH key appeared concurrently; reusing $IDENTITY."
  fi
  rh_unlock
fi

# --- ephemeral-floor sanity check ------------------------------------------
low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true)  # Linux
[ -z "$low" ] && low=$(sysctl -n net.inet.ip.portrange.first 2>/dev/null || true)   # macOS/BSD
low=${low:-32768}
if [ "$PORT" -ge "$low" ]; then
  note "WARNING: port $PORT is within the ephemeral range (>= $low); it may occasionally"
  note "         collide with an outbound connection. A fixed port below $low is safer."
fi

# --- write an idempotent managed block -------------------------------------
BEGIN="# >>> remote-harness:${ALIAS} >>> (managed; edits here are overwritten)"
END="# <<< remote-harness:${ALIAS} <<<"
strip="$(mktemp "$(dirname "$CFG")/.rh-strip.XXXXXX" 2>/dev/null)" || strip="$CFG.rh-strip.$$"
awk -v b="$BEGIN" -v e="$END" '
  index($0,"# >>> remote-harness:")==1 && index($0, b)==1 {skip=1}
  skip==0 {print}
  $0==e {skip=0}
' "$CFG" > "$strip"

# Build the new config in a SAME-DIRECTORY temp, then rename over $CFG. The rename is atomic on one
# filesystem, so even if the lock above was lost (timeout / no flock), a concurrent reader/writer sees
# the old OR the fully-new file — never a half-written one, and at worst a lost update, not corruption.
new="$(mktemp "$(dirname "$CFG")/.rh-cfg.XXXXXX" 2>/dev/null)" || new="$CFG.rh-new.$$"
{
  cat "$strip"
  printf '%s\n' "$BEGIN"
  printf '# %s reaches your laptop via the reverse tunnel (laptop adds: RemoteForward %s 127.0.0.1:22)\n' "$ALIAS" "$PORT"
  printf 'Host %s\n' "$ALIAS"
  printf '    HostName 127.0.0.1\n'
  printf '    Port %s\n' "$PORT"
  printf '    User %s\n' "$(ssh_config_value "$LUSER")"
  [ -n "$IDENTITY" ] && printf '    IdentityFile %s\n' "$(ssh_config_value "$IDENTITY")"
  printf '    UserKnownHostsFile %s\n' "$(ssh_config_value "$KH")"
  printf '    GlobalKnownHostsFile /dev/null\n'
  printf '    StrictHostKeyChecking accept-new\n'
  printf '    ServerAliveInterval 30\n'
  printf '    ServerAliveCountMax 3\n'
  # Disable multiplexing: avoiding ControlPath sockets makes macOS/FUSE-T sessions much more robust.
  printf '    ControlMaster no\n'
  printf '%s\n' "$END"
} > "$new"
chmod 600 "$new" 2>/dev/null || true
mv "$new" "$CFG"
rm -f "$strip"
emit STATUS configured
emit ALIAS "$ALIAS"
emit PORT "$PORT"
emit CONFIG "$CFG"
emit IDENTITY "${IDENTITY:-}"
emit KNOWN_HOSTS "$KH"
emit REMOTEFORWARD_LINE "RemoteForward $PORT 127.0.0.1:22"
if [ -n "$IDENTITY" ] && [ -f "$IDENTITY.pub" ]; then
  emit PUBKEY "$(cat "$IDENTITY.pub")"
  # Keep a diagnostic copy as well; the simple path consumes the PUBKEY line above directly.
  mkdir -p "$RH_HOME" 2>/dev/null || true
  cp "$IDENTITY.pub" "$RH_HOME/.tunnel-pubkey" 2>/dev/null || true
else
  emit PUBKEY ""
  note "No remote-harness public key available; the laptop must already accept agent/key auth,"
  note "or re-run with --gen-key to create a remote-harness key under $RH_HOME/keys."
fi
note "Wrote Host '$ALIAS' to $CFG (managed block)."
