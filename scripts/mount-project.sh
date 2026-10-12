#!/usr/bin/env bash
# remote-harness / mount-project.sh
# Mount a project directory from an SSH-reachable host onto a LOCAL path with sshfs so the agent
# edits it as local files while changes land on the project host. The default mountpoint is the
# current directory and must be empty, so the remote project can cleanly become the project root and
# the mount does not hide existing files. Use --unmount to detach. Prints KEY=VALUE.
#
#   mount-project.sh --alias NAME --remote-path /path --ssh-config FILE [--mountpoint DIR] [--force]
#   mount-project.sh --alias NAME --unmount [--mountpoint DIR]
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }
note() { printf '%s\n' "$*" >&2; }
need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    note "missing value for $1"
    exit 2
  fi
}
safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

sshfs_install_hint(){   # the right install command for THIS machine's OS / package manager
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t  (no kernel extension / no reduced security)';;
    *) if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y sshfs'
       elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y fuse-sshfs'
       elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm sshfs'
       elif command -v zypper  >/dev/null 2>&1; then printf 'sudo zypper install -y sshfs'
       elif command -v apk     >/dev/null 2>&1; then printf 'sudo apk add sshfs'
       else printf "install 'sshfs' with your package manager"; fi;;
  esac
}

ALIAS="" RPATH="" MP="" SSH_CONFIG="" SESSION_ID="" UNMOUNT=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --alias)       need_arg "$1" "${2-}"; ALIAS="$2"; shift 2;;
    --remote-path) need_arg "$1" "${2-}"; RPATH="$2"; shift 2;;
    --mountpoint)  need_arg "$1" "${2-}"; MP="$2"; shift 2;;
    --ssh-config)  need_arg "$1" "${2-}"; SSH_CONFIG="$2"; shift 2;;
    --session-id)  need_arg "$1" "${2-}"; SESSION_ID="$2"; shift 2;;
    --unmount)     UNMOUNT=1; shift;;
    --force)       FORCE=1; shift;;
    *) shift;;
  esac
done
[ -n "$ALIAS" ] || { note "usage: mount-project.sh --alias NAME --remote-path /path [--mountpoint DIR] [--ssh-config FILE] [--force]"; note "       mount-project.sh --alias NAME --unmount [--mountpoint DIR]"; exit 2; }
safe_ssh_token "$ALIAS" || { note "unsafe ssh alias: $ALIAS"; exit 2; }
case "$SSH_CONFIG" in *'
'*) note "ssh config path contains a newline"; exit 2;; esac

# Default mountpoint = current directory.
[ -n "$MP" ] || MP="$PWD"

OS="$(uname -s 2>/dev/null || echo unknown)"
# The sshfs binary. On macOS the no-kext FUSE-T build (brew macos-fuse-t/homebrew-cask/sshfs-fuse-t)
# may install as `sshfs` or `sshfs-fuse-t`; prefer plain `sshfs` if present.
SSHFS_BIN=""; for c in sshfs sshfs-fuse-t; do command -v "$c" >/dev/null 2>&1 && { SSHFS_BIN="$c"; break; }; done

