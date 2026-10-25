#!/usr/bin/env bash
# remote-harness / laptop-setup.sh — run ON YOUR LAPTOP.
#
# Full flow (all in one command, no editing required):
#   Phase 1 — Ensure SSH server on, write RemoteForward to a session ssh config
#   Phase 2 — Reconnect automatically (establishes the reverse tunnel)
#   Phase 3 — Pick a project dir on THIS laptop (readline prompt, defaults to cwd)
#   Phase 4 — Mount the chosen dir on the remote box via sshfs (over the tunnel)
#   Phase 5 — Launch the chosen agent (claude/codex/opencode) on the box in the mounted dir (ssh -tt)
#
# Usage (emitted by the skill — paste as-is). This script sources _common.sh from beside it, so the
# command fetches BOTH files into one temp dir (the laptop usually has no install):
#   (
#     mkdir -p "$HOME/.remote-harness/.sessions"
#     d=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit
#     trap 'rm -rf "$d"' EXIT
#     ssh -o ClearAllForwardings=yes <CONNECT> 'cat ~/.remote-harness/scripts/_common.sh'      >"$d/_common.sh" &&
#     ssh -o ClearAllForwardings=yes <CONNECT> 'cat ~/.remote-harness/scripts/laptop-setup.sh' >"$d/laptop-setup.sh" &&
#     bash "$d/laptop-setup.sh" --host <HOST> --port <PORT> --via '<CONNECT>' --box-alias <ALIAS>
#   )
#
# Flags:
#   --host <alias|ip>     ssh entry used to reach the box; a dedicated harness alias is managed
#   --port <PORT>         RemoteForward port on the remote (required)
#   --via <ssh-args>      exact ssh args to reach the box (e.g. "-p 2222 user@1.2.3.4")
#   --box-alias <name>    alias the BOX uses to reach back to this laptop (default: <user>-mac)
#   --box-ssh-config <f>  box-side ssh config file for that alias (session-local; required
#                         for full sessions; optional with --setup-only)
#   --pubkey <key>        remote-harness public key to authorize temporarily in authorized_keys
#   --box-user <user>     remote box username (for mount path and alias naming)
#   --remote-mountpoint <d>  exact box dir to mount the project at (must be empty;
#                            default: <remote $RH_HOME>/mounts/<project-name>)
#   --project-dir <d>     laptop project dir to mount (validated; prompts again if invalid)
#   --launch <cmd>        coding-agent CLI to start on the remote (default: claude;
#                         Codex passes 'codex', opencode passes 'opencode')
#   --approval <mode>     approvals on the launched agent: 'auto' (default; claude
#                         --permission-mode auto, codex --approve-for-me, normal where the CLI
#                         lacks it), 'normal' (the agent asks), or 'yolo' (same as --yolo)
#   --yolo                bypass approvals on the launched agent — claude/codex get their
#                         bypass flag; opencode gets a temporary permission=allow config (restored)
#   --local-sshd <mode>   SSH server the tunnel reaches on this laptop: 'system' (default; the
#                         sshd on :22 reading ~/.ssh/authorized_keys) or 'user' (a per-session sshd
#                         run as you on a free loopback port, for sshds that ignore authorized_keys
#                         such as FreeIPA/sssd). Defaults to $RH_LOCAL_SSHD when set.
#   --setup-only          stop after Phase 1 — skip reconnect / dir-pick / mount / launch
#   --yes                 non-interactive (skip all confirm prompts)
set -uo pipefail

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

# ---- argument parsing -----------------------------------------------------
HOST="" PORT="" PUBKEY="" VIA="" BOX_ALIAS="" BOX_SSH_CONFIG="" ASSUME_YES=0 SETUP_ONLY=0
BOX_USER="" REMOTE_MP="" LAUNCH="claude" PROJ_DIR_ARG=""
APPROVAL=auto; EFF_LAUNCH=""; LAUNCH_BASE="claude"
LOCAL_SSHD_MODE="${RH_LOCAL_SSHD:-system}"
while [ $# -gt 0 ]; do
  case "$1" in
    --host)          need_arg "$1" "${2-}"; HOST="$2";           shift 2;;
    --port)          need_arg "$1" "${2-}"; PORT="$2";           shift 2;;
    --pubkey)        need_arg "$1" "${2-}"; PUBKEY="$2";         shift 2;;
    --via)           need_arg "$1" "${2-}"; VIA="$2";            shift 2;;
    --launch)        need_arg "$1" "${2-}"; LAUNCH="$2";         shift 2;;   # CLI to start on the remote (claude/codex/opencode)
    --approval)      need_arg "$1" "${2-}"; APPROVAL="$2";       shift 2;;   # normal|auto|yolo
    --yolo)          APPROVAL=yolo;       shift;;     # bypass approvals on the launched agent
    --box-alias)     need_arg "$1" "${2-}"; BOX_ALIAS="$2";      shift 2;;
    --box-ssh-config) need_arg "$1" "${2-}"; BOX_SSH_CONFIG="$2"; shift 2;;
    --box-user)      need_arg "$1" "${2-}"; BOX_USER="$2";       shift 2;;
    --remote-mountpoint) need_arg "$1" "${2-}"; REMOTE_MP="$2";  shift 2;;   # exact box dir to mount at (e.g. your invoking cwd)
    --project-dir)   need_arg "$1" "${2-}"; PROJ_DIR_ARG="$2";   shift 2;;   # laptop project dir (skip the interactive prompt)
    --local-sshd)    need_arg "$1" "${2-}"; LOCAL_SSHD_MODE="$2"; shift 2;;
    --setup-only)    SETUP_ONLY=1;        shift;;
    --yes|-y)        ASSUME_YES=1;        shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$PORT" ] || { printf 'need --port\n' >&2; exit 2; }
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { printf 'port must be numeric: %s\n' "$PORT" >&2; exit 2; }
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { printf 'port out of range: %s\n' "$PORT" >&2; exit 2; }
case "$APPROVAL" in
  normal|auto|yolo) ;;
  *) printf 'unsupported --approval %s (expected normal|auto|yolo)\n' "$APPROVAL" >&2; exit 2;;
esac
case "$LOCAL_SSHD_MODE" in
  system|auto|"") LOCAL_SSHD_MODE=system;;
  user) [ "$SETUP_ONLY" = 0 ] || { printf -- '--local-sshd user needs a full session (not --setup-only)\n' >&2; exit 2; };;
  *) printf 'unsupported --local-sshd %s (expected system|user)\n' "$LOCAL_SSHD_MODE" >&2; exit 2;;
esac

# ---- shared helpers (colors, say/ok/warn/err/hdr/ask, sq, OS vars, parse_via, ssh-config) -------
# laptop-setup.sh is fetched to the laptop and run STANDALONE (the laptop usually has no install),
# so the skill's one-command fetches _common.sh next to this file and we source it by path.
RH_COMMON="${RH_COMMON:-$(dirname "$0")/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else printf 'error: missing _common.sh next to %s — re-copy the full command\n' "$0" >&2; exit 2; fi

# Its own RH_LAPTOP_STEPS steps, after any simple-laptop-setup.sh steps (RH_STEP_BASE).
STEP_TOTAL=$((STEP_N + RH_LAPTOP_STEPS))

# ---- auto-cleanup on exit/disconnect ---------------------------------------
TUNNEL_PID=""; TUNNEL_START=""; MOUNTED=0; CLEANED=0; RULE_INJECTED=0; RCU_DETAIL=""; RELEASE_DETAIL=""
LOCAL_SESSION_DIR=""; LOCAL_SSH_CONFIG=""; RULE_SESSION_ID=""
# The tunnel's laptop end: :22 for the system sshd, or the per-session user-mode sshd's port.
LOCAL_SSHD_PORT=22; LOCAL_SSHD_DIR=""; LOCAL_SSHD_PID=""; LOCAL_SSHD_START=""; LOCAL_SSHD_CFG=""
REMOTE_SESSION_DIR=""
# The box logs into THIS laptop as the box alias's `User`, so the login user must be US. The laptop's
# own `id -un` is the single source of truth (whatever the box-side setup guessed, e.g. from a
# project path); we force the box alias to it in Phase 2. In the simple reverse flow remote-harness
# may temporarily authorize the box's generated key in ~/.ssh/authorized_keys, with a scoped managed
# block that is removed on exit.
LAPTOP_USER="$(id -un 2>/dev/null || echo user)"

