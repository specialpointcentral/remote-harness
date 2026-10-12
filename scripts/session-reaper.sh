#!/usr/bin/env sh
# remote-harness / session-reaper.sh — RUNS ON THE AGENT HOST.
# Server-side cleanup for sessions whose local launcher never got to run its cleanup (laptop slept,
# terminal killed, network dropped, the remote side force-closed the connection, ...).
#
#   session-reaper.sh watch <session-dir>   detached per-session watcher started by the launcher
#   session-reaper.sh reap  <session-dir> [--session-only]
#   session-reaper.sh release <session-dir>   normal launcher cleanup, using the same resource lock
#   session-reaper.sh release-config <ssh-config>   USED=0 only after all references are gone
#   session-reaper.sh gc                    reap every dead session under $RH_HOME/.sessions
#
# A session is alive while its recorded agent process (pid + start time) exists. When it dies, or
# when its terminal was hung up but the agent lingers, the watcher waits a short grace period for the
# normal local cleanup, then removes whatever is left: the multiplexing master, leftover routed
# tool/command processes, the SSHFS mount (unless another live session uses it), the session dir, and
# the session SSH config with its private key (which also makes any stale local authorization inert).
# `gc` repeats this for every session at the next launch, covering watchers lost to a reboot.
# Release/query commands print KEY=VALUE; watcher/GC cleanup is silent on success.
set -u

RH_HOME="${RH_HOME:-$HOME/.remote-harness}"
SESSIONS="$RH_HOME/.sessions"
if [ "${RH_REAPER_LIBRARY:-0}" != 1 ]; then
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)"
fi
POLL="${RH_REAP_POLL:-5}"
GRACE="${RH_REAP_GRACE:-20}"
UNLAUNCHED_MINUTES="${RH_REAP_UNLAUNCHED_MINUTES:-30}"
ORPHAN_CONFIG_MINUTES="${RH_REAP_ORPHAN_CONFIG_MINUTES:-60}"
RESOURCE_LOCK_HELD=0

# All mount registration, release and GC decisions use this lock. A missing owner record is
# treated as uncertain; never steal a lock merely because its holder is slow.
resource_lock() {
  mkdir -p "$SESSIONS" || return 1
  RESOURCE_LOCK="$SESSIONS/.resources.lock"
  _rl_i=0
  while ! mkdir "$RESOURCE_LOCK" 2>/dev/null; do
    _rl_pid=$(kv "$RESOURCE_LOCK/owner" PID)
    case "$_rl_pid" in
      ''|*[!0-9]*) ;;
      *)
        _rl_start=$(kv_b64 "$RESOURCE_LOCK/owner" START)
        _rl_observed=$(process_start "$_rl_pid")
        if ! kill -0 "$_rl_pid" 2>/dev/null || { [ -n "$_rl_start" ] && [ -n "$_rl_observed" ] && [ "$_rl_observed" != "$_rl_start" ]; }; then
          rm -f "$RESOURCE_LOCK/owner" 2>/dev/null
          rmdir "$RESOURCE_LOCK" 2>/dev/null || true
        fi;;
    esac
    _rl_i=$((_rl_i + 1))
    [ "$_rl_i" -lt 30 ] || return 1
    sleep 1
  done
  printf 'PID=%s\nSTART=%s\n' "$$" "$(printf '%s' "$(process_start "$$")" | base64 | tr -d '\n')" > "$RESOURCE_LOCK/owner"
  RESOURCE_LOCK_HELD=1
}

resource_unlock() {
  [ "$RESOURCE_LOCK_HELD" = 1 ] || return 0
  rm -f "$RESOURCE_LOCK/owner" 2>/dev/null
  rmdir "$RESOURCE_LOCK" 2>/dev/null || true
  RESOURCE_LOCK_HELD=0
}

mount_record() {
  printf '%s/.mounts/%s.env' "$SESSIONS" "$(printf '%s' "$1" | cksum | awk '{print $1 "-" $2}')"
}

lease_dir() {
  case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1;; esac
  printf '%s/lease.%s' "$SESSIONS" "$1"
}

