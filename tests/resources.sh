#!/usr/bin/env bash
# Exercise shared resource release and implementation snapshots without a real SSHFS mount.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/rh-resources.XXXXXX")
worker=""
trap '[ -z "$worker" ] || kill "$worker" 2>/dev/null || true; rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
export RH_HOME="$fixture/rh" MOUNTPOINT="$fixture/mount"
export MOUNT_STATE="$fixture/mounted" UNMOUNT_LOG="$fixture/unmount.log"
export BAD_REAPER_MARKER="$fixture/wrong-reaper"
export MUX_LOG="$fixture/mux.log"
mkdir -p "$fixture/bin" "$fixture/source" "$MOUNTPOINT" "$RH_HOME/.sessions/transport.a/runtime" "$RH_HOME/.sessions/transport.b/runtime"
cp "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.py "$fixture/source/"
cat > "$fixture/bin/sshfs" <<'SH'
#!/bin/sh
printf '%s\n' "$1" > "$MOUNT_STATE"
SH
cat > "$fixture/bin/mount" <<'SH'
#!/bin/sh
[ ! -f "$MOUNT_STATE" ] || printf '%s on %s type fuse.sshfs (rw)\n' "$(cat "$MOUNT_STATE")" "$MOUNTPOINT"
SH
cat > "$fixture/bin/mountpoint" <<'SH'
#!/bin/sh
[ -f "$MOUNT_STATE" ] && [ "$2" = "$MOUNTPOINT" ]
SH
cat > "$fixture/bin/umount" <<'SH'
#!/bin/sh
case "$*" in *"$MOUNTPOINT"*) ;; *) exit 1;; esac
[ "${FAIL_UNMOUNT:-0}" != 1 ] || exit 1
printf 'unmount\n' >> "$UNMOUNT_LOG"
rm -f "$MOUNT_STATE"
SH
cp "$fixture/bin/umount" "$fixture/bin/fusermount"
cp "$fixture/bin/umount" "$fixture/bin/fusermount3"
cat > "$fixture/bin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$MUX_LOG"
SH
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
cfg_a="$RH_HOME/.sessions/transport.a/ssh_config"
cfg_b="$RH_HOME/.sessions/transport.b/ssh_config"
printf 'Host rlocal\n    HostName 127.0.0.1\n    Port 25292\n' > "$cfg_a"
printf 'Host rlocal\n    HostName 127.0.0.1\n    Port 25302\n' > "$cfg_b"
printf key > "$(dirname "$cfg_a")/id_ed25519"
printf key > "$(dirname "$cfg_b")/id_ed25519"
# The dispatcher marker makes it observable which implementation a generated entry executes.
printf '#!/bin/sh\nprintf "snapshot-v1\\n"\n' > "$fixture/source/run-on-project-host.sh"

for name in a b; do
  cfg="$cfg_a"; [ "$name" = a ] || cfg="$cfg_b"
  "$fixture/source/mount-project.sh" --alias rlocal --remote-path /project \
    --mountpoint "$MOUNTPOINT" --ssh-config "$cfg" --session-id "rev.$name" > "$fixture/mount-$name.out"
  "$fixture/source/inject-rule.sh" on codex /project rlocal "$MOUNTPOINT" 0 "$cfg" "rev.$name" > "$fixture/inject-$name.out"