box_ssh_f_arg() {
  [ -n "${BOX_SSH_CONFIG:-}" ] && printf -- '-F %s' "$(sq "$BOX_SSH_CONFIG")"
}
box_check_config_arg() {
  [ -n "${BOX_SSH_CONFIG:-}" ] && printf ' --ssh-config %s' "$(sq "$BOX_SSH_CONFIG")"
}
box_setup_config_arg() {
  [ -n "${BOX_SSH_CONFIG:-}" ] && printf ' --config %s' "$(sq "$BOX_SSH_CONFIG")"
}
ssh_uses_session_config() {
  [ -n "${LOCAL_SSH_CONFIG:-}" ] && [ -n "${TARGET:-}" ] || return 1
  local _need_value=0 _target="" _arg
  for _arg in "$@"; do
    if [ "$_need_value" = 1 ]; then _need_value=0; continue; fi
    case "$_arg" in
      -F|-F*) return 1;;
      -b|-c|-D|-E|-e|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w) _need_value=1; continue;;
      -b*|-c*|-D*|-E*|-e*|-I*|-i*|-J*|-L*|-l*|-m*|-O*|-o*|-p*|-Q*|-R*|-S*|-W*|-w*) continue;;
      -*) continue;;
      *) _target="$_arg"; break;;
    esac
  done
  [ "$_target" = "$TARGET" ]
}
# Every setup call to the box is a fresh SSH connection, which costs seconds on a high-latency link
# (TCP + key exchange + authentication). Once the session config exists, a multiplexing master carries
# those calls instead; until its socket appears they simply connect directly. It is passed on the
# command line only (generated ssh_config files keep ControlMaster no) and lives under a short /tmp
# path because macOS limits socket path length. The reverse tunnel (-N, it owns the RemoteForward),
# control commands (-O, -M) and the interactive agent session (-t/-tt: a multiplexed session from
# macOS was seen to get a 0x0 pty, which leaves the agent's TUI unable to redraw) keep their own
# connection; callers pass those flags as separate words.
SETUP_MUX_DIR=""
ssh() {
  if ssh_uses_session_config "$@"; then
    case " $* " in
      *" -N "*|*" -O "*|*" -M "*|*" -t "*|*" -tt "*) ;;
      *) if [ -S "$SETUP_MUX_DIR/m" ]; then
           command ssh -F "$LOCAL_SSH_CONFIG" -o ControlMaster=no -o "ControlPath=$SETUP_MUX_DIR/m" "$@"
           # Explicit status: a bare return inside the EXIT-trap cleanup would report the status the
           # script exited with instead of this ssh's, so a failed launch could never release its tunnel.
           return $?
         fi ;;
    esac
    command ssh -F "$LOCAL_SSH_CONFIG" "$@"
  else
    command ssh "$@"
  fi
}
start_setup_mux() {  # in the background, overlapping the local authorization work
  SETUP_MUX_DIR=$(mktemp -d /tmp/rh.XXXXXX 2>/dev/null) || { SETUP_MUX_DIR=""; return 0; }
  # No forwards on the master: the separate tunnel connection owns the RemoteForward port.
  command ssh -F "$LOCAL_SSH_CONFIG" -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o ControlMaster=yes -o "ControlPath=$SETUP_MUX_DIR/m" -o ControlPersist=300 -fN "$TARGET" \
    >/dev/null 2>&1 </dev/null &
}
stop_setup_mux() {
  [ -n "$SETUP_MUX_DIR" ] || return 0
  [ ! -S "$SETUP_MUX_DIR/m" ] || command ssh -o "ControlPath=$SETUP_MUX_DIR/m" -O exit rh-setup >/dev/null 2>&1 || true
  rm -rf "$SETUP_MUX_DIR" 2>/dev/null || true
  SETUP_MUX_DIR=""
}
# Legacy marker path, used only to remove a marker that matches a verified resource-record PID.
# New tunnel ownership (PID + start time + exact config) is stored under the local session dir.
tunnel_state_path() {
  printf '%s/.remote-harness/.tunnel-%s.pid' "$HOME" \
    "$(printf '%s-%s' "${TARGET:-}" "${PORT:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
}
# Release a specific transport under the remote resource lock; an uncertain response retains it.
# Returns 1 when released, 0 when another session uses it, 3 when the server is unreachable (ssh
# itself failed), 2 for any other unclear answer. RCU_DETAIL explains a result that retains it.
remote_config_usage() {
  local _out _rc _used
  _out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
    "rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"; \"\$rh/scripts/session-reaper.sh\" release-config $(sq "$BOX_SSH_CONFIG")" 2>/dev/null)
  _rc=$?
  # Trust the reaper's verdict line even when the remote shell added output or a non-zero exit:
  # it prints USED=0 only after it has already removed the box-side config.
  _used=$(printf '%s\n' "$_out" | sed -n 's/^USED=\([01]\)$/\1/p' | tail -1)
  case "$_used" in
    0) RCU_DETAIL=""; return 1;;
    1) RCU_DETAIL="another remote session still uses this transport"; return 0;;
  esac
  if [ "$_rc" = 255 ] && [ -z "$_out" ]; then
    RCU_DETAIL="remote host unreachable"
    return 3
  fi
  RCU_DETAIL="remote release check failed (ssh exit $_rc${_out:+: $(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-160)})"
  return 2
}

resource_value() { # records are base64 values, never executable shell configuration
  local _raw
  _raw=$(sed -n "s/^$2=//p" "$1" | head -1)
  if [ "$OS" = Darwin ]; then printf '%s' "$_raw" | base64 -D
  else printf '%s' "$_raw" | base64 --decode; fi
}

RESOURCE_FIELDS="TARGET PORT BOX_SSH_CONFIG LOCAL_SSH_CONFIG TUNNEL_PID TUNNEL_START AUTHKEY_TYPE AUTHKEY_BLOB AUTHKEY_TAG AUTHKEY_BEGIN AUTHKEY_END AUTHKEY_REF_DIR AUTHKEY_TOKEN AUTHKEY_MANAGED GATEWAY_SESSION_DIR LOCAL_SSHD_PID LOCAL_SSHD_START LOCAL_SSHD_CFG"

write_local_resource_record() {
  [ -n "$LOCAL_SESSION_DIR" ] || return 0
  local _name _value
  {
    for _name in $RESOURCE_FIELDS; do
      _value="${!_name}"
      printf '%s=%s\n' "$_name" "$(printf '%s' "$_value" | base64 | tr -d '\n')"
    done
    printf 'OWNER_PID=%s\nOWNER_START=%s\n' "$$" "$(proc_start "$$" | base64 | tr -d '\n')"
  } > "$LOCAL_SESSION_DIR/resources.env.tmp" && mv "$LOCAL_SESSION_DIR/resources.env.tmp" "$LOCAL_SESSION_DIR/resources.env"
}

# Stop a recorded process only while it is still the same one (start time and command line match);
# one that is gone, or whose pid now has another start time, counts as stopped.
kill_recorded() {  # pid recorded-start args-needle
  case "$1" in ''|*[!0-9]*) return 0;; esac
  [ -n "$2" ] && [ -n "$3" ] && [ "$(proc_start "$1")" = "$2" ] || return 0
  case "$(ps -ww -p "$1" -o args= 2>/dev/null)" in *"$3"*) kill "$1" 2>/dev/null;; *) return 1;; esac
}

release_local_resources() { # only release records whose exact remote config is confirmed unused
  local _dir="$1" _file="$1/resources.env" _usage _name _state_file _delay _step
  # shellcheck disable=SC2086 # declares each record field as a local name.
  local $RESOURCE_FIELDS
  [ -f "$_file" ] && [ ! -L "$_dir" ] || return 1
  for _name in $RESOURCE_FIELDS; do
    printf -v "$_name" '%s' "$(resource_value "$_file" "$_name")"
  done
  [ -n "$TARGET" ] && [ -n "$BOX_SSH_CONFIG" ] || return 1
  remote_config_usage
  _usage=$?
  # A dropped network often comes back within a minute; retry before deciding for this session.
  if [ "$_usage" = 3 ] && [ "$_dir" = "$LOCAL_SESSION_DIR" ]; then
    _step=$STEP_LABEL
    for _delay in ${RH_RELEASE_RETRY_DELAYS:-10 20 30}; do
      step_label "$(tr2 "Remote host unreachable; retrying in ${_delay}s" "远端不可达，${_delay} 秒后重试")"
      sleep "$_delay"
      remote_config_usage
      _usage=$?
      [ "$_usage" = 3 ] || break
    done
    [ -z "$STEP_LABEL" ] || STEP_LABEL=$_step
  fi
  [ "$_dir" != "$LOCAL_SESSION_DIR" ] || RELEASE_DETAIL="$RCU_DETAIL"
  # A shared config or an unclear answer retains everything. An unreachable server retains only a
  # tunnel this launch did not create; its own tunnel is stopped below, after which the server can no
  # longer use the sshd or authorization either, and the remote watcher cleans up its side.
  case "$_usage" in
    1) ;;
    3) [ -n "$TUNNEL_PID" ] || return 1 ;;
    *) return 1 ;;
  esac
  kill_recorded "$TUNNEL_PID" "$TUNNEL_START" "$LOCAL_SSH_CONFIG" || return 1
  # The user-mode sshd lives exactly as long as the tunnel that reaches it.
  kill_recorded "$LOCAL_SSHD_PID" "$LOCAL_SSHD_START" "$LOCAL_SSHD_CFG" || return 1
  cleanup_reverse_authorized_key || return 1
  _state_file=$(tunnel_state_path)
  if [ -n "$TUNNEL_PID" ] && [ "$(cat "$_state_file" 2>/dev/null)" = "$TUNNEL_PID" ]; then rm -f "$_state_file"; fi
  rm -rf "$_dir"
}

sweep_local_resources() {
  local _dir _file _pid _start _actual
  for _dir in "$HOME/.remote-harness/.sessions"/rev.*; do
    [ -f "$_dir/resources.env" ] && [ ! -L "$_dir" ] || continue
    if [ "$_dir" = "$LOCAL_SESSION_DIR" ] && [ "$CLEANED" != 1 ]; then continue; fi
    _file="$_dir/resources.env"
    _pid=$(sed -n 's/^OWNER_PID=//p' "$_file" | head -1)
    _start=$(resource_value "$_file" OWNER_START)
    case "$_pid" in ''|*[!0-9]*) continue;; esac
    _actual=$(proc_start "$_pid")
    if [ "$_dir" != "$LOCAL_SESSION_DIR" ] && [ -n "$_start" ] && [ "$_start" = "$_actual" ]; then continue; fi
    release_local_resources "$_dir" || true
  done
}

# -- temporary authorized_keys management -----------------------------------
# The only intentional ~/.ssh write in the simple reverse path is a tagged,
# loopback-scoped authorized_keys block for the remote-harness key generated on
# the box. Everything else (ssh config, known_hosts) remains under
# ~/.remote-harness.
AUTHKEY_TYPE="" AUTHKEY_BLOB="" AUTHKEY_TAG="" AUTHKEY_BEGIN="" AUTHKEY_END=""
AUTHKEY_REF_DIR="" AUTHKEY_TOKEN="" AUTHKEY_MANAGED=0 AUTHKEY_LOCK_DIR="" AUTHKEY_LOCK_HELD=0
GATEWAY_DIR="" GATEWAY_PATH="" GATEWAY_SESSION_DIR=""

authkey_lock() {
  [ "$AUTHKEY_LOCK_HELD" = 1 ] && return 0
  AUTHKEY_LOCK_DIR="$HOME/.remote-harness/.locks/authorized_keys.lock.d"
  mkdir -p "$(dirname "$AUTHKEY_LOCK_DIR")" 2>/dev/null || return 1
  _n=0
  while ! mkdir "$AUTHKEY_LOCK_DIR" 2>/dev/null; do
    _n=$((_n + 1))
    [ "$_n" -ge 30 ] && return 1
    sleep 1
  done
  AUTHKEY_LOCK_HELD=1
  return 0
}

