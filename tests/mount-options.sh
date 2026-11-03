#!/usr/bin/env bash
# Exercise mount-project's actual SSHFS arguments, then symlink behavior if FUSE is available.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d /tmp/rh-mount-options.XXXXXX)
fixture=$(cd "$fixture" && pwd -P)
real_mp="$fixture/real-mount"
OS=$(uname -s)
# macOS has no mountpoint(1); FUSE-T mounts appear in mount(8) by their real path. The table is read
# whole: under pipefail, `mount | grep -q` fails when grep's early exit stops mount with SIGPIPE (and
# GNU grep exits early for output to /dev/null too). No bare `return`: called from the EXIT trap, it
# would report the status from before the trap.
real_mounted() {
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$real_mp" 2>/dev/null
  else
    grep -qF " $real_mp " <<<"$(mount 2>/dev/null)"
  fi
}
cleanup() {
  if real_mounted; then
    fusermount -uz "$real_mp" 2>/dev/null || fusermount3 -uz "$real_mp" 2>/dev/null \
      || umount "$real_mp" 2>/dev/null || umount -f "$real_mp" 2>/dev/null || true
    if real_mounted; then
      printf 'could not unmount test mount; kept %s\n' "$fixture" >&2
      return
    fi
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# CI installs SSHFS and sets RH_TEST_REAL_SSHFS=1, so a real mount that cannot run fails there.
skip_real() {
  [ "${RH_TEST_REAL_SSHFS:-0}" != 1 ] || fail "real SSHFS symlink test could not run: $*"
  printf 'skip: real SSHFS symlinks (%s)\n' "$*"
  exit 0
}
export REAL_UNAME="$(command -v uname)" REAL_SSHFS="$(command -v sshfs || command -v sshfs-fuse-t || true)"
export MC_LOG="$fixture/sshfs.log"
unset RH_SSHFS_FOLLOW_SYMLINKS
mc_bin="$fixture/bin"
mkdir -p "$mc_bin" "$fixture/mount"
: > "$fixture/ssh_config"
# Fake help and mount table put the line a probe looks for first, then more than any pipe buffer:
# a probe whose grep -q exits early under pipefail then fails deterministically on SIGPIPE.
cat > "$mc_bin/sshfs" <<'SH'
#!/bin/sh
if [ "$1" = --help ]; then
  [ -n "${MC_NO_MAX:-}" ] || printf '%s\n' '-o max_conns=N'
  exec awk 'BEGIN { for (i = 0; i < 8000; i++) print "    -o other_option_" i "=VALUE" }'
fi
printf '%s\n' "$@" > "$MC_LOG"
exit 1
SH
cat > "$mc_bin/uname" <<'SH'
#!/bin/sh
if [ "$1" = -s ] && [ -n "${MC_OS:-}" ]; then printf '%s\n' "$MC_OS"
else exec "$REAL_UNAME" "$@"; fi
SH
printf '#!/bin/sh\nexit 1\n' > "$mc_bin/mountpoint"
cat > "$mc_bin/mount" <<'SH'
#!/bin/sh
[ -n "${MC_MOUNTED:-}" ] || exit 0
printf 'box:/p on %s type fuse.sshfs (rw)\n' "$MC_MOUNTED"
exec awk 'BEGIN { for (i = 0; i < 8000; i++) print "tmpfs on /run/filler-" i " type tmpfs (rw)" }'
SH
chmod +x "$mc_bin/"*
mc_opts() {  # arguments from the existing fake-SSHFS mount fixture
  : > "$MC_LOG"
  PATH="$mc_bin:$PATH" RH_HOME="$fixture/rh" "$ROOT/scripts/mount-project.sh" \
    --alias box --remote-path /p --ssh-config "$fixture/ssh_config" \
    --mountpoint "$fixture/mount" > "$fixture/mount.out" 2> "$fixture/mount.err" || return $?
  sed -n '4p' "$MC_LOG"
}
for mc_os in Linux Darwin; do
  mc_default="$(MC_OS="$mc_os" mc_opts)"
  case ",$mc_default," in *,follow_symlinks,*) ;; *) fail "$mc_os mount did not follow symlinks by default";; esac
  case ",$mc_default," in *,transform_symlinks,*|*,no_contain_symlinks,*) fail "$mc_os default rewrites links or disables containment";; esac
  mc_preserve="$(MC_OS="$mc_os" RH_SSHFS_FOLLOW_SYMLINKS=0 mc_opts)"
  case ",$mc_preserve," in *,transform_symlinks,*) ;; *) fail "$mc_os RH_SSHFS_FOLLOW_SYMLINKS=0 did not preserve symlinks";; esac
  case ",$mc_preserve," in *,follow_symlinks,*|*,no_contain_symlinks,*) fail "$mc_os preserve mode dereferences links or disables containment";; esac