is_mounted() {
  _mp="$1"
  _canon="$(canon_mountpoint "$_mp")"
  if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1" && return 0; fi
  mount 2>/dev/null | grep -qF " $_mp " && return 0
  [ "$_canon" != "$_mp" ] && mount 2>/dev/null | grep -qF " $_canon " && return 0
  return 1
}
canon_mountpoint() {
  _cm_path="$1"
  _cm_dir="$(dirname "$_cm_path" 2>/dev/null || printf '.')"
  _cm_base="$(basename "$_cm_path" 2>/dev/null || printf '')"
  _cm_phys="$(cd "$_cm_dir" 2>/dev/null && pwd -P)" || { printf '%s' "$_cm_path"; return; }
  printf '%s/%s' "$_cm_phys" "$_cm_base"
}
# Is the mount at $1 actually ALIVE (not a stale/dead sshfs endpoint left by a dropped tunnel)?
mount_live() {
  if command -v timeout >/dev/null 2>&1; then timeout 5 ls "$1" >/dev/null 2>&1
  else ls "$1" >/dev/null 2>&1; fi
}
# Best-effort: the source (alias:/path) currently mounted at $1, from the mount table.
mounted_source() {
  _ms_canon="$(canon_mountpoint "$1")"
  mount 2>/dev/null | awk -v mp=" $1 " -v canon=" $_ms_canon " 'index($0,mp)||index($0,canon){print $1; exit}'
}
# systemd-logind KillUserProcesses=yes kills everything in an SSH login's session scope when that
# login ends: the sshfs started by the mount command, the agent, and the session watcher. Report it
# so the launcher can tell the user to fix the server instead of failing mysteriously later.
kill_user_processes_enabled() {
  [ "$(uname -s 2>/dev/null)" = Linux ] || return 1
  if command -v busctl >/dev/null 2>&1; then
    _kup=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager KillUserProcesses 2>/dev/null) && {
      [ "$_kup" = "b true" ]
      return
    }
  fi
  grep -hiEs '^[[:space:]]*KillUserProcesses[[:space:]]*=[[:space:]]*(yes|true|on|1)[[:space:]]*$' \
    /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf /run/systemd/logind.conf.d/*.conf \
    /usr/lib/systemd/logind.conf.d/*.conf >/dev/null 2>&1
}
emit_session_policy() {
  kill_user_processes_enabled && emit KILL_USER_PROCESSES 1
  return 0
}
# Progress markers for an interactive caller (the laptop's exit steps). Written only to the fd named
# by RH_PROGRESS_FD, never to stdout, which stays KEY=VALUE.
progress() {
  [ -n "${RH_PROGRESS_FD:-}" ] || return 0
  case "$RH_PROGRESS_FD" in *[!0-9]*) return 0;; esac
  { printf 'RH_PROGRESS=%s\n' "$1" >&"$RH_PROGRESS_FD"; } 2>/dev/null || true
}
# This user's sshfs daemons whose mountpoint argument is $1 or $2 (two spellings of one mountpoint).
sshfs_pids_for() {
  ps -ww -u "$(id -u)" -o pid= -o args= 2>/dev/null | awk -v a="$1" -v b="${2:-}" '
    { n = split($0, f, " ")
      if (n >= 4 && (f[2] == "sshfs" || f[2] ~ /\/sshfs$/) && (f[4] == a || (b != "" && f[4] == b))) print f[1] }'
}
mount_path_in_use() {  # any process of this user with its cwd or an open file under $1
  find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -user "$(id -u)" \
    \( -lname "$1" -o -lname "$1/*" \) -print -quit 2>/dev/null | grep -q .
}
io_signature() {  # cumulative read/write byte counters of the given pids
  for _ios_p in "$@"; do
    awk '/^(rchar|wchar):/ {printf "%s ", $2}' "/proc/$_ios_p/io" 2>/dev/null || printf 'gone '
  done
}
# A detached mount's sshfs should exit by itself, but one whose worker threads are still blocked on
# its SFTP connections (more likely with max_conns, or a dropped tunnel) can linger indefinitely.
# Stop it only when that is safe. After a clean unmount the kernel already guaranteed no open files
# (sshfs completes writes on close), so a 1s grace suffices. After a lazy (or earlier, unknown) detach
# nothing may still use the mountpoint, and the daemon itself must show no read/write progress for
# RH_SSHFS_IDLE_SECONDS (default 3); keepalives of its ssh connections are not its own I/O. A daemon
# still making progress is left running once RH_SSHFS_SYNC_MAX_SECONDS (default 120) passes. Its sftp
# ssh exits on EOF once sshfs is gone. Without /proc there is no reliable progress signal: no-op.
stop_detached_sshfs() {  # $1 = clean|lazy, $2/$3 = mountpoint spellings no longer in the mount table
  [ -d /proc/self ] || return 0
  _sds_mode="$1"; shift
  _sds_pids="$(sshfs_pids_for "$@")"
  [ -n "$_sds_pids" ] || return 0
  progress sshfs-wait
  _sds_limit="${RH_SSHFS_IDLE_SECONDS:-3}"
  if [ "$_sds_mode" = clean ]; then _sds_limit=1
  elif mount_path_in_use "$1"; then return 0; fi
  _sds_idle=0 _sds_waited=0 _sds_last=""
  while [ "$_sds_idle" -lt "$_sds_limit" ]; do
    [ "$_sds_waited" -lt "${RH_SSHFS_SYNC_MAX_SECONDS:-120}" ] || return 0  # still progressing: leave it
    _sds_waited=$((_sds_waited + 1))
    _sds_alive=""
    for _sds_p in $_sds_pids; do kill -0 "$_sds_p" 2>/dev/null && _sds_alive="$_sds_alive $_sds_p"; done
    _sds_pids="$_sds_alive"
    [ -n "$_sds_pids" ] || return 0                                         # exited by itself
    # shellcheck disable=SC2086
    _sds_now="$(io_signature $_sds_pids)"
    if [ "$_sds_now" = "$_sds_last" ]; then _sds_idle=$((_sds_idle + 1)); else _sds_idle=0 _sds_last="$_sds_now"; fi
    sleep 1
  done
  [ "$_sds_mode" = clean ] || ! mount_path_in_use "$1" || return 0
  note "remote-harness: stopping sshfs for detached $1 (no I/O progress)"
  for _sds_sig in TERM KILL; do
    # shellcheck disable=SC2086
    kill "-$_sds_sig" $_sds_pids 2>/dev/null || true
    _sds_i=0
    # shellcheck disable=SC2086
    while [ "$_sds_i" -lt 10 ] && kill -0 $_sds_pids 2>/dev/null; do sleep 0.5; _sds_i=$((_sds_i + 1)); done
    # shellcheck disable=SC2086
    kill -0 $_sds_pids 2>/dev/null || break
  done
  return 0
}
do_unmount() {
  _du_canon="$(canon_mountpoint "$1")"
  detach_mount "$1" "$_du_canon"
  _du_status=$?
  is_mounted "$1" && return 1
  progress unmounted
  # Also covers a mount an earlier lazy unmount already detached while its daemon stayed wedged.
  if [ "$_du_status" = 0 ]; then stop_detached_sshfs clean "$1" "$_du_canon"
  else stop_detached_sshfs lazy "$1" "$_du_canon"; fi
  [ "$_du_status" != 1 ]
}
detach_mount() {  # $1 = mountpoint, $2 = canonical spelling -> 0 clean, 2 lazy, 1 nothing detached
  for _du_target in "$1" "$2"; do
    [ -n "$_du_target" ] || continue
    fusermount -u "$_du_target" 2>/dev/null && return 0
    fusermount3 -u "$_du_target" 2>/dev/null && return 0
    umount "$_du_target" 2>/dev/null && return 0
    # A dead tunnel can leave the FUSE endpoint busy; lazily detach it as the unprivileged owner.
    # Files may still be open on a lazily detached mount.
    fusermount -uz "$_du_target" 2>/dev/null && return 2
    fusermount3 -uz "$_du_target" 2>/dev/null && return 2
    umount -l "$_du_target" 2>/dev/null && return 2
    [ "$_du_target" = "$2" ] && break
  done
  return 1
}

if [ "$UNMOUNT" = 1 ]; then
  do_unmount "$MP" || true
  if is_mounted "$MP"; then emit STATUS unmount-failed; emit ERROR "still mounted ($MP) — busy?"
  else emit STATUS unmounted; fi
  emit MOUNTPOINT "$MP"
  exit 0
fi

[ -n "$RPATH" ] || { note "need --remote-path"; exit 2; }
[ -n "$SSH_CONFIG" ] || { note "need --ssh-config (session-local config keeps SSH runtime files out of ~/.ssh)"; exit 2; }

if [ -n "$SESSION_ID" ]; then
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
  RH_REAPER_LIBRARY=1 . "$(dirname "$0")/session-reaper.sh" || exit 2
  unset RH_REAPER_LIBRARY
  lease_dir "$SESSION_ID" >/dev/null || { emit STATUS invalid-session; exit 2; }
  resource_lock || { emit STATUS registry-busy; exit 2; }
  trap resource_unlock EXIT
  MP="$(canon_mountpoint "$MP")"
  record=$(mount_record "$MP")
  if [ -f "$record" ] && [ "$(kv_b64 "$record" MOUNTPOINT)" != "$MP" ]; then
    emit STATUS registry-conflict
    exit 2
  fi
  if ! is_mounted "$MP" && [ -f "$record" ]; then
    if mount_used_elsewhere "" "$MP"; then
      emit STATUS mount-in-use
      emit ERROR 'registered users still own this missing mount; refusing to replace its transport'
      exit 2
    fi
    rm -f "$record"
  fi
fi

if [ -z "$SSHFS_BIN" ]; then
  emit STATUS need-sshfs; emit INSTALL_CMD "$(sshfs_install_hint)"
  note "sshfs is not installed. Install it once (the user runs the command above), then re-run."
  exit 3
fi

if is_mounted "$MP"; then
  want="$ALIAS:$RPATH"; have=""
  # On macOS/FUSE-T the mount source is an NFS loopback (not alias:path), so source-matching is
  # unreliable there. The mount table is whitespace-delimited too, so a source containing spaces
  # can't be parsed from $1 — in both cases skip the source match and rely on liveness only (else a
  # live, correct mount on a spaced path would be misread as "points elsewhere" and needlessly remounted).
  if [ "$OS" != Darwin ]; then
    case "$want" in
      *[[:space:]]*) ;;                       # spaced source: unparseable from the mount table
      *) have="$(mounted_source "$MP")";;
    esac
  fi
  # Reuse only a LIVE mount that points at the requested project; otherwise drop the stale/wrong
  # one and remount fresh (fixes the dropped-tunnel re-run that used to launch into a dead dir).
  if mount_live "$MP" && { [ -z "$have" ] || [ "$have" = "$want" ]; }; then
    if [ -n "$SESSION_ID" ]; then
      record=$(mount_record "$MP")
      mount_cfg=$(kv_b64 "$record" SSH_CONFIG)
      if [ "$(kv_b64 "$record" MOUNTPOINT)" != "$MP" ] || [ ! -f "$mount_cfg" ]; then
        emit STATUS untracked-mount
        emit ERROR 'live mount has no verified transport record; leave its session running or close it before retrying'
        exit 2
      fi
      register_mount_lease "$SESSION_ID" "$MP" "$SSH_CONFIG" "$mount_cfg" "$ALIAS" || exit 2
    fi
    emit STATUS already-mounted; emit MOUNTPOINT "$MP"; emit REMOTE "$want"
    emit_session_policy
    exit 0
  fi
  note "Existing mount at $MP is stale or points elsewhere (${have:-unknown}) — remounting as $want."
  if [ -n "$SESSION_ID" ] && mount_used_elsewhere "" "$MP"; then
    emit STATUS mount-in-use
    emit ERROR 'another session uses this mount; refusing to replace it'
    exit 2
  fi
  do_unmount "$MP" || true
  [ -z "$SESSION_ID" ] || rm -f "$(mount_record "$MP")"
fi

mkdir -p "$MP"
# SAFETY: refuse to mount onto a non-empty directory — sshfs would HIDE its contents, and for
# project-dir mounting the target must be empty so the remote project becomes the project root.
if [ "$FORCE" != 1 ] && [ -n "$(ls -A "$MP" 2>/dev/null)" ]; then
  emit STATUS not-empty
  emit MOUNTPOINT "$MP"
  note "Refusing to mount onto non-empty dir: $MP"
  note "Start Claude Code in a fresh EMPTY directory dedicated to this project and mount there,"
  note "or pass --force to override (will hide the current contents while mounted)."
  exit 4
fi

RH_HOME="${RH_HOME:-$HOME/.remote-harness}"
mkdir -p "$RH_HOME/.sessions" 2>/dev/null || true
err="$(mktemp "$RH_HOME/.sessions/rh-mount.XXXXXX" 2>/dev/null)" || err="${RH_HOME}/.sessions/rh-mount.$$"
# reconnect + keepalives so brief tunnel hiccups self-heal. idmap=user (libfuse sshfs) maps the
# remote uid → ours; omitted on macOS, where FUSE-T's sshfs mounts via NFS and doesn't accept it.
# We deliberately KEEP sshfs's default attribute/dir caching (no cache_timeout=0): disabling it
# slows stat-heavy operations — git status, editor file-watchers, tree-scanning builds — noticeably
# over the tunnel. The trade-off is a brief window where a just-written edit may not yet be visible
# to a remote `ssh <alias> 'cd … && build'`; the injected rule tells the agent to simply re-run the
# command once if a build fails right after an edit.
case "$OS" in
  Darwin) SSHFS_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks";;
  *)      SSHFS_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks,idmap=user";;
esac
SSH_BIN="$(command -v ssh 2>/dev/null || printf 'ssh')"
# Parallel SFTP connections keep one long scan (a whole-tree lstat over a high-latency tunnel) from
# queueing every other file request behind it. Only sshfs builds that advertise it get the option;
# RH_SSHFS_MAX_CONNS=1 turns it off.
MAX_CONNS="${RH_SSHFS_MAX_CONNS:-4}"
case "$MAX_CONNS" in ''|*[!0-9]*) MAX_CONNS=4;; esac
if [ "$MAX_CONNS" -gt 1 ] && "$SSHFS_BIN" --help 2>&1 | grep -q 'max_conns'; then
  [ "$MAX_CONNS" -le 16 ] || MAX_CONNS=16
  SSHFS_OPTS="$SSHFS_OPTS,max_conns=$MAX_CONNS"
fi
SSHFS_OPTS="$SSHFS_OPTS,ssh_command=$SSH_BIN -F $SSH_CONFIG"
if "$SSHFS_BIN" "$ALIAS:$RPATH" "$MP" -o "$SSHFS_OPTS" 2>"$err"; then
  _ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if is_mounted "$MP" && mount_live "$MP"; then _ready=1; break; fi
    sleep 1
  done
  if [ "$_ready" != 1 ]; then
    emit STATUS failed
    emit ERROR "sshfs exited 0 but the mount did not become live"
    do_unmount "$MP" || true
    rm -f "$err" 2>/dev/null || true
    exit 0
  fi
  if [ -n "$SESSION_ID" ]; then
    register_mount_lease "$SESSION_ID" "$MP" "$SSH_CONFIG" "$SSH_CONFIG" "$ALIAS" || exit 2
  fi
  emit STATUS mounted
  emit MOUNTPOINT "$MP"
  emit REMOTE "$ALIAS:$RPATH"
  emit_session_policy
  [ -d "$MP/.git" ] && emit GIT_BRANCH "$(git -C "$MP" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  # Claude Code reads CLAUDE.md, not AGENTS.md — flag if the project ships only AGENTS.md.
  [ -f "$MP/AGENTS.md" ] && [ ! -e "$MP/CLAUDE.md" ] && emit AGENTS_MD_ONLY 1
else
  emit STATUS failed
  emit ERROR "$(tr '\n' ' ' < "$err" 2>/dev/null | sed 's/  */ /g' | cut -c1-300)"
fi
rm -f "$err" 2>/dev/null || true