reference_live() {
  owner_state "$1"
  case $? in
    0) return 0;;
    2) recently_created "$2" "$UNLAUNCHED_MINUTES" && return 0;;
  esac
  return 1
}

# Register the actual mount transport separately from the session's command transport.
register_mount_lease() { # session id, physical mountpoint, command config, mount config, alias
  _rml_dir=$(lease_dir "$1") || return 1
  [ ! -f "$_rml_dir/lease.env" ] || return 1
  _rml_record=$(mount_record "$2")
  if [ -f "$_rml_record" ] && { [ "$(kv_b64 "$_rml_record" MOUNTPOINT)" != "$2" ] || [ "$(kv_b64 "$_rml_record" SSH_CONFIG)" != "$4" ]; }; then
    return 1
  fi
  mkdir -p "$_rml_dir" "$SESSIONS/.mounts" || return 1
  {
    printf 'MOUNTPOINT=%s\n' "$(printf '%s' "$2" | base64 | tr -d '\n')"
    printf 'SSH_CONFIG=%s\n' "$(printf '%s' "$3" | base64 | tr -d '\n')"
    printf 'MOUNT_SSH_CONFIG=%s\n' "$(printf '%s' "$4" | base64 | tr -d '\n')"
  } > "$_rml_dir/lease.env"
  if [ ! -f "$_rml_record" ]; then
    printf 'MOUNTPOINT=%s\nSSH_CONFIG=%s\nALIAS=%s\n' \
      "$(printf '%s' "$2" | base64 | tr -d '\n')" \
      "$(printf '%s' "$4" | base64 | tr -d '\n')" \
      "$(printf '%s' "$5" | base64 | tr -d '\n')" > "$_rml_record"
  fi
}

b64d() {
  if printf '' | base64 --decode >/dev/null 2>&1; then printf '%s' "$1" | base64 --decode
  elif printf '' | base64 -d >/dev/null 2>&1; then printf '%s' "$1" | base64 -d
  else printf '%s' "$1" | base64 -D; fi
}

kv() {  # $1=file $2=key -> raw value
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

kv_b64() {  # $1=file $2=key -> decoded value
  _kb_raw=$(kv "$1" "$2")
  [ -n "$_kb_raw" ] || return 0
  b64d "$_kb_raw" 2>/dev/null
}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

session_dir_ok() {  # only ever operate on direct children of $RH_HOME/.sessions
  case "$1" in
    "$SESSIONS"/*) ;;
    *) return 1 ;;
  esac
  _sdo_rest=${1#"$SESSIONS"/}
  case "$_sdo_rest" in ""|.*|*/*) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ]
}