authkey_unlock() {
  [ "$AUTHKEY_LOCK_HELD" = 1 ] || return 0
  rmdir "$AUTHKEY_LOCK_DIR" 2>/dev/null || true
  AUTHKEY_LOCK_HELD=0
}

parse_pubkey_for_authorized_keys() {
  [ -n "$PUBKEY" ] || return 1
  case "$PUBKEY" in *'
'*) warn "box public key contains a newline; not modifying authorized_keys"; return 1;; esac
  # shellcheck disable=SC2086 # deliberate field split of the public key line.
  set -- $PUBKEY
  AUTHKEY_TYPE="${1:-}"
  AUTHKEY_BLOB="${2:-}"
  case "$AUTHKEY_TYPE" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) warn "box public key type is not recognized: ${AUTHKEY_TYPE:-<empty>}"; return 1;;
  esac
  [ -n "$AUTHKEY_BLOB" ] || { warn "box public key is missing key material"; return 1; }
  case "$AUTHKEY_BLOB" in *[!A-Za-z0-9+/=]*|"") warn "box public key material is invalid"; return 1;; esac
  AUTHKEY_TAG="$(printf '%s %s' "$AUTHKEY_TYPE" "$AUTHKEY_BLOB" | cksum | awk '{print $1 "-" $2}')"
  AUTHKEY_BEGIN="# >>> remote-harness:reverse-auth:$AUTHKEY_TAG >>>"
  AUTHKEY_END="# <<< remote-harness:reverse-auth:$AUTHKEY_TAG <<<"
  AUTHKEY_REF_DIR="$HOME/.remote-harness/.sessions/authorized-keys/$AUTHKEY_TAG"
  AUTHKEY_TOKEN="$AUTHKEY_REF_DIR/$$.$(date +%s 2>/dev/null || echo now)"
  return 0
}

authorized_key_match() {
  _ak_scope="$1"
  _ak_file="$2"
  [ -r "$_ak_file" ] || return 1
  awk -v t="$AUTHKEY_TYPE" -v k="$AUTHKEY_BLOB" -v b="$AUTHKEY_BEGIN" -v e="$AUTHKEY_END" -v scope="$_ak_scope" '
    $0==b {managed=1; next}
    $0==e {managed=0; next}
    /^[[:space:]]*($|#)/ {next}
    {
      line_has_key=0
      for (i=1; i<NF; i++) {
        if ($i==t && $(i+1)==k) line_has_key=1
      }
      if (line_has_key && (scope=="any" || (scope=="managed" && managed) || (scope=="user" && !managed))) found=1
    }
    END {exit found ? 0 : 1}
  ' "$_ak_file"
}

write_authorized_keys_without_managed_block() {
  _ak_file="$1"
  _ak_dir="$(dirname "$_ak_file")"
  mkdir -p "$_ak_dir" 2>/dev/null || return 1
  chmod 700 "$_ak_dir" 2>/dev/null || true
  _ak_tmp="$(mktemp "$_ak_dir/.authorized_keys.XXXXXX" 2>/dev/null)" || return 1
  if [ -f "$_ak_file" ]; then
    awk -v b="$AUTHKEY_BEGIN" -v e="$AUTHKEY_END" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$_ak_file" > "$_ak_tmp" || { rm -f "$_ak_tmp"; return 1; }
  fi
  chmod 600 "$_ak_tmp" 2>/dev/null || true
  mv "$_ak_tmp" "$_ak_file"
}

authorized_command_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

install_project_host_gateway() {
  _ipg_scripts="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || return 1
  [ -f "$_ipg_scripts/project-host-gateway.sh" ] && [ -f "$_ipg_scripts/run-on-project-host.sh" ] \
    || { warn "missing project-host gateway scripts beside laptop-setup.sh"; return 1; }
  GATEWAY_SESSION_DIR="$HOME/.remote-harness/.sessions/gateways/$AUTHKEY_TAG"
  GATEWAY_DIR="$GATEWAY_SESSION_DIR/bin"
  GATEWAY_PATH="$GATEWAY_DIR/project-host-gateway.sh"
  mkdir -p "$GATEWAY_DIR" "$GATEWAY_SESSION_DIR" 2>/dev/null || return 1
  chmod 700 "$GATEWAY_DIR" "$GATEWAY_SESSION_DIR" 2>/dev/null || true
  # A reused session key keeps the same implementation; a new key gets its own snapshot.
  if [ ! -f "$GATEWAY_PATH" ]; then
    cp "$_ipg_scripts/project-host-gateway.sh" "$GATEWAY_PATH" || return 1
    cp "$_ipg_scripts/run-on-project-host.sh" "$GATEWAY_DIR/run-on-project-host.sh" || return 1
  fi
  chmod 700 "$GATEWAY_PATH" "$GATEWAY_DIR/run-on-project-host.sh" 2>/dev/null || return 1
}

register_gateway_project() {
  [ -n "$GATEWAY_SESSION_DIR" ] || return 1
  _rgp_root=$(printf '%s' "$PROJ_DIR" | base64 | tr -d '\n')
  if [ -f "$GATEWAY_SESSION_DIR/project-root.b64" ] && [ "$(cat "$GATEWAY_SESSION_DIR/project-root.b64")" != "$_rgp_root" ]; then
    warn "session key is already registered for another project; refusing to change its gateway"
    return 1
  fi
  printf '%s' "$_rgp_root" > "$GATEWAY_SESSION_DIR/project-root.b64" \
    || return 1
  chmod 600 "$GATEWAY_SESSION_DIR/project-root.b64" 2>/dev/null || true
}

append_managed_authorized_key() {
  _ak_file="$1"
  _ak_command="$(sq "$GATEWAY_PATH") $(sq "$AUTHKEY_TAG")"
  write_authorized_keys_without_managed_block "$_ak_file" || return 1
  {
    [ -s "$_ak_file" ] && printf '\n'
    printf '%s\n' "$AUTHKEY_BEGIN"
    printf '# scope: remote-harness reverse tunnel; source limited to laptop loopback via from=127.0.0.1,::1\n'
    printf 'from="127.0.0.1,::1",command="%s",no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty %s %s remote-harness:reverse:%s\n' \
      "$(authorized_command_escape "$_ak_command")" "$AUTHKEY_TYPE" "$AUTHKEY_BLOB" "$AUTHKEY_TAG"
    printf '%s\n' "$AUTHKEY_END"
  } >> "$_ak_file" || return 1
  chmod 600 "$_ak_file" 2>/dev/null || true
}

prepare_reverse_authorized_key() {
  if [ -z "$PUBKEY" ]; then
    if [ "$LOCAL_SSHD_MODE" = user ]; then
      warn "user-mode sshd needs the box's session public key (--pubkey)"
      return 1
    fi
    warn "No remote-harness public key was provided; the box must already be authorized to SSH back to this laptop."
    return 0
  fi
  parse_pubkey_for_authorized_keys || return 1
  # The user-mode sshd reads only its own authorized_keys, so ~/.ssh stays untouched.
  _ak_file="$HOME/.ssh/authorized_keys" _ak_label="authorized_keys: temporarily authorized"
  if [ "$LOCAL_SSHD_MODE" = user ]; then
    _ak_file="$LOCAL_SSHD_DIR/authorized_keys" _ak_label="user-mode sshd: authorized"
  fi

  authkey_lock || { warn "could not lock authorized_keys; not modifying SSH authorization"; return 1; }
  local _rc=0
  update_authorized_key_locked || _rc=$?
  authkey_unlock
  return "$_rc"
}

# Body of prepare_reverse_authorized_key, run while holding the authorized_keys lock; its caller
# releases the lock on every path.
update_authorized_key_locked() {
  if authorized_key_match user "$_ak_file"; then
    warn "authorized_keys contains the session key without the forced gateway; refusing unsafe reuse"
    return 1
  fi

  install_project_host_gateway || return 1

  mkdir -p "$AUTHKEY_REF_DIR" 2>/dev/null || return 1
  printf 'pid=%s\nstarted=%s\n' "$$" "$(date 2>/dev/null || true)" > "$AUTHKEY_TOKEN" 2>/dev/null || return 1

  # Only the ~/.ssh block is managed (reference-counted and removed on exit); the private file goes
  # away with its session directory.
  [ "$LOCAL_SSHD_MODE" = user ] || AUTHKEY_MANAGED=1

  if authorized_key_match managed "$_ak_file"; then
    ok "authorized_keys: reusing existing remote-harness temporary authorization"
    return 0
  fi

  if append_managed_authorized_key "$_ak_file"; then
    ok "$_ak_label the forced project-host gateway"
    return 0
  fi

  rm -f "$AUTHKEY_TOKEN" 2>/dev/null || true
  AUTHKEY_TOKEN=""
  AUTHKEY_MANAGED=0
  warn "could not update $_ak_file"
  return 1
}

cleanup_reverse_authorized_key() {
  [ -n "${AUTHKEY_TOKEN:-}" ] || return 0
  authkey_lock || { warn "could not lock authorized_keys for cleanup; temporary authorization may remain"; return 1; }
  local _rc=0
  release_authorized_key_locked || _rc=$?
  authkey_unlock
  return "$_rc"
}

# Body of cleanup_reverse_authorized_key, run while holding the authorized_keys lock: drop this
# launch's reference, and the managed block and gateway registration once no reference is left.
release_authorized_key_locked() {
  rm -f "$AUTHKEY_TOKEN" 2>/dev/null || true
  if [ -d "$AUTHKEY_REF_DIR" ] && find "$AUTHKEY_REF_DIR" -type f -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  rmdir "$AUTHKEY_REF_DIR" 2>/dev/null || true
  if [ "$AUTHKEY_MANAGED" = 1 ] && [ -f "$HOME/.ssh/authorized_keys" ]; then
    if write_authorized_keys_without_managed_block "$HOME/.ssh/authorized_keys"; then
      ok "authorized_keys: temporary remote-harness authorization removed"
    else
      warn "could not remove temporary remote-harness authorized_keys block"
      return 1
    fi
  fi
  [ -z "$GATEWAY_SESSION_DIR" ] || rm -rf "$GATEWAY_SESSION_DIR" 2>/dev/null || true
}

cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  [ -z "$STEP_LABEL" ] || step_end fail
  write_local_resource_record
  local _total=0 _line _rc=""
  [ "$MOUNTED" = 1 ] && _total=2
  [ -z "$LOCAL_SESSION_DIR" ] || _total=$((_total + 1))
  step_reset "$_total"
  [ "$_total" = 0 ] && { stop_setup_mux; return 0; }
  sep
  say "  $(tr2 "Connection closed — releasing this session's resources" "连接已关闭，正在释放本次会话的资源")"
  if [ "$MOUNTED" = 1 ]; then
    local _wait_label
    _wait_label="$(tr2 "Waiting for sshfs to flush and exit" "等待 sshfs 刷写完成并退出")"
    to_wait_step() { [ "$STEP_N" != 1 ] || { step_end "${1:-ok}"; step_begin "$_wait_label"; }; }
    step_begin "$(tr2 "Unmounting the remote project" "卸载远端挂载")"
    # The remote release reports progress on stderr (RH_PROGRESS=...): once the mount is detached,
    # the next step waits for sshfs to flush and exit, which can take a while on a slow link.
    while IFS= read -r _line; do
      case "$_line" in
        RH_PROGRESS=unmounted) to_wait_step ;;
        RH_PROGRESS=sshfs-wait)
          step_label "$(tr2 "Waiting for sshfs to flush and exit (still transferring or stuck)" "等待 sshfs 刷写完成并退出（仍在传输或已卡住）")" ;;
        RH_RC=*) _rc=${_line#RH_RC=} ;;
      esac
    done < <(
      ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" "
        rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
        sd=$(sq "$REMOTE_SESSION_DIR")
        reaper=\"\$sd/impl/session-reaper.sh\"
        if [ ! -x \"\$reaper\" ] || [ ! -x \"\$sd/impl/mount-project.sh\" ]; then reaper=\"\$rh/scripts/session-reaper.sh\"; fi
        if [ ! -d \"\$sd\" ]; then sd=\"\$rh/.sessions/lease.$RULE_SESSION_ID\"; fi
        RH_PROGRESS_FD=3 \"\$reaper\" release \"\$sd\" 3>&2 || exit 1
        ld=\"\$rh/.sessions/lease.$RULE_SESSION_ID\"
        if [ -d \"\$ld\" ]; then \"\$rh/scripts/session-reaper.sh\" release \"\$ld\"; fi
      " 2>&1 >/dev/null
      printf 'RH_RC=%s\n' "$?"
    )
    to_wait_step "$([ "$_rc" = 0 ] && echo ok || echo warn)"
    if [ "$_rc" = 0 ]; then
      step_end ok
    else
      step_end warn "$(tr2 "remote release incomplete; retaining local resources until it can be verified" "远端释放未完成；在确认之前保留本机资源")"
    fi
  fi
  if [ -n "$LOCAL_SESSION_DIR" ]; then
    step_begin "$(tr2 "Removing the local tunnel and temporary authorization" "移除本机隧道与临时授权")"
    sweep_local_resources
    if [ -d "$LOCAL_SESSION_DIR" ]; then
      step_end warn "$(tr2 "shared or unverified transport retained with its config and authorization" "传输仍被共享或无法确认，已保留其配置与授权")${RELEASE_DETAIL:+ ($RELEASE_DETAIL)}"
    else
      step_end ok
    fi
  fi
  step_reset 0
  stop_setup_mux
}

# OS vars (OS/PLAT/IS_WSL) come from _common.sh.
printf "\n${_B}remote-harness${_0} laptop setup  ${_C}port=%s${_0}  platform=%s\n\n" "$PORT" "$PLAT"

# Resolve YOLO into the effective launch command per agent.
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac
EFF_LAUNCH="$LAUNCH"
LAUNCH_BASE="$LAUNCH"
if [ "$APPROVAL" = yolo ]; then
  case "$LAUNCH_BASE" in
    claude)   EFF_LAUNCH="$LAUNCH --dangerously-skip-permissions";              warn "YOLO: claude --dangerously-skip-permissions";;
    codex)    EFF_LAUNCH="$LAUNCH --dangerously-bypass-approvals-and-sandbox";  warn "YOLO: codex --dangerously-bypass-approvals-and-sandbox";;
    opencode) warn "YOLO: opencode permission=allow (set in this session's config only — nothing global)";;
  esac