done
mc_default="$(MC_OS=Linux mc_opts)"
case "$mc_default" in *max_conns*) fail 'sshfs used parallel SFTP connections by default';; esac
case "$(RH_SSHFS_MAX_CONNS=4 mc_opts)" in *max_conns=4*) ;; *) fail 'RH_SSHFS_MAX_CONNS=4 did not enable max_conns';; esac
case "$mc_default" in *entry_timeout=20,attr_timeout=20,negative_timeout=20,auto_cache*) ;; *) fail 'sshfs lookups and contents are not cached by default';; esac
case "$(MC_OS=Linux RH_SSHFS_CACHE_SECONDS=0 mc_opts)" in *negative_timeout*|*auto_cache*) fail 'RH_SSHFS_CACHE_SECONDS=0 still cached';; esac
mc_unsupported="$(MC_NO_MAX=1 RH_SSHFS_MAX_CONNS=4 mc_opts)"
[ -n "$mc_unsupported" ] || fail 'fake sshfs was not invoked'
case "$mc_unsupported" in *max_conns*) fail 'max_conns passed to an sshfs that does not support it';; esac
# The world-readable mount table names no project source; FUSE-T's sshfs keeps its own options.
case ",$mc_default," in *,fsname=remote-harness,*) ;; *) fail 'Linux sshfs mount table shows the project source';; esac
case ",$(MC_OS=Darwin mc_opts)," in *,fsname=*) fail 'FUSE-T sshfs got the libfuse fsname option';; esac
# The parent of default mountpoints, named after their projects, is private to this account.
mkdir -p "$fixture/rh/mounts/proj"
chmod 755 "$fixture/rh/mounts"
PATH="$mc_bin:$PATH" RH_HOME="$fixture/rh" "$ROOT/scripts/mount-project.sh" --alias box --remote-path /p \
  --ssh-config "$fixture/ssh_config" --mountpoint "$fixture/rh/mounts/proj" >/dev/null 2>&1 || true
[ "$(stat -c %a "$fixture/rh/mounts" 2>/dev/null || stat -f %Lp "$fixture/rh/mounts")" = 700 ] \
  || fail 'the default mountpoint parent is not private'
# Without mountpoint(1) answering yes (as on macOS), a mount listed early in a long table is reused.
MC_MOUNTED="$fixture/mount" mc_opts >/dev/null
grep -qx STATUS=already-mounted "$fixture/mount.out" || fail 'a mount listed before a long mount table was not found'
[ ! -s "$MC_LOG" ] || fail 'a listed mount was mounted again'

# Reject invalid settings before mount or local launcher SSH activity; cleanup ignores this knob.
for value in 2 true '1,follow_symlinks' '$(touch bad)' '1;exit 0'; do
  : > "$MC_LOG"
  if RH_SSHFS_FOLLOW_SYMLINKS="$value" mc_opts >/dev/null; then fail "invalid symlink setting accepted: $value"; fi
  [ ! -s "$MC_LOG" ] || fail 'invalid symlink setting reached SSHFS'
  if RH_SSHFS_FOLLOW_SYMLINKS="$value" bash "$ROOT/scripts/laptop-setup.sh" \
      > "$fixture/launcher.out" 2> "$fixture/launcher.err"; then fail 'launcher accepted invalid symlink setting'; fi
  grep -qx 'RH_SSHFS_FOLLOW_SYMLINKS must be 0 or 1' "$fixture/launcher.err" || fail 'launcher did not validate symlink setting before setup'