ssh_config_ok() {  # per-launch session SSH config: $RH_HOME/.sessions/<dir>/ssh_config
  case "$1" in "$SESSIONS"/*/ssh_config) ;; *) return 1 ;; esac
  _sco_rest=${1#"$SESSIONS"/}
  case "$_sco_rest" in .*|*/*/*) return 1 ;; esac
  [ ! -L "$(dirname "$1")" ] || return 1
  return 0
}

process_start() { trim "$(ps -p "$1" -o lstart= 2>/dev/null)"; }

# 0 = agent alive, 1 = agent gone, 2 = never launched (no owner record yet)
owner_state() {
  _os_file="$1/owner.env"
  [ -f "$_os_file" ] || return 2
  [ -r "$_os_file" ] || return 0
  _os_pid=$(kv "$_os_file" OWNER_PID)
  case "$_os_pid" in ""|*[!0-9]*) return 0 ;; esac
  kill -0 "$_os_pid" 2>/dev/null || return 1
  _os_start=$(kv_b64 "$_os_file" OWNER_START)
  _os_observed=$(process_start "$_os_pid")
  [ -n "$_os_observed" ] || return 0
  if [ -n "$_os_start" ] && [ "$_os_observed" != "$_os_start" ]; then
    return 1  # pid reused by an unrelated process
  fi
  return 0
}

# The agent was launched on a terminal, but that terminal is gone (connection force-closed).
owner_detached() {
  _od_file="$1/owner.env"
  case "$(kv_b64 "$_od_file" OWNER_TTY)" in /dev/*) ;; *) return 1 ;; esac
  _od_tty=$(trim "$(ps -p "$(kv "$_od_file" OWNER_PID)" -o tty= 2>/dev/null)")
  case "$_od_tty" in ""|"?"|"??") return 0 ;; esac
  return 1
}

terminate_owner() {
  _to_pid=$(kv "$1/owner.env" OWNER_PID)
  case "$_to_pid" in ""|*[!0-9]*) return 0 ;; esac
  for _to_signal in HUP TERM KILL; do
    owner_state "$1" || return 0
    kill "-$_to_signal" "$_to_pid" 2>/dev/null || return 0
    _to_i=0
    while [ "$_to_i" -lt 10 ]; do
      owner_state "$1" || return 0
      sleep 1
      _to_i=$((_to_i + 1))
    done
  done
}

recently_created() {  # $1=file $2=minutes
  _rc_found=$(find "$1" -mmin "-$2" 2>/dev/null) || return 0
  [ -n "$_rc_found" ]
}

# Does an SSHFS transport referencing $1 (a session SSH config or its directory) still serve a
# mounted mountpoint? A daemon that outlived its unmount, and the sftp ssh it leaves behind, do not
# keep anything in use: counting them would retain the laptop tunnel and authorization for nothing.
sshfs_transport_live() {
  ps -ww -u "$(id -u)" -o args= 2>/dev/null | awk -v ref="$1" '
    { n = split($0, f, " ")
      if (n >= 3 && (f[1] == "sshfs" || f[1] ~ /\/sshfs$/) && index($0, ref)) print f[3] }' |
  while IFS= read -r _stl_mp; do
    mount 2>/dev/null | grep -qF " $_stl_mp " && { echo live; break; }
  done | grep -q live
}

# Is any process of this user referencing the given path in its arguments?
path_in_use() {
  _piu_list=$(ps -ww -u "$(id -u)" -o pid= -o args= 2>/dev/null) || return 0
  printf '%s\n' "$_piu_list" | while read -r _piu_pid _piu_args; do
    [ "$_piu_pid" = "$$" ] && continue
    case "$_piu_args" in *session-reaper.sh*|*sshfs*|*' sftp'*) continue ;; esac  # SSHFS: see below
    case "$_piu_args" in *"$1"*) echo yes; break ;; esac
  done | grep -q yes || sshfs_transport_live "$1"
}

# Is the mountpoint still used by a different live (or about-to-launch) session?
mount_used_elsewhere() {  # $1=this session dir $2=mountpoint
  for _mue_meta in "$SESSIONS"/lease.*/lease.env; do
    [ -f "$_mue_meta" ] || continue
    _mue_sd=$(dirname "$_mue_meta")
    [ "$_mue_sd" = "$(kv_b64 "$1/session.env" LEASE_DIR)" ] && continue
    [ "$(kv_b64 "$_mue_meta" MOUNTPOINT)" = "$2" ] || continue
    reference_live "$_mue_sd" "$_mue_meta" && return 0
  done
  for _mue_meta in "$SESSIONS"/*/session.env; do
    [ -f "$_mue_meta" ] || continue
    _mue_sd=$(dirname "$_mue_meta")
    [ "$_mue_sd" = "$1" ] && continue
    [ "$(kv_b64 "$_mue_meta" MOUNTPOINT)" = "$2" ] || continue
    owner_state "$_mue_sd"
    case $? in
      0) return 0 ;;
      2) recently_created "$_mue_meta" "$UNLAUNCHED_MINUTES" && return 0 ;;
    esac
  done
  return 1
}

config_used_elsewhere() {  # $1=this session dir $2=ssh config
  for _cue_meta in "$SESSIONS"/lease.*/lease.env; do
    [ -f "$_cue_meta" ] || continue
    _cue_sd=$(dirname "$_cue_meta")
    [ "$_cue_sd" = "$(kv_b64 "$1/session.env" LEASE_DIR)" ] && continue
    if [ "$(kv_b64 "$_cue_meta" SSH_CONFIG)" = "$2" ] || [ "$(kv_b64 "$_cue_meta" MOUNT_SSH_CONFIG)" = "$2" ]; then
      reference_live "$_cue_sd" "$_cue_meta" && return 0
    fi
  done
  # A mount that could not be released still owns its transport, even without a live agent.
  for _cue_record in "$SESSIONS"/.mounts/*.env; do
    [ -f "$_cue_record" ] || continue
    [ "$(kv_b64 "$_cue_record" SSH_CONFIG)" = "$2" ] && return 0
  done
  for _cue_meta in "$SESSIONS"/*/session.env; do
    [ -f "$_cue_meta" ] || continue
    _cue_sd=$(dirname "$_cue_meta")
    [ "$_cue_sd" = "$1" ] && continue
    [ "$(kv_b64 "$_cue_meta" SSH_CONFIG)" = "$2" ] || continue
    owner_state "$_cue_sd"
    case $? in
      0) return 0 ;;
      2) recently_created "$_cue_meta" "$UNLAUNCHED_MINUTES" && return 0 ;;
    esac
  done
  # Legacy mounts may lack a registry record. Keep the config a still-mounted SSHFS transport uses.
  sshfs_transport_live "$2"
}