fi

# ===========================================================================
# Phase 1: SSH server check, user-managed auth note, RemoteForward in session ssh config
# ===========================================================================

# -- parse --via into V_HOST/V_PORT/V_USER/V_IDENTITY (parse_via from _common.sh) --
parse_via "$VIA"
[ -z "${V_UNSUPPORTED_SSH_OPTIONS:-}" ] || {
  printf 'unsupported ssh option(s) in --via:%s\n' "$V_UNSUPPORTED_SSH_OPTIONS" >&2
  printf 'Put complex ssh options in ~/.ssh/config as a Host alias, then pass that alias.\n' >&2
  exit 2
}
[ -z "$V_HOST" ] && [ -n "$HOST" ] && V_HOST="$HOST"
[ -z "$BOX_USER" ] && BOX_USER="$V_USER"
[ -z "$V_HOST" ] || safe_ssh_token "$V_HOST" || { printf 'unsafe ssh host in --via: %s\n' "$V_HOST" >&2; exit 2; }
[ -z "$HOST" ] || safe_ssh_token "$HOST" || { printf 'unsafe --host: %s\n' "$HOST" >&2; exit 2; }
[ -z "$BOX_ALIAS" ] || safe_ssh_token "$BOX_ALIAS" || { printf 'unsafe --box-alias: %s\n' "$BOX_ALIAS" >&2; exit 2; }
[ -z "$BOX_USER" ] || safe_ssh_token "$BOX_USER" || { printf 'unsafe --box-user: %s\n' "$BOX_USER" >&2; exit 2; }
case "$BOX_SSH_CONFIG" in *'
'*) printf 'box ssh config path contains a newline\n' >&2; exit 2;; esac

step_begin -s "$(tr2 "Local checks (SSH server, git, rg) and temporary authorization" "检查本机环境（SSH 服务、git、rg）与临时授权")"
# -- SSH authentication boundary -------------------------------------------
if [ -n "$PUBKEY" ]; then
  ok "box key visible: $(printf '%s' "$PUBKEY" | awk '{print $1, substr($2,1,14)"...", $3}')"
fi
if [ "$LOCAL_SSHD_MODE" = user ]; then
  say  "  Reverse auth: a per-session sshd reads only its own authorized_keys; ~/.ssh is not modified."
else
  say  "  Reverse auth: remote-harness may add a tagged temporary entry to ~/.ssh/authorized_keys."
  say  "  A matching unrestricted key is rejected; only the managed forced-gateway entry is reusable."
fi

# -- ensure SSH server running --
ssh_listening() { ! local_port_free 22; }
if [ "$LOCAL_SSHD_MODE" = user ]; then
  # Started after the session authorization exists; only its binary is needed now.
  if _usd_bin=$(user_sshd_bin); then
    ok "SSH server: user-mode sshd ($_usd_bin) on a free loopback port, this session only"
  else
    err "user-mode sshd: no sshd binary found (install openssh-server; it does not need to run)"
    exit 1
  fi
elif ssh_listening; then
  ok "SSH server: listening on :22"
else
  if [ "$PLAT" = macos ]; then
    ask "  SSH server (Remote Login) seems OFF. Enable it?" && \
      { sudo systemsetup -setremotelogin on && ok "Remote Login ON" \
        || warn "enable in System Settings > General > Sharing > Remote Login"; }
  else
    if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
      if command -v apt-get >/dev/null 2>&1; then
        ask "  sshd not found. Install via apt-get?" && sudo apt-get install -y openssh-server
      elif command -v dnf >/dev/null 2>&1; then
        ask "  sshd not found. Install via dnf?" && sudo dnf install -y openssh-server
      elif command -v pacman >/dev/null 2>&1; then
        ask "  sshd not found. Install via pacman?" && sudo pacman -S --noconfirm openssh
      elif command -v apk >/dev/null 2>&1; then
        ask "  sshd not found. Install via apk?" && sudo apk add openssh
      else
        warn "sshd not found and no supported package manager was detected; install OpenSSH server manually."
      fi
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      ask "  Enable & start ssh (sudo systemctl enable --now ssh)?" && \
        { sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null; }
    elif command -v service >/dev/null 2>&1; then
      # No systemd (common on WSL / OpenRC / SysV) — fall back to the service wrapper.
      ask "  Start ssh (sudo service ssh start)?" && \
        { sudo service ssh start 2>/dev/null || sudo service sshd start 2>/dev/null; }
    elif [ -x /etc/init.d/ssh ] || [ -x /etc/init.d/sshd ]; then
      ask "  Start ssh (sudo /etc/init.d/ssh start)?" && \
        { sudo /etc/init.d/ssh start 2>/dev/null || sudo /etc/init.d/sshd start 2>/dev/null; }
    fi
  fi
  ssh_listening && ok "SSH server: listening" \
                || warn "still not listening on :22 — the tunnel won't work without it"
fi

# Routed git/rg calls run on THIS machine; when one is missing the agent host falls back to scanning
# the project over SSHFS, which is very slow on a high-latency link. Look it up exactly as the
# gateway does and say so before launch.
check_project_host_tools() {
  local _finder _tool _path _why _hint
  _finder="$(dirname "$0")/run-on-project-host.sh"
  [ -f "$_finder" ] || return 0
  for _tool in git rg; do
    if _path=$(sh "$_finder" --find-tool "$_tool" 2>/dev/null); then
      ok "project host: $_tool found ($_path)"
      continue
    fi
    case "$_tool" in
      git) _why="the agent's git status/diff/log"; _hint=$(pkg_install_hint git)
           [ "$PLAT" != macos ] || _hint="xcode-select --install" ;;
      rg)  _why="the agent's file search and Grep"; _hint=$(pkg_install_hint ripgrep) ;;
    esac
    warn "project host: $_tool not found — $_why fall back to scanning over SSHFS (slow)"
    say  "    Install: ${_B}${_hint}${_0}"
  done
}
check_project_host_tools