done
grep -q '^STATUS=already-mounted$' "$fixture/mount-b.out" || fail 'second session did not share the mount'
key=$(printf '%s' "$MOUNTPOINT" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
sd_a="$RH_HOME/.sessions/$key.rev.a"
sd_b="$RH_HOME/.sessions/$key.rev.b"
[ "$(sed -n 's/^MOUNT_SSH_CONFIG=//p' "$sd_b/session.env")" = "$(b64 "$cfg_a")" ] || fail 'shared mount forgot its original transport'
start=$(ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
printf 'OWNER_PID=%s\nOWNER_START=%s\n' "$$" "$(b64 "$start")" > "$sd_b/owner.env"
cp "$sd_b/owner.env" "$RH_HOME/.sessions/lease.rev.b/owner.env"
printf 'OWNER_PID=999999999\n' > "$sd_a/owner.env"
cp "$sd_a/owner.env" "$RH_HOME/.sessions/lease.rev.a/owner.env"

# Changing the development copy must not change either generated call or its cleanup code.
printf '#!/bin/sh\nprintf "changed\\n"\nexit 77\n' > "$fixture/source/run-on-project-host.sh"
printf 'raise SystemExit(77)\n' > "$fixture/source/project-host-tool.py"
printf '#!/bin/sh\ntouch "$BAD_REAPER_MARKER"\nexit 77\n' > "$fixture/source/session-reaper.sh"
[ "$(cd "$MOUNTPOINT" && "$sd_b/bin/git" status --porcelain)" = snapshot-v1 ] || fail 'git shim used changed development code'
[ "$("$sd_b/bin/rh-run" "$(b64 .)" "$(b64 :)" )" = snapshot-v1 ] || fail 'runner used changed development code'

# A process using the shared config must survive the first owner's cleanup.
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(300)' \
  "$(dirname "$cfg_a")/runtime/mux" "$cfg_a" &
worker=$!
for attempt in 1 2 3 4 5; do [ ! -S "$(dirname "$cfg_a")/runtime/mux" ] || break; sleep 1; done
"$sd_a/impl/session-reaper.sh" release "$sd_a" > "$fixture/release-a.out"
[ -f "$MOUNT_STATE" ] || fail 'first exit unmounted a shared project'
[ -f "$cfg_a" ] && [ -f "$(dirname "$cfg_a")/id_ed25519" ] || fail 'first exit deleted a shared transport'
kill -0 "$worker" || fail 'first exit killed a shared transport process'
[ ! -e "$MUX_LOG" ] || fail 'first exit closed a shared multiplexing master'
[ -d "$sd_b/impl" ] || fail 'first exit removed another implementation snapshot'
[ ! -e "$BAD_REAPER_MARKER" ] || fail 'cleanup used changed development reaper'

# Failed unmount retains the actual mount config. A later GC retries it and reclaims the key.
printf 'OWNER_PID=999999999\n' > "$sd_b/owner.env"
cp "$sd_b/owner.env" "$RH_HOME/.sessions/lease.rev.b/owner.env"
FAIL_UNMOUNT=1 "$sd_b/impl/session-reaper.sh" release "$sd_b" > "$fixture/release-b.out" 2> "$fixture/release-b.err"
[ -f "$cfg_a" ] && [ -f "$MOUNT_STATE" ] || fail 'failed unmount lost its reconnect config'
kill -0 "$worker" || fail 'failed unmount killed its mount transport'

# Reap the recorded orphan mount once it becomes releasable; another rlocal port is independent.
mkdir -p "$RH_HOME/.sessions/transport.c"
cfg_c="$RH_HOME/.sessions/transport.c/ssh_config"
printf 'Host rlocal\n    Port 25312\n' > "$cfg_c"
RH_REAPER_LIBRARY=1 . "$ROOT/scripts/session-reaper.sh"
resource_lock
register_mount_lease rev.c "$fixture/other-mount" "$cfg_c" "$cfg_c" rlocal
resource_unlock
unset RH_REAPER_LIBRARY
"$ROOT/scripts/session-reaper.sh" gc
[ ! -f "$MOUNT_STATE" ] || fail 'GC did not retry the abandoned mount'
[ ! -f "$cfg_a" ] || fail 'last mount reference did not release its config'
[ -s "$MUX_LOG" ] || fail 'last reference did not close the multiplexing master'
[ -f "$cfg_c" ] || fail 'cleanup affected a different rlocal tunnel'
if kill -0 "$worker" 2>/dev/null; then fail 'last reference left a transport process running'; fi
wait "$worker" 2>/dev/null || true
worker=""