# Terminate leftover routed processes of this session: tool shims, multiplexing clients/master, and
# Bash runners. The SSHFS process (sshfs / its sftp ssh child) is left to the unmount step.
kill_session_processes() {  # $1=session dir $2=ssh config (may be empty)
  ps -ww -u "$(id -u)" -o pid= -o args= 2>/dev/null | while read -r _ksp_pid _ksp_args; do
    [ "$_ksp_pid" = "$$" ] && continue
    case "$_ksp_args" in *session-reaper.sh*|*inject-rule.sh*|*sshfs*|*sftp*) continue ;; esac
    _ksp_match=0
    if [ -n "$1" ]; then case "$_ksp_args" in *"$1"/*) _ksp_match=1 ;; esac; fi
    if [ "$_ksp_match" = 0 ] && [ -n "$2" ]; then
      case "$_ksp_args" in *"$2"*) _ksp_match=1 ;; esac
    fi
    [ "$_ksp_match" = 1 ] && kill -TERM "$_ksp_pid" 2>/dev/null
  done
  return 0
}

remove_ssh_config() {  # mirrors the local launcher's box-side cleanup
  ssh_config_ok "$1" || return 0
  _rsc_dir=$(dirname "$1")
  # The last reference may belong to a different session than the transport creator.
  if [ -S "$_rsc_dir/runtime/mux" ]; then
    ssh -F /dev/null -o "ControlPath=$_rsc_dir/runtime/mux" -O exit rh-mux >/dev/null 2>&1 || true
  fi
  kill_session_processes "" "$1"
  rm -f "$1" "$_rsc_dir/id_ed25519" "$_rsc_dir/id_ed25519.pub" 2>/dev/null || true
  rm -rf "$_rsc_dir/runtime" 2>/dev/null || true
  rmdir "$_rsc_dir" 2>/dev/null || true
}

reap() {  # $1=session dir $2=--session-only?
  sd=$1
  mode=full
  [ "${2:-}" = --session-only ] && mode=session
  session_dir_ok "$sd" || return 0
  meta="$sd/session.env"
  mp=""; alias_name=""; cfg=""; control=""; lease=""; mount_cfg=""
  if [ -f "$meta" ]; then
    mp=$(kv_b64 "$meta" MOUNTPOINT)
    alias_name=$(kv_b64 "$meta" ALIAS)
    cfg=$(kv_b64 "$meta" SSH_CONFIG)
    control=$(kv_b64 "$meta" CONTROL_PATH)
    lease=$(kv_b64 "$meta" LEASE_DIR)
    mount_cfg=$(kv_b64 "$meta" MOUNT_SSH_CONFIG)
  fi
  if [ "$mode" = full ] && [ -n "$mp" ] && ! mount_used_elsewhere "$sd" "$mp"; then
    _reap_mount_tool="$sd/impl/mount-project.sh"
    [ -x "$_reap_mount_tool" ] || _reap_mount_tool="$SCRIPT_DIR/mount-project.sh"
    _reap_out=$("$_reap_mount_tool" --alias "${alias_name:-remote-harness}" --unmount \
      --mountpoint "$mp" 2>/dev/null) || _reap_out=""
    if printf '%s\n' "$_reap_out" | grep -q '^STATUS=unmounted$'; then
      rm -f "$(mount_record "$mp")"
      case "$mp" in "$RH_HOME/mounts/"*) rmdir "$mp" 2>/dev/null || true;; esac
    else
      printf 'remote-harness: retaining mount transport after unsuccessful unmount\n' >&2
    fi
  fi
  cfg_shared=0
  [ -z "$cfg" ] || { config_used_elsewhere "$sd" "$cfg" && cfg_shared=1; }
  if [ "$cfg_shared" = 0 ] && [ -n "$control" ] && [ -S "$control" ]; then
    ssh -F /dev/null -o "ControlPath=$control" -O exit rh-mux >/dev/null 2>&1 || true
    rm -f "$control" 2>/dev/null || true
  fi
  _reap_kill_cfg=""
  [ "$cfg_shared" = 1 ] || _reap_kill_cfg="$cfg"
  kill_session_processes "$sd" "$_reap_kill_cfg"
  case "$lease" in "$SESSIONS"/lease.*) session_dir_ok "$lease" && rm -rf "$lease";; esac
  impl_needed=0
  for _reap_record in "$SESSIONS"/.mounts/*.env; do
    [ -f "$_reap_record" ] || continue
    [ "$(kv_b64 "$_reap_record" IMPLEMENTATION)" = "$sd/impl" ] && impl_needed=1
  done
  if [ "$impl_needed" = 0 ]; then rm -rf "$sd" 2>/dev/null || true; fi

  if [ "$mode" = full ] && [ -n "$cfg" ] && ! config_used_elsewhere "$sd" "$cfg"; then
    remove_ssh_config "$cfg"
  fi
  if [ "$mode" = full ] && [ -n "$mount_cfg" ] && [ "$mount_cfg" != "$cfg" ] && ! config_used_elsewhere "$sd" "$mount_cfg"; then
    remove_ssh_config "$mount_cfg"
  fi
}

release_session() {
  resource_lock || return 1
  trap resource_unlock EXIT
  trap 'resource_unlock; exit 1' HUP INT TERM
  session_dir_ok "$1" || return 0
  if [ -d "$1" ] && owner_state "$1"; then
    printf 'STATUS=active\n'
    return 1
  fi
  if [ -f "$1/lease.env" ] && [ ! -f "$1/session.env" ]; then
    _rs_lease="$1/lease.env"
    printf 'MOUNTPOINT=%s\nSSH_CONFIG=%s\nLEASE_DIR=%s\nMOUNT_SSH_CONFIG=%s\n' \
      "$(kv "$_rs_lease" MOUNTPOINT)" "$(kv "$_rs_lease" SSH_CONFIG)" \
      "$(printf '%s' "$1" | base64 | tr -d '\n')" "$(kv "$_rs_lease" MOUNT_SSH_CONFIG)" > "$1/session.env"
  fi
  reap "$1" "${2:-}"
  printf 'STATUS=released\n'
}

watch() {
  sd=$1
  session_dir_ok "$sd" || exit 0
  waited=0
  while [ -d "$sd" ]; do
    owner_state "$sd"
    case $? in
      0)
        owner_detached "$sd" && terminate_owner "$sd"
        ;;
      2)
        # The launcher writes the owner record before starting the watcher; give up eventually.
        waited=$((waited + POLL))
        [ "$waited" -lt 600 ] || exit 0
        ;;
      *)
        sleep "$GRACE"
        [ -d "$sd" ] && release_session "$sd"
        exit 0
        ;;
    esac
    sleep "$POLL"
  done
}

gc() {
  mkdir -p "$SESSIONS" 2>/dev/null || return 0
  resource_lock || return 0
  trap resource_unlock EXIT
  trap 'resource_unlock; exit 1' HUP INT TERM

  for gc_meta in "$SESSIONS"/*/session.env; do
    [ -f "$gc_meta" ] || continue
    gc_sd=$(dirname "$gc_meta")
    owner_state "$gc_sd"
    case $? in
      0) continue ;;
      2)
        recently_created "$gc_meta" "$UNLAUNCHED_MINUTES" && continue
        path_in_use "$gc_sd" && continue
        ;;
    esac
    reap "$gc_sd"
  done

  for gc_lease in "$SESSIONS"/lease.*/lease.env; do
    [ -f "$gc_lease" ] || continue
    gc_ld=$(dirname "$gc_lease")
    reference_live "$gc_ld" "$gc_lease" && continue
    # An early launch that never reached injection has no watcher; release its mount lease too.
    gc_mp=$(kv_b64 "$gc_lease" MOUNTPOINT)
    gc_cfg=$(kv_b64 "$gc_lease" SSH_CONFIG)
    printf 'MOUNTPOINT=%s\nSSH_CONFIG=%s\nLEASE_DIR=%s\nMOUNT_SSH_CONFIG=%s\n' \
      "$(kv "$gc_lease" MOUNTPOINT)" "$(kv "$gc_lease" SSH_CONFIG)" \
      "$(printf '%s' "$gc_ld" | base64 | tr -d '\n')" "$(kv "$gc_lease" MOUNT_SSH_CONFIG)" > "$gc_ld/session.env"
    reap "$gc_ld"
  done

  # A failed mount release before injection may have no agent session to drive a later retry.
  for gc_mount in "$SESSIONS"/.mounts/*.env; do
    [ -f "$gc_mount" ] || continue
    gc_mp=$(kv_b64 "$gc_mount" MOUNTPOINT)
    [ -n "$gc_mp" ] || continue
    mount_used_elsewhere "" "$gc_mp" && continue
    gc_cfg=$(kv_b64 "$gc_mount" SSH_CONFIG)
    gc_impl=$(kv_b64 "$gc_mount" IMPLEMENTATION)
    gc_mount_tool="$gc_impl/mount-project.sh"
    [ -x "$gc_mount_tool" ] || gc_mount_tool="$SCRIPT_DIR/mount-project.sh"
    gc_out=$("$gc_mount_tool" --alias remote-harness --unmount --mountpoint "$gc_mp" 2>/dev/null) || gc_out=""
    if printf '%s\n' "$gc_out" | grep -q '^STATUS=unmounted$'; then
      rm -f "$gc_mount"
      [ -z "$gc_cfg" ] || { config_used_elsewhere "" "$gc_cfg" || remove_ssh_config "$gc_cfg"; }
    fi
  done

  # Session SSH configs (with their private keys) whose launch never reached rule injection.
  for gc_cfg in "$SESSIONS"/*/ssh_config; do
    [ -f "$gc_cfg" ] || continue
    ssh_config_ok "$gc_cfg" || continue
    recently_created "$gc_cfg" "$ORPHAN_CONFIG_MINUTES" && continue
    config_used_elsewhere "" "$gc_cfg" && continue
    path_in_use "$(dirname "$gc_cfg")" && continue
    remove_ssh_config "$gc_cfg"
  done
}

if [ "${RH_REAPER_LIBRARY:-0}" != 1 ]; then
case "${1:-}" in
  watch) [ -n "${2:-}" ] || exit 2; watch "$2" ;;
  reap|release) [ -n "${2:-}" ] || exit 2; release_session "$2" "${3:-}" ;;
  config-used|release-config)
    [ -n "${2:-}" ] || exit 2
    resource_lock || exit 2
    trap resource_unlock EXIT
    trap 'resource_unlock; exit 1' HUP INT TERM
    if config_used_elsewhere "" "$2" || path_in_use "$2"; then
      printf 'USED=1\n'
    else
      [ "$1" != release-config ] || remove_ssh_config "$2"
      printf 'USED=0\n'
    fi
    ;;
  gc) gc ;;
  *) echo "usage: session-reaper.sh watch <session-dir> | reap <session-dir> [--session-only] | gc" >&2; exit 2 ;;
esac
fi