# -- write RemoteForward to a session-local ssh config --
TARGET=""   # write_managed_alias comes from _common.sh and writes to $CFG.
load_effective_ssh_alias() {
  local _alias="$1" _cfg _identity
  _cfg="$(ssh -G "$_alias" 2>/dev/null || true)"
  [ -n "$_cfg" ] || return 1
  V_HOST=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="hostname"{print $2; exit}')
  V_PORT=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="port"{print $2; exit}')
  V_USER=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="user"{print $2; exit}')
  V_PROXYJUMP=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="proxyjump" && $2!="none"{print $2; exit}')
  # The session Host is a new name, so options the user's `Host <alias>` block supplies only by name
  # (e.g. a gcloud IAP ProxyCommand) must be carried over explicitly.
  V_PROXYCOMMAND=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="proxycommand" && $2!="none"{sub(/^[^ \t]+[ \t]+/, ""); print; exit}')
  V_IDENTITIESONLY=$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="identitiesonly" && ($2=="yes" || $2=="no"){print $2; exit}')
  V_IDENTITY=""
  while IFS= read -r _identity; do
    case "$_identity" in "~/"*) _identity="$HOME/${_identity#"~/"}";; esac
    if [ -f "$_identity" ]; then V_IDENTITY="$_identity"; break; fi
  done <<EOF
$(printf '%s\n' "$_cfg" | awk 'tolower($1)=="identityfile"{print $2}')
EOF
  return 0
}
# The --via connection is the GROUND TRUTH for how to reach the box. Use a DEDICATED session-local
# alias for the harness connection even when --via is a normal `Host <alias>` alias; ordinary
# `ssh <alias>` remains untouched.
RAW_CONN=0; { [ -n "$V_PORT" ] || [ -n "$V_USER" ] || [ -n "$V_IDENTITY" ] || [ -n "$V_PROXYJUMP" ]; } && RAW_CONN=1
if [ "$RAW_CONN" = 0 ] && [ -n "$HOST" ]; then
  load_effective_ssh_alias "$HOST" || warn "ssh config: could not resolve Host '$HOST' with ssh -G; using it as HostName"
fi
[ -z "${V_HOST:-}" ] || safe_ssh_token "$V_HOST" || { printf 'unsafe resolved ssh HostName: %s\n' "$V_HOST" >&2; exit 2; }
[ -z "${V_USER:-}" ] || safe_ssh_token "$V_USER" || { printf 'unsafe resolved ssh User: %s\n' "$V_USER" >&2; exit 2; }
[ -z "${V_PROXYJUMP:-}" ] || safe_ssh_token "$V_PROXYJUMP" || { printf 'unsafe resolved ssh ProxyJump: %s\n' "$V_PROXYJUMP" >&2; exit 2; }
TARGET="${HOST:-${BOX_USER:-${V_USER:-box}}}-remote-harness"
safe_target="$(printf '%s' "$TARGET" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//; s/[._-]*$//')"
[ -n "$safe_target" ] || safe_target=box
mkdir -p "$HOME/.remote-harness/.sessions" 2>/dev/null || true
LOCAL_SESSION_DIR="$(mktemp -d "$HOME/.remote-harness/.sessions/rev.XXXXXX")" || exit 2
RULE_SESSION_ID="$(basename "$LOCAL_SESSION_DIR")"
LOCAL_SSH_CONFIG="$LOCAL_SESSION_DIR/ssh_config"
CFG="$LOCAL_SSH_CONFIG"; touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
write_session_ssh_defaults "$LOCAL_SESSION_DIR" \
  || { err "could not create session SSH runtime directory"; exit 1; }
write_target_forward() {
  local _port="$1" _rf_line
  _rf_line="    RemoteForward $_port 127.0.0.1:$LOCAL_SSHD_PORT"
  # Create-or-replace a DEDICATED session alias carrying the exact --via identity + RemoteForward.
  # Keepalives so a half-open tunnel (NAT idle / laptop sleep) is detected;
  # ExitOnForwardFailure so a port-collision fails loudly instead of leaving a live-but-no-forward
  # connection that polls as "up".
  if write_managed_alias "$TARGET" "$_rf_line" \
      "    ServerAliveInterval 30" "    ServerAliveCountMax 3" \
      "    ExitOnForwardFailure yes" "    TCPKeepAlive yes" \
      "    ForwardAgent no"; then
    ok "ssh config: prepared session Host '$TARGET' (HostName ${V_HOST:-?}, port ${V_PORT:-22}, user ${V_USER:-<login default>}${V_PROXYCOMMAND:+, ProxyCommand}) + RemoteForward $_port"
  else
    err "ssh config: could not write session Host '$TARGET'"
    return 1
  fi
}
# The user-mode sshd's forward is written once it has bound its port, after the cleanup trap exists.
if [ "$LOCAL_SSHD_MODE" != user ]; then
  write_target_forward "$PORT" || exit 2
fi
say "    Session ssh alias: ${_B}ssh $TARGET${_0}"
chmod 600 "$CFG" 2>/dev/null || true

# -- default box-alias --
if [ -z "$BOX_ALIAS" ]; then
  BOX_ALIAS="${LAPTOP_USER}-mac"
fi

# == Phase 1 done ==
if [ "$SETUP_ONLY" = 1 ]; then
  step_end ok
  ok "Phase 1 done (--setup-only)."
  say "  Session config: ${_B}$LOCAL_SSH_CONFIG${_0}"
  say "  Reconnect: ${_B}ssh -F $(sq "$LOCAL_SSH_CONFIG") $TARGET${_0}"
  exit 0
fi
[ -n "$BOX_SSH_CONFIG" ] || {
  err "need --box-ssh-config for a full reverse session; run through simple-laptop-setup.sh"
  exit 2
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
if [ "$LOCAL_SSHD_MODE" = user ]; then
  LOCAL_SSHD_DIR="$LOCAL_SESSION_DIR/sshd"
  user_sshd_start "$LOCAL_SSHD_DIR" "$LAPTOP_USER"
  _usd_rc=$?
  if [ -n "$USER_SSHD_PID" ]; then
    LOCAL_SSHD_PID="$USER_SSHD_PID" LOCAL_SSHD_START="$USER_SSHD_START" LOCAL_SSHD_CFG="$USER_SSHD_CFG"
    write_local_resource_record
  fi
  if [ "$_usd_rc" = 3 ]; then
    err "user-mode sshd: sshd StrictModes would refuse its keys: $USER_SSHD_UNSAFE_DIR is writable by group/others or not owned by you"
    say "    $(tr2 "Fix it, then rerun:" "修复后重新运行：") ${_B}chmod go-w $(sq "$USER_SSHD_UNSAFE_DIR")${_0}"
    exit 1
  fi
  if [ "$_usd_rc" != 0 ]; then
    err "user-mode sshd did not start"
    user_sshd_log_reasons "$USER_SSHD_LOG" 8 | sed 's/^/    /'
    exit 1
  fi
  LOCAL_SSHD_PORT="$USER_SSHD_PORT"
  write_target_forward "$PORT" || exit 2
  chmod 600 "$CFG" 2>/dev/null || true
  ok "user-mode sshd: listening on 127.0.0.1:$LOCAL_SSHD_PORT (pid $LOCAL_SSHD_PID)"
fi
start_setup_mux
prepare_reverse_authorized_key || exit 1
write_local_resource_record
sweep_local_resources
step_end ok

# ===========================================================================
# Phase 2: Reconnect — establish the reverse tunnel automatically
# ===========================================================================
step_begin "$(tr2 "Establishing the reverse tunnel" "建立反向隧道")"

# Listening TCP ports on the box, one per line (ss -> netstat -an [GNU/BSD] -> lsof), matching
# check-tunnel.sh; extracts the port from host:PORT or BSD host.PORT.
REMOTE_LISTENING_PORTS="{ if command -v ss >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print \$4}';
       elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print \$4}';
       elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print \$9}';
       fi; } | sed -E 's/.*[:.]([0-9]+)\$/\1/'"