done

# A real temporary mount uses a local sftp-server in place of ssh: no network or live session.
sftp_server=""
for candidate in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/sftp-server; do
  [ -x "$candidate" ] && { sftp_server=$candidate; break; }
done
{ [ -n "$sftp_server" ] && [ -n "$REAL_SSHFS" ]; } || skip_real 'needs sshfs and sftp-server'
# FUSE-T on macOS serves mounts over a loopback NFS server: no /dev/fuse or fusermount.
if [ "$OS" != Darwin ] && { [ ! -c /dev/fuse ] \
    || ! { command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1; }; }; then
  skip_real 'needs fusermount and /dev/fuse'
fi
real_src="$fixture/source"
mkdir -p "$fixture/real-bin" "$real_src/sub" "$real_src/tree" "$real_mp" "$fixture/outside"
printf 'project\n' > "$real_src/target"
printf 'linked-tree\n' > "$real_src/tree/child"
printf 'external\n' > "$fixture/outside/target"
ln -s target "$real_src/relative"
ln -s "$real_src/target" "$real_src/absolute"
ln -s tree "$real_src/tree-link"
ln -s "$real_src/tree" "$real_src/absolute-tree"
ln -s ../target "$real_src/sub/relative"
ln -s "$real_src/target" "$real_src/sub/absolute"
ln -s missing "$real_src/dangling"
ln -s "$fixture/outside/target" "$real_src/external"
export SFTP_LAUNCHER="$fixture/sftp"
printf '#!/bin/sh\nexec "%s"\n' "$sftp_server" > "$SFTP_LAUNCHER"
cat > "$fixture/real-bin/sshfs" <<'SH'
#!/bin/sh
if [ "$1" = --help ]; then exec "$REAL_SSHFS" "$@"; fi
exec "$REAL_SSHFS" "$1" "$2" -o "${4%,ssh_command=*},ssh_command=$SFTP_LAUNCHER"
SH
chmod +x "$fixture/real-bin/sshfs" "$SFTP_LAUNCHER"
real_mount() {  # [session id]
  PATH="$fixture/real-bin:$PATH" RH_HOME="$fixture/rh" RH_SSHFS_CACHE_SECONDS=0 \
    "$ROOT/scripts/mount-project.sh" --alias x --remote-path "$real_src" \
    --mountpoint "$real_mp" --ssh-config "$fixture/ssh_config" ${1:+--session-id "$1"} > "$fixture/real.out"
}
real_unmount() {
  "$ROOT/scripts/mount-project.sh" --alias x --unmount --mountpoint "$real_mp" > "$fixture/unmount.out"
  grep -qx STATUS=unmounted "$fixture/unmount.out" || fail 'temporary symlink mount did not unmount'
}
real_mount
if ! grep -qx STATUS=mounted "$fixture/real.out"; then
  skip_real "temporary local-sftp mount unavailable: $(tr '\n' ' ' < "$fixture/real.out")"
fi
grep -qx FOLLOW_SYMLINKS=1 "$fixture/real.out" || fail 'default mount did not report following symlinks'
python3 - "$real_mp" <<'PY'
from pathlib import Path
import stat
import sys

mount = Path(sys.argv[1])
assert stat.S_ISREG((mount / "relative").lstat().st_mode)
assert stat.S_ISDIR((mount / "tree-link").lstat().st_mode)
assert (mount / "sub/relative").read_text() == "project\n"
assert (mount / "sub/absolute").read_text() == "project\n"
assert (mount / "external").read_text() == "external\n"
PY
real_unmount