remote_port_listening() {
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=3 "$TARGET" \
    "$REMOTE_LISTENING_PORTS | grep -qx $(sq "$1")" 2>/dev/null
}
tunnel_alias_up() {
  local _port="$1" out laptop_host laptop_user local_host local_user
  out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    if [ -x \"\$rh/scripts/check-tunnel.sh\" ]; then
      \"\$rh/scripts/check-tunnel.sh\" --alias $(sq "$BOX_ALIAS") --port $(sq "$_port")$(box_check_config_arg)
    else
      ssh $(box_ssh_f_arg) -o BatchMode=yes -o ConnectTimeout=5 $(sq "$BOX_ALIAS") 'printf \"RH_OK %s %s\" \"\$(hostname 2>/dev/null)\" \"\$(id -un 2>/dev/null)\"'
    fi
  " 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -q '^SSH=up'; then
    laptop_host=$(printf '%s\n' "$out" | kv_value LAPTOP_HOSTNAME)
    laptop_user=$(printf '%s\n' "$out" | kv_value LAPTOP_USER)
  elif printf '%s' "$out" | grep -q '^RH_OK'; then
    laptop_host=$(printf '%s' "$out" | awk '{print $2}')
    laptop_user=$(printf '%s' "$out" | awk '{print $3}')
  else
    return 1
  fi
  local_host=$(hostname 2>/dev/null || true)
  local_user=$(id -un 2>/dev/null || true)
  [ -z "$laptop_host" ] || [ -z "$local_host" ] || [ "$laptop_host" = "$local_host" ] || return 1
  [ -z "$laptop_user" ] || [ -z "$local_user" ] || [ "$laptop_user" = "$local_user" ] || return 1
  return 0
}

# First port from $1 through $1+200 that is not listening on the box (one round trip).
find_next_remote_port() {
  local _end=$(($1 + 200))
  [ "$_end" -le 65535 ] || _end=65535
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
    "$REMOTE_LISTENING_PORTS" 2>/dev/null \
    | awk -v s="$1" -v e="$_end" '{ used[$1] = 1 } END { for (p = s; p <= e; p++) if (!(p in used)) { print p; exit 0 } exit 1 }'
}

# Point the box alias at port $1 with this laptop's login user, keeping the identity it already
# resolves to, in one round trip. With --if-user-differs it prints UNCHANGED=1 and changes nothing
# when the alias already logs in as LAPTOP_USER.
set_box_alias() {  # port [--if-user-differs]
  local _only=0
  [ "${2:-}" = --if-user-differs ] && _only=1
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    [ -x \"\$rh/scripts/setup-tunnel.sh\" ] || { printf 'ERROR=missing setup-tunnel.sh\n'; exit 2; }
    cfg=\$(ssh $(box_ssh_f_arg) -G $(sq "$BOX_ALIAS") 2>/dev/null || true)
    user=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"user\"{print \$2; exit}')
    [ $_only = 0 ] || [ \"\$user\" != $(sq "$LAPTOP_USER") ] || { printf 'UNCHANGED=1\n'; exit 0; }
    identity=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"identityfile\"{print \$2; exit}')
    case \"\$identity\" in \"~/\"*) identity=\"\$HOME/\${identity#~/}\";; esac
    set --
    [ ! -f \"\$identity\" ] || set -- --identity \"\$identity\"
    \"\$rh/scripts/setup-tunnel.sh\"$(box_setup_config_arg) --alias $(sq "$BOX_ALIAS") --port $(sq "$1") --user $(sq "$LAPTOP_USER") \"\$@\"
  " 2>&1
}

update_box_alias_port() {
  local out
  out=$(set_box_alias "$1") || {
    err "Could not update remote alias '$BOX_ALIAS' to port $1."
    printf '%s\n' "$out" >&2
    return 1
  }
  ok "box alias: updated '$BOX_ALIAS' to remote port $1 (login user $LAPTOP_USER)"
}

# Force the box alias's login user to THIS laptop's `id -un` (see LAPTOP_USER note above), overriding
# any box-side guess. No-op when already correct. Non-fatal: the tunnel_alias_up/switch fallback still
# guards a stale mismatch, so we never abort here.
ensure_box_alias_user() {
  local out
  if out=$(set_box_alias "$PORT" --if-user-differs); then
    [ "$(printf '%s\n' "$out" | kv_value UNCHANGED)" = 1 ] \
      || ok "box alias: login user set to '$LAPTOP_USER' (this laptop account)"
  else
    warn "could not set box alias '$BOX_ALIAS' login user to '$LAPTOP_USER'"
    printf '%s\n' "$out" >&2
  fi
  return 0
}

switch_tunnel_port() {
  local old_port="$PORT" new_port
  new_port=$(find_next_remote_port "$((PORT + 1))") || {
    err "Remote port $PORT is occupied, and no free port was found in the next 200 ports."
    say "    Close the stale/conflicting SSH session, or rerun remote-harness and choose a known free port."
    return 1
  }
  warn "Remote port $old_port is already listening, but '$BOX_ALIAS' does not reach this laptop."
  say "    Switching this setup to remote port ${_B}$new_port${_0} and continuing."
  update_box_alias_port "$new_port" || return 1
  PORT="$new_port"
  write_target_forward "$PORT" || return 1
  chmod 600 "$CFG" 2>/dev/null || true
}

# Make the box log into this laptop as US (id -un), regardless of the box-side guess, BEFORE the
# tunnel check — otherwise a wrong User would make tunnel_alias_up fail and trigger a needless
# port switch.
ensure_box_alias_user

while :; do
  if tunnel_alias_up "$PORT"; then
    ok "Reusing existing reverse tunnel — $BOX_ALIAS already reaches this laptop on remote port $PORT"
    say "    This script did not create that tunnel, so it will leave the tunnel itself running on exit."
    break
  fi
  if remote_port_listening "$PORT"; then
    switch_tunnel_port || exit 1
    continue
  fi

  say "  Opening connection as '${_B}$TARGET${_0}' (carries RemoteForward $PORT)..."
  # Bypass the shell wrapper so $! owns the actual SSH process rather than a function subshell.
  command ssh -F "$LOCAL_SSH_CONFIG" -N "$TARGET" >/dev/null 2>&1 &
  TUNNEL_PID=$!
  TUNNEL_START=$(proc_start "$TUNNEL_PID")
  write_local_resource_record

  # Poll until the remote port is listening (up to 20s)
  READY=0
  for _ in $(seq 1 10); do
    sleep 2
    if remote_port_listening "$PORT"; then READY=1; break; fi
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
  done
  if [ "$READY" = 1 ]; then
    ok "Tunnel active — remote port $PORT is live"
    break
  elif ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    # The backgrounded `ssh -N` already exited. With ExitOnForwardFailure=yes that means the
    # RemoteForward couldn't bind (port collision on the box) or auth/connect failed. Don't mount over
    # a dead tunnel and surface a misleading "Mount failed" — report the real cause and bail (the EXIT
    # trap runs cleanup; nothing is mounted yet).
    TUNNEL_PID=""
    if remote_port_listening "$PORT"; then
      switch_tunnel_port || exit 1
      continue
    fi
    err "Tunnel failed: the SSH connection carrying RemoteForward $PORT exited before the port came up."
    say "    Likely an ssh auth/connect failure. Confirm you can ${_B}ssh $TARGET${_0} non-interactively."
    exit 1
  else
    warn "Could not confirm port $PORT on remote (tunnel still up — may still be starting)."
    say "    Proceeding — if the mount fails, reconnect and re-run."
    break
  fi
done

# Creator records remain available to later launchers when another lease still uses the tunnel.
write_local_resource_record

# ===========================================================================
# Phase 3: Pick a project directory ON THIS LAPTOP
# ===========================================================================
step_begin -s "$(tr2 "Selecting the local project directory" "选择本机项目目录")"

pick_dir() {
  local result="" def="$PWD"
  printf '  Project dir [%s]: ' "$def" >/dev/tty
  # Read the path from the controlling terminal. Two deliberate choices:
  #  - NO `-i` prefill: a prefilled editable default makes a PASTED absolute path APPEND to it
  #    (e.g. /Users/me + /srv/app → /Users/me/srv/app). The default is shown in the prompt above and
  #    an empty reply falls back to it, so prefilling buys nothing and breaks pasting.
  #  - NO `2>/dev/null` on the readline read: `read -e` echoes typed characters on STDERR, so
  #    redirecting stderr to /dev/null makes your input INVISIBLE as you type.
  # (Plain `read -e`, no `-i`, works the same on bash 3.2 and 4+, so no version branch is needed.)
  if [ -r /dev/tty ]; then
    IFS= read -r -e result </dev/tty || IFS= read -r result </dev/tty
  else
    IFS= read -r result
  fi
  [ -z "$result" ] && result="$def"
  result="${result/#\~/$HOME}"
  printf '%s' "$result"
}

choose_project_dir() {
  local candidate="${1:-}" from_arg="${2:-0}" newdir=""
  [ -n "$candidate" ] || candidate="$(pick_dir)"
  while :; do
    candidate="${candidate/#\~/$HOME}"
    candidate="${candidate%/}"
    if [ -d "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    if [ "$from_arg" = 1 ]; then
      warn "Project dir from skill is not a directory: $candidate" >&2
      from_arg=0
    else
      warn "Project dir is not a directory: $candidate" >&2
    fi
    if [ ! -e "$candidate" ]; then
      if ask "  Create it?"; then
        if mkdir -p "$candidate" 2>/dev/null && [ -d "$candidate" ]; then
          ok "Created $candidate" >&2
          printf '%s' "$candidate"
          return 0
        fi
        warn "Could not create $candidate" >&2
      fi
    else
      warn "Path exists but is not a directory." >&2
    fi
    if [ "$ASSUME_YES" = 1 ] || [ ! -e /dev/tty ]; then
      err "No valid project directory selected."
      exit 1
    fi
    printf '  Enter a laptop project dir (blank to abort): ' >/dev/tty
    newdir=""
    IFS= read -r newdir </dev/tty || true
    [ -n "$newdir" ] || { err "Aborted."; exit 1; }
    candidate="$newdir"
  done
}

# Use the agent-confirmed dir if it passed one (--project-dir); otherwise prompt interactively.
if [ -n "$PROJ_DIR_ARG" ]; then
  if ! PROJ_DIR="$(choose_project_dir "$PROJ_DIR_ARG" 1)"; then exit 1; fi
  ok "Project dir (from skill): ${_B}${PROJ_DIR}${_0}"
else
  if ! PROJ_DIR="$(choose_project_dir "" 0)"; then exit 1; fi
fi
ok "Selected: ${_B}${PROJ_DIR}${_0}"
PROJ_NAME="$(basename "$PROJ_DIR")"
register_gateway_project || { err "could not register the project with the forced gateway"; exit 1; }

# ===========================================================================
# Phase 4: Mount on the remote box
# ===========================================================================
step_begin "$(tr2 "Mounting the project on the remote (sshfs)" "在远端挂载项目（sshfs）")"

# Determine the remote mountpoint:
#  - explicit --remote-mountpoint (e.g. the dir you invoked /remote-harness from) wins;
#  - otherwise default to <remote $RH_HOME>/mounts/<project-name>.
#    The mount call itself resolves that default, so it costs no extra round trip.
REMOTE_MOUNTPOINT="$REMOTE_MP"

# Mount, with interactive retry: a recoverable failure (sshfs missing / target not empty) loops
# back instead of exiting, so the tunnel we just established is NOT thrown away.
while :; do
  [ -z "$REMOTE_MOUNTPOINT" ] || say "  Remote mountpoint: ${_B}${REMOTE_MOUNTPOINT}${_0}"
  MOUNT_OUT=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    mp=$(sq "$REMOTE_MOUNTPOINT")
    [ -n \"\$mp\" ] || mp=\"\$rh/mounts/\"$(sq "$PROJ_NAME")
    mkdir -p \"\$mp\"
    \"\$rh/scripts/mount-project.sh\" \
      --alias $(sq "$BOX_ALIAS") \
      --remote-path $(sq "$PROJ_DIR") \
      --mountpoint \"\$mp\"$(box_check_config_arg) \
      --session-id $(sq "$RULE_SESSION_ID")
  " 2>/dev/null || true)
  STATUS=$(printf '%s\n' "$MOUNT_OUT" | kv_value STATUS)
  _mounted_path=$(printf '%s\n' "$MOUNT_OUT" | kv_value MOUNTPOINT)
  [ -z "$_mounted_path" ] || REMOTE_MOUNTPOINT="$_mounted_path"
  case "$STATUS" in
    mounted|already-mounted)
      _remote_key=$(printf '%s' "$REMOTE_MOUNTPOINT" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
      REMOTE_SESSION_DIR="$(dirname "$(dirname "$BOX_SSH_CONFIG")")/$_remote_key.$RULE_SESSION_ID"
      ok "Mounted ${PROJ_DIR} → remote:${REMOTE_MOUNTPOINT}"
      MOUNTED=1   # arm auto-unmount in cleanup()
      break
      ;;
    need-sshfs)
      INSTALL_CMD=$(printf '%s\n' "$MOUNT_OUT" | kv_value INSTALL_CMD)
      warn "sshfs not installed on the remote box."
      say "  On the remote box, run: ${_B}${INSTALL_CMD:-install sshfs via your package manager}${_0}"
      ask "  Installed sshfs on the box — retry the mount?" && continue
      err "Aborted (sshfs missing)."; exit 1
      ;;
    not-empty)
      warn "Remote mountpoint is not empty: ${REMOTE_MOUNTPOINT}"
      say "  sshfs needs an EMPTY box dir (mounting would hide its existing contents)."
      if [ "$ASSUME_YES" = 1 ] || [ ! -e /dev/tty ]; then
        say "  Re-run with ${_B}--remote-mountpoint <empty-dir>${_0} (or start the agent in a fresh empty dir)."
        exit 1
      fi
      printf '  Enter a different EMPTY box dir (blank to abort): ' >/dev/tty
      newmp=""; IFS= read -r newmp </dev/tty || true
      [ -z "$newmp" ] && { err "Aborted."; exit 1; }
      REMOTE_MOUNTPOINT="${newmp%/}"
      continue
      ;;
    *)
      ERR=$(printf '%s\n' "$MOUNT_OUT" | kv_value ERROR)
      err "Mount failed (STATUS=${STATUS:-unknown}): ${ERR:-(no error detail)}"
      say "  Check: is the tunnel active? Is '${BOX_ALIAS}' the right alias on the remote?"
      if [ "$LOCAL_SSHD_MODE" = user ]; then
        _usd_reasons=$(user_sshd_log_reasons "$USER_SSHD_LOG" 5)
        [ -z "$_usd_reasons" ] || { say "  user-mode sshd log ($USER_SSHD_LOG):"; printf '%s\n' "$_usd_reasons" | sed 's/^/    /'; }
      else
        say "  $(tr2 "If this machine's sshd ignores ~/.ssh/authorized_keys (e.g. FreeIPA/sssd), rerun with RH_LOCAL_SSHD=user." "如果本机 sshd 不读取 ~/.ssh/authorized_keys（例如 FreeIPA/sssd），请加 RH_LOCAL_SSHD=user 重新运行。")"
      fi
      exit 1
      ;;
  esac
done

if [ "$(printf '%s\n' "$MOUNT_OUT" | kv_value KILL_USER_PROCESSES)" = 1 ]; then
  warn "the remote box has systemd-logind KillUserProcesses=yes: ending an SSH login kills the mount,"
  say  "    the agent, and remote-harness's cleanup watcher. Ask the server admin to set"
  say  "    KillUserProcesses=no (see docs/ssh-sshfs-long-lived-connections.md)."
fi

# AGENTS.md-only project: only matters for Claude Code (reads CLAUDE.md, not AGENTS.md); codex and
# opencode read AGENTS.md natively. remote-harness does not create repo guidance files implicitly.
AGENTS_ONLY=$(printf '%s\n' "$MOUNT_OUT" | kv_value AGENTS_MD_ONLY)
if [ "$AGENTS_ONLY" = 1 ] && [ "$LAUNCH_BASE" = claude ]; then
  say ""
  warn "this project has AGENTS.md but no CLAUDE.md; Claude Code may not read that guidance."
fi

# ===========================================================================
# Phase 5: Launch the agent on the remote
# ===========================================================================
# Local resume marker (the epoch of the drop) for this remote, remote mountpoint and agent. ssh exits
# 255 when the interactive connection drops; the next launch then offers to continue even if the
# remote left no marker.
LOCAL_RESUME_MARKER="$HOME/.remote-harness/.sessions/.resume/$(printf '%s\n%s\n%s' "$TARGET" \
  "$REMOTE_MOUNTPOINT" "$LAUNCH_BASE" | cksum | awk '{print $1}')"

# Inject the run-on-laptop rule SCOPED TO THIS SESSION: inject-rule builds box-side, per-session
# artifacts (nothing global, nothing in the mounted repo, so other projects on this box are
# unaffected) and prints how to launch so ONLY this agent reads it — a session flag for claude, or
# an env/config prefix (Codex developer_instructions / OPENCODE_CONFIG) for codex/opencode. For opencode, YOLO's
# permission=allow is folded into that per-session config too.
# The box-side session dir is keyed by mountpoint AND this launch's RULE_SESSION_ID, so a
# relaunch or a dead session's cleanup for the same project cannot delete a live session's runner.
step_begin "$(tr2 "Installing session routing (hooks, runner, git/rg shims)" "注入会话路由（hook、runner、git/rg 垫片）")"
# Discover Python/git/rg/Codex in the same login+interactive environment as the final agent launch.
# A plain SSH command often has only /usr/bin in PATH, hiding ~/.local/bin/codex and its bundled rg.
# RH_LANG travels with it so a Chinese session's rule asks the agent to reply in Chinese.
inject_remote_cmd="RH_LANG=$(is_zh && echo zh || echo en) \"\${RH_HOME:-\$HOME/.remote-harness}/scripts/inject-rule.sh\" on $(sq "$LAUNCH_BASE") $(sq "$PROJ_DIR") $(sq "$BOX_ALIAS") $(sq "$REMOTE_MOUNTPOINT") $(sq "$APPROVAL") $(sq "$BOX_SSH_CONFIG") $(sq "$RULE_SESSION_ID")"
# Without a terminal, a startup file that waits for input or execs another program (tmux, a nested
# shell) would hang here forever, so bound the whole step on the box and keep its stderr.
inject_shell="\"\${SHELL:-/bin/bash}\" -lic $(sq "$inject_remote_cmd")"
inject_err="$LOCAL_SESSION_DIR/inject.err"
rh_rc=0
rh_out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
     "if command -v timeout >/dev/null 2>&1; then exec timeout -k 5 120 $inject_shell; else exec $inject_shell; fi" \
     2>"$inject_err") || rh_rc=$?
rh_status=$(printf '%s\n' "$rh_out" | kv_value RH_STATUS)
[ "$rh_rc" = 0 ] || rh_status=ERROR
if [ "$rh_status" = INJECTED ]; then
  RULE_INJECTED=1
  rh_env=$(printf '%s\n' "$rh_out" | kv_value RH_LAUNCH_ENV)
  rh_flags=$(printf '%s\n' "$rh_out" | kv_value RH_LAUNCH_FLAGS)
  if [ "$APPROVAL" = auto ]; then
    if [ "$(printf '%s\n' "$rh_out" | kv_value RH_APPROVAL)" = auto ]; then
      ok "$(tr2 "Approvals: ${LAUNCH_BASE} automatic review (auto mode)" "审批模式：${LAUNCH_BASE} 自动审核（auto 模式）")"
    else
      warn "$(tr2 "This remote ${LAUNCH_BASE} has no auto approval mode; it will ask for approvals as usual." \
                  "远端 ${LAUNCH_BASE} 不支持 auto 审批模式，将照常逐项请求审批。")"
    fi
  fi
  rh_ready=$(printf '%s\n' "$rh_out" | kv_value RH_READY_FILE)
  # The session launcher records the agent pid for the box-side watcher that cleans up after a
  # dropped connection; it wraps only this final launch, never the opencode readiness probe below.
  rh_prefix=$(printf '%s\n' "$rh_out" | kv_value RH_LAUNCH_PREFIX)
  REMOTE_SESSION_DIR=$(printf '%s\n' "$rh_out" | kv_value RH_SESSION_DIR)
  if [ -z "$REMOTE_SESSION_DIR" ]; then
    # Compatibility with older injectors: the directory still has the same mount/session key.
    _remote_key=$(printf '%s' "$REMOTE_MOUNTPOINT" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
    REMOTE_SESSION_DIR="$(dirname "$(dirname "$BOX_SSH_CONFIG")")/$_remote_key.$RULE_SESSION_ID"
  fi
  # Continue the agent's last conversation in this mount when the remote watcher ended it after a lost
  # connection (asked once, default yes). RH_RESUME=1 always continues, RH_RESUME=0 never does.
  rh_resume=$(printf '%s\n' "$rh_out" | kv_value RH_RESUME_AVAILABLE)
  rh_resume_args=$(printf '%s\n' "$rh_out" | kv_value RH_RESUME_ARGS)
  # The remote watcher cannot record a disconnect that the agent outran by exiting on SIGHUP; the
  # local marker from an interactive ssh that lost its connection covers that case.
  if [ -f "$LOCAL_RESUME_MARKER" ]; then
    _local_resume_at=$(cat "$LOCAL_RESUME_MARKER" 2>/dev/null)
    rm -f "$LOCAL_RESUME_MARKER"
    case "$_local_resume_at" in ''|*[!0-9]*) ;; *)
      [ -n "$rh_resume" ] || [ $(( $(date +%s) - _local_resume_at )) -gt 604800 ] \
        || rh_resume="disconnected,$_local_resume_at" ;;
    esac
  fi
  RESUME=0
  case "${RH_RESUME:-}" in
    1|yes) RESUME=1;;
    0|no) ;;
    *)
      if [ -n "$rh_resume" ]; then
        _resume_at=${rh_resume#*,}
        case "$_resume_at" in ''|*[!0-9]*) _resume_ago="?";; *) _resume_ago=$(( ($(date +%s) - _resume_at) / 60 ));; esac
        warn "$(tr2 "The last ${LAUNCH_BASE} session of this project ended on a lost connection (${_resume_ago} min ago)." \
                    "该项目上一次的 ${LAUNCH_BASE} 会话因断线结束（${_resume_ago} 分钟前）。")"
        ask "$(tr2 "Continue that conversation?" "继续该会话？")" y && RESUME=1
      fi
      ;;
  esac
  if [ "$RESUME" = 1 ] && [ -n "$rh_resume_args" ]; then
    EFF_LAUNCH="$LAUNCH_BASE $rh_resume_args${EFF_LAUNCH#"$LAUNCH_BASE"}"
    ok "$(tr2 "Continuing the last ${LAUNCH_BASE} conversation in this project" "将继续该项目上一次的 ${LAUNCH_BASE} 会话")"
  fi
  EFF_LAUNCH="${rh_env:+$rh_env }${rh_prefix:+$rh_prefix }${EFF_LAUNCH}${rh_flags:+ $rh_flags}"
  ok "Injected session-scoped run-on-laptop rule for ${LAUNCH_BASE} (removed on exit)"
else
  err "could not install strict run-on-laptop routing (${rh_status:-no status}); refusing to launch the agent"
  if [ "$rh_rc" = 124 ] || [ "$rh_rc" = 137 ]; then
    say "  The remote login shell did not finish within 120s; check its startup files (~/.bashrc,"
    say "  ~/.zshrc, ~/.profile) for prompts or commands that wait or exec another program."
  fi
  # Interactive shells without a terminal always print job-control notices; show only the rest.
  inject_tail=$(grep -v -e 'cannot set terminal process group' -e 'no job control in this shell' \
    "$inject_err" 2>/dev/null | tail -n 8)
  if [ -n "$inject_tail" ]; then
    say "  Remote output (last lines):"
    printf '%s\n' "$inject_tail" | sed 's/^/    /'
  fi
  exit 1
fi

if [ "$LAUNCH_BASE" = opencode ]; then
  case "$rh_ready" in
    /*) ;;
    *) err "opencode routing plugin did not provide a readiness marker; refusing to launch"; exit 1;;
  esac
  case "$rh_ready" in *'
'*) err "opencode routing plugin returned an invalid readiness marker; refusing to launch"; exit 1;; esac
  if ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" "
    ready=$(sq "$rh_ready")
    mount_root=$(sq "$REMOTE_MOUNTPOINT")
    rm -f \"\$ready\" 2>/dev/null || true
    cd \"\$mount_root\" || exit 1
    (${rh_env:+$rh_env }opencode debug config </dev/null >/dev/null 2>&1) &
    pid=\$!
    i=0
    while [ \"\$i\" -lt 60 ]; do
      if [ -s \"\$ready\" ]; then
        kill \"\$pid\" 2>/dev/null || true
        wait \"\$pid\" 2>/dev/null || true
        exit 0
      fi
      kill -0 \"\$pid\" 2>/dev/null || break
      sleep 1
      i=\$((i + 1))
    done
    kill \"\$pid\" 2>/dev/null || true
    wait \"\$pid\" 2>/dev/null || true
    exit 1
  "; then
    ok "opencode routing plugin loaded"
  else
    err "opencode routing plugin failed to load; refusing to launch the agent"
    exit 1
  fi
fi

step_begin "$(tr2 "Launching ${LAUNCH} on the remote" "在远端启动 ${LAUNCH}")"
step_end ok "${REMOTE_MOUNTPOINT}"
say "  $(tr2 "Your terminal becomes the remote ${LAUNCH} session. Exit ${LAUNCH} to return here." "终端将切换为远端 ${LAUNCH} 会话；退出 ${LAUNCH} 即返回这里。")"
sep

# Use a LOGIN+INTERACTIVE shell so the remote PATH (e.g. ~/.local/bin from ~/.profile / ~/.zshrc)
# is sourced — `ssh host cmd` alone runs a non-login non-interactive shell and won't find claude.
# ClearAllForwardings=yes: don't re-request the RemoteForward (Phase 2's tunnel already holds it).
# The simple bootstrap path runs this script from a pipe (`ssh cat ... | bash -s`), so stdin is not
# a terminal even though the user has a controlling tty. Attach the final interactive ssh to
# /dev/tty explicitly; otherwise OpenSSH refuses to allocate a pty and TUI agents fail immediately.
# Shown by the remote side before the agent takes over the terminal (this script can no longer print
# once ssh -tt owns it). The prewarm reads, in parallel, the metadata an agent probes one by one at
# startup (.git HEAD/config/refs, the tracked upstream ref, .mcp.json, CLAUDE.md, .claude settings,
# ...), including files that do not exist, so the SSHFS lookup cache already holds those answers when
# the agent starts. In the background it also runs a no-op routed command, which opens the session's
# multiplexing master to the project host (one SSH handshake, ~5s on a slow link) before the agent's
# first routed git/rg/Bash call needs it. POSIX sh; every step is best effort.
remote_launch_prelude() {
  local _conn _warming _warm _start
  _conn=$(tr2 "Remote session connected" "远端会话已连接")
  _warming=$(tr2 "Prewarming project metadata (.git, settings files)" "正在预热项目元数据（.git、设置文件）")
  _warm=$(tr2 "Prewarmed project metadata (.git, settings files)" "预热项目元数据（.git、设置文件）")
  _start=$(tr2 "Starting ${LAUNCH_BASE} (a folder used for the first time asks whether you trust it)..." \
               "启动 ${LAUNCH_BASE}（第一次进入的目录会先询问是否信任）…")
  cat <<EOF
printf '  \342\234\223 %s\n' $(sq "$_conn")
rh_t0=\$(date +%s)
rh_spin() {
  set -- ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
  while :; do for rh_c in "\$@"; do
    printf "\\r\\033[K  \$rh_c %s...  %ss" $(sq "$_warming") "\$((\$(date +%s) - rh_t0))"; sleep 0.15
  done; done
}
rh_sp=""
if [ -t 1 ]; then rh_spin & rh_sp=\$!; fi
$( [ -n "$REMOTE_SESSION_DIR" ] && printf '%s
' "[ ! -x $(sq "$REMOTE_SESSION_DIR/bin/rh-run") ] || $(sq "$REMOTE_SESSION_DIR/bin/rh-run") Lg== dHJ1ZQ== >/dev/null 2>&1 </dev/null &" )
rh_warm() {  # parallel reads; waits for exactly these readers, never for the spinner
  rh_pids=""
  for rh_f in "\$@"; do cat -- "\$rh_f" >/dev/null 2>&1 & rh_pids="\$rh_pids \$!"; done
  wait \$rh_pids 2>/dev/null
}
ls -A .git/refs/heads .git/refs/remotes .git/refs/remotes/* .claude >/dev/null 2>&1 &
rh_warm .git/HEAD .git/config .git/packed-refs .git/commondir .git/info/exclude .mcp.json CLAUDE.md CLAUDE.local.md AGENTS.md .gitignore .claude/settings.json .claude/settings.local.json
rh_b=\$(sed -n 's#^ref: refs/heads/##p' .git/HEAD 2>/dev/null)
rh_up=\$(awk -v b="\$rh_b" '/^\[/ { s = (\$0 == "[branch \"" b "\"]") } s && \$1 == "remote" { r = \$3 } s && \$1 == "merge" { m = \$3; sub("^refs/heads/", "", m) } END { if (r != "" && m != "") print r "/" m }' .git/config 2>/dev/null)
rh_warm ".git/refs/heads/\$rh_b" ".git/refs/remotes/origin/\$rh_b" ".git/refs/remotes/\$rh_up" .git/refs/remotes/origin/HEAD
if [ -n "\$rh_sp" ]; then kill -9 "\$rh_sp" 2>/dev/null; wait "\$rh_sp" 2>/dev/null; printf '\r\033[K'; fi
printf '  \342\234\223 %s  %ss\n' $(sq "$_warm") "\$((\$(date +%s) - rh_t0))"
printf '  \342\213\257 %s\n' $(sq "$_start")
EOF
}
launch_remote_agent() {
  local _remote_cmd _rc
  _remote_cmd="cd $(sq "$REMOTE_MOUNTPOINT") || exit 1
$(remote_launch_prelude)
exec \"\${SHELL:-/bin/bash}\" -lic $(sq "$EFF_LAUNCH")"
  # Also hand the local terminal size to the remote pty, so the agent never starts on a 0x0 terminal.
  local _size _rows _cols
  _size=$(stty size 2>/dev/null </dev/tty) || _size=""
  _rows=${_size% *} _cols=${_size#* }
  case "$_rows$_cols" in ''|*[!0-9]*) ;; *)
    [ "$_rows" -gt 0 ] && [ "$_cols" -gt 0 ] && _remote_cmd="stty rows $_rows cols $_cols 2>/dev/null; $_remote_cmd" ;;
  esac
  say "  ${_C}⋯${_0} $(tr2 "Connecting the remote session..." "正在连接远端会话…")"
  if { exec 3</dev/tty; } 2>/dev/null; then
    ssh -tt -o ClearAllForwardings=yes "$TARGET" "$_remote_cmd" <&3
    _rc=$?
    exec 3<&-
    return "$_rc"
  fi
  warn "no controlling tty found; remote ${LAUNCH} TUI may not start"
  ssh -tt -o ClearAllForwardings=yes "$TARGET" "$_remote_cmd"
}
launch_remote_agent
CLAUDE_EXIT=$?
if [ "$CLAUDE_EXIT" = 255 ]; then
  mkdir -p "${LOCAL_RESUME_MARKER%/*}" 2>/dev/null && date +%s > "$LOCAL_RESUME_MARKER" 2>/dev/null || true
fi

# ===========================================================================
# Post-session cleanup offer
# ===========================================================================
sep
if [ "$CLAUDE_EXIT" = 0 ]; then
  ok "${LAUNCH} session ended."
elif [ "$CLAUDE_EXIT" = 255 ]; then
  warn "$(tr2 "Lost the connection to the remote ${LAUNCH} session; the next launch of this project offers to continue it." \
              "与远端 ${LAUNCH} 会话的连接已断开；下次启动该项目时会询问是否继续该会话。")"
else
  warn "${LAUNCH} session ended (exit code $CLAUDE_EXIT)."
fi
# cleanup() (armed via trap) auto-unmounts and drops the tunnel as this script exits.
printf "\n${_B}Done.${_0}\n"