# Preserved links, recorded with the mount for the sessions that share it.
RH_SSHFS_FOLLOW_SYMLINKS=0 real_mount rev.a
grep -qx STATUS=mounted "$fixture/real.out" || fail 'preserved-symlink mount failed'
grep -qx FOLLOW_SYMLINKS=0 "$fixture/real.out" || fail 'preserved-symlink mount did not report its mode'
record=$(find "$fixture/rh/.sessions/.mounts" -name '*.env' -type f)
[ "$(grep -c '^FOLLOW_SYMLINKS=0$' "$record")" = 1 ] || fail 'mount record does not hold the symlink mode'
# Read the whole help first: under pipefail, grep -q can SIGPIPE sshfs and misreport the option.
contain=0
case "$("$REAL_SSHFS" --help 2>&1 || true)" in *contain_symlinks*) contain=1;; esac
python3 - "$real_mp" "$real_src" "$fixture/outside/target" "$contain" <<'PY'
import os
from pathlib import Path
import stat
import sys

mount, source, outside = map(Path, sys.argv[1:4])
contain = sys.argv[4] == "1"
for name in ("relative", "absolute", "tree-link", "absolute-tree", "sub/relative", "sub/absolute", "dangling", "external"):
    assert stat.S_ISLNK((mount / name).lstat().st_mode), name
for name in ("relative", "absolute"):
    assert (mount / name).read_text() == "project\n", name
    assert os.readlink(mount / name) == "target", name
for name in ("tree-link", "absolute-tree"):
    assert (mount / name / "child").read_text() == "linked-tree\n", name
assert os.readlink(mount / "dangling") == "missing"
assert not (mount / "dangling").exists()
# os.walk without followlinks sees the directories' links but never their children.
walked = {str(Path(root, f).relative_to(mount)) for root, _, files in os.walk(mount) for f in files}
assert "tree/child" in walked
assert "tree-link/child" not in walked and "absolute-tree/child" not in walked
for name in ("sub/relative", "sub/absolute"):
    if contain:
        try:
            (mount / name).read_text()
        except PermissionError:
            pass
        else:
            raise AssertionError(f"SSHFS containment was bypassed: {name}")
    else:
        assert (mount / name).read_text() == "project\n", name
        assert os.readlink(mount / name) == "../target", name
if contain:
    try:
        os.readlink(mount / "external")
    except PermissionError:
        pass
    else:
        raise AssertionError("SSHFS containment was bypassed for an external absolute link")
else:
    # Outside-base targets are left verbatim, not mapped into the project mount.
    assert os.readlink(mount / "external") == str(outside)
assert os.readlink(source / "absolute") == str(source / "target")
PY
# Another session reusing the mount learns the mode it actually has, not the one it asked for.
# The mount table shows the fixed fsname, never alias:path; sessions match the source by record.
if [ "$(uname -s)" = Linux ]; then
  real_table=$(cat /proc/mounts)
  grep -qF "remote-harness $real_mp " <<<"$real_table" || fail 'the real mount does not show the fixed fsname'
  ! grep -qF "x:$real_src" <<<"$real_table" || fail 'the mount table names the project source'
fi
real_mount rev.b
grep -qx STATUS=already-mounted "$fixture/real.out" || fail 'second session did not reuse the mount'
grep -qx FOLLOW_SYMLINKS=0 "$fixture/real.out" || fail 'shared mount did not report its preserved-symlink mode'
# Records written before the setting existed belong to mounts that always followed links.
grep -v '^FOLLOW_SYMLINKS=' "$record" > "$fixture/record.old"
cat "$fixture/record.old" > "$record"
real_mount rev.c
grep -qx FOLLOW_SYMLINKS=1 "$fixture/real.out" || fail 'a record without a mode was not reported as following links'
real_unmount
printf 'ok: real SSHFS symlink follow default, preserved identity, and shared-mount mode\n'
