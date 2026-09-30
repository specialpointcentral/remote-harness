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
#   --yolo                bypass approvals on the launched agent — claude/codex get their
#                         bypass flag; opencode gets a temporary permission=allow config (restored)
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
YOLO=0; EFF_LAUNCH=""; LAUNCH_BASE="claude"
while [ $# -gt 0 ]; do
  case "$1" in
    --host)          need_arg "$1" "${2-}"; HOST="$2";           shift 2;;
    --port)          need_arg "$1" "${2-}"; PORT="$2";           shift 2;;
    --pubkey)        need_arg "$1" "${2-}"; PUBKEY="$2";         shift 2;;
    --via)           need_arg "$1" "${2-}"; VIA="$2";            shift 2;;
    --launch)        need_arg "$1" "${2-}"; LAUNCH="$2";         shift 2;;   # CLI to start on the remote (claude/codex/opencode)
    --yolo)          YOLO=1;              shift;;     # bypass approvals on the launched agent
    --box-alias)     need_arg "$1" "${2-}"; BOX_ALIAS="$2";      shift 2;;
    --box-ssh-config) need_arg "$1" "${2-}"; BOX_SSH_CONFIG="$2"; shift 2;;
    --box-user)      need_arg "$1" "${2-}"; BOX_USER="$2";       shift 2;;
    --remote-mountpoint) need_arg "$1" "${2-}"; REMOTE_MP="$2";  shift 2;;   # exact box dir to mount at (e.g. your invoking cwd)
    --project-dir)   need_arg "$1" "${2-}"; PROJ_DIR_ARG="$2";   shift 2;;   # laptop project dir (skip the interactive prompt)
    --setup-only)    SETUP_ONLY=1;        shift;;
    --yes|-y)        ASSUME_YES=1;        shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$PORT" ] || { printf 'need --port\n' >&2; exit 2; }
printf '%s' "$PORT" | grep -qE '^[0-9]+$' || { printf 'port must be numeric: %s\n' "$PORT" >&2; exit 2; }
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { printf 'port out of range: %s\n' "$PORT" >&2; exit 2; }

# ---- shared helpers (colors, say/ok/warn/err/hdr/ask, sq, OS vars, parse_via, ssh-config) -------
# laptop-setup.sh is fetched to the laptop and run STANDALONE (the laptop usually has no install),
# so the skill's one-command fetches _common.sh next to this file and we source it by path.
RH_COMMON="${RH_COMMON:-$(dirname "$0")/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else printf 'error: missing _common.sh next to %s — re-copy the full command\n' "$0" >&2; exit 2; fi

# ---- auto-cleanup on exit/disconnect ---------------------------------------
TUNNEL_PID=""; MOUNTED=0; CLEANED=0; RULE_INJECTED=0
LOCAL_SESSION_DIR=""; LOCAL_SSH_CONFIG=""
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
ssh() {
  if ssh_uses_session_config "$@"; then
    command ssh -F "$LOCAL_SSH_CONFIG" "$@"
  else
    command ssh "$@"
  fi
}
# Path to the per-(box,port) pid file recording WHO owns the reverse tunnel (the live `ssh -N` pid),
# so the LAST session out can drop it even if it didn't create it — same-user multi-project, where a
# second session reuses the tunnel. Keyed by TARGET+PORT (evaluated at call time, after they're set).
tunnel_state_path() {
  printf '%s/.remote-harness/.tunnel-%s.pid' "$HOME" \
    "$(printf '%s-%s' "${TARGET:-}" "${PORT:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
}
# True if the box STILL has another sshfs mount riding this reverse tunnel (a different session's
# '<BOX_ALIAS>:…' mount remains after we've unmounted ours). Best-effort: false on error, and on a
# macOS/FUSE-T box (its mount source isn't '<alias>:path', so it can't be detected — the tunnel is
# then dropped as before).
tunnel_still_needed() {
  [ -n "${BOX_ALIAS:-}" ] && [ -n "${TARGET:-}" ] || return 1
  _cnt="$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
    "mount 2>/dev/null | grep -F -- $(sq "$BOX_ALIAS:") 2>/dev/null | grep -c -i fuse" 2>/dev/null)"
  case "${_cnt:-0}" in *[!0-9]*) _cnt=0;; esac
  [ "${_cnt:-0}" -gt 0 ]
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
  GATEWAY_DIR="$HOME/.remote-harness/bin"
  GATEWAY_PATH="$GATEWAY_DIR/project-host-gateway.sh"
  GATEWAY_SESSION_DIR="$HOME/.remote-harness/.sessions/gateways/$AUTHKEY_TAG"
  mkdir -p "$GATEWAY_DIR" "$GATEWAY_SESSION_DIR" 2>/dev/null || return 1
  chmod 700 "$GATEWAY_DIR" "$GATEWAY_SESSION_DIR" 2>/dev/null || true
  cp "$_ipg_scripts/project-host-gateway.sh" "$GATEWAY_PATH" || return 1
  cp "$_ipg_scripts/run-on-project-host.sh" "$GATEWAY_DIR/run-on-project-host.sh" || return 1
  chmod 700 "$GATEWAY_PATH" "$GATEWAY_DIR/run-on-project-host.sh" 2>/dev/null || return 1
}

register_gateway_project() {
  [ -n "$GATEWAY_SESSION_DIR" ] || return 1
  printf '%s' "$PROJ_DIR" | base64 | tr -d '\n' > "$GATEWAY_SESSION_DIR/project-root.b64" \
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
    warn "No remote-harness public key was provided; the box must already be authorized to SSH back to this laptop."
    return 0
  fi
  parse_pubkey_for_authorized_keys || return 1
  _ak_file="$HOME/.ssh/authorized_keys"

  authkey_lock || { warn "could not lock authorized_keys; not modifying SSH authorization"; return 1; }
  if authorized_key_match user "$_ak_file"; then
    authkey_unlock
    warn "authorized_keys contains the session key without the forced gateway; refusing unsafe reuse"
    return 1
  fi

  install_project_host_gateway || { authkey_unlock; return 1; }

  mkdir -p "$AUTHKEY_REF_DIR" 2>/dev/null || { authkey_unlock; return 1; }
  printf 'pid=%s\nstarted=%s\n' "$$" "$(date 2>/dev/null || true)" > "$AUTHKEY_TOKEN" 2>/dev/null || {
    authkey_unlock
    return 1
  }
  AUTHKEY_MANAGED=1

  if authorized_key_match managed "$_ak_file"; then
    ok "authorized_keys: reusing existing remote-harness temporary authorization"
    authkey_unlock
    return 0
  fi

  if append_managed_authorized_key "$_ak_file"; then
    ok "authorized_keys: temporarily authorized the forced project-host gateway"
    authkey_unlock
    return 0
  fi

  rm -f "$AUTHKEY_TOKEN" 2>/dev/null || true
  AUTHKEY_TOKEN=""
  AUTHKEY_MANAGED=0
  authkey_unlock
  warn "could not update ~/.ssh/authorized_keys"
  return 1
}

cleanup_reverse_authorized_key() {
  [ -n "${AUTHKEY_TOKEN:-}" ] || return 0
  authkey_lock || { warn "could not lock authorized_keys for cleanup; temporary authorization may remain"; return 0; }
  rm -f "$AUTHKEY_TOKEN" 2>/dev/null || true
  if [ -d "$AUTHKEY_REF_DIR" ] && find "$AUTHKEY_REF_DIR" -type f -print -quit 2>/dev/null | grep -q .; then
    authkey_unlock
    return 0
  fi
  rmdir "$AUTHKEY_REF_DIR" 2>/dev/null || true
  if [ "$AUTHKEY_MANAGED" = 1 ] && [ -f "$HOME/.ssh/authorized_keys" ]; then
    if write_authorized_keys_without_managed_block "$HOME/.ssh/authorized_keys"; then
      ok "authorized_keys: temporary remote-harness authorization removed"
    else
      warn "could not remove temporary remote-harness authorized_keys block"
    fi
  fi
  [ -z "$GATEWAY_SESSION_DIR" ] || rm -rf "$GATEWAY_SESSION_DIR" 2>/dev/null || true
  authkey_unlock
}

cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  if [ "$MOUNTED" = 1 ]; then
    printf '\n'
    say "  Connection closed — auto-unmounting ${REMOTE_MOUNTPOINT:-} on the remote box..."
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" "
      rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
      \"\$rh/scripts/mount-project.sh\" --alias $(sq "${BOX_ALIAS:-}") --unmount --mountpoint $(sq "${REMOTE_MOUNTPOINT:-}")
      mp=$(sq "${REMOTE_MOUNTPOINT:-}")
      case \"\$mp\" in \"\$rh/mounts/\"*) rmdir \"\$mp\" 2>/dev/null || true;; esac
    " >/dev/null 2>&1 && ok "Unmounted" || warn "auto-unmount failed — mount may be stale on the box (next run re-validates it)"
  fi
  if [ "${RULE_INJECTED:-0}" = 1 ]; then
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" \
      "\"\${RH_HOME:-\$HOME/.remote-harness}/scripts/inject-rule.sh\" off $(sq "${LAUNCH_BASE:-claude}") $(sq "${REMOTE_MOUNTPOINT:-}")" >/dev/null 2>&1 \
      && ok "session-scoped rule removed" || true
  fi
  if [ -n "${BOX_SSH_CONFIG:-}" ] && [ -n "${TARGET:-}" ]; then
    ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "${TARGET:-}" "
      cfg=$(sq "$BOX_SSH_CONFIG")
      case \"\$cfg\" in
        */.remote-harness/.sessions/*/ssh_config)
          dir=\$(dirname \"\$cfg\")
          rm -f \"\$cfg\" \"\$dir/id_ed25519\" \"\$dir/id_ed25519.pub\" 2>/dev/null || true
          rm -rf \"\$dir/runtime\" 2>/dev/null || true
          rmdir \"\$dir\" 2>/dev/null || true
          ;;
      esac
    " >/dev/null 2>&1 && ok "box temp ssh config removed" || true
  fi
  # Drop the reverse tunnel ONLY when no other session still rides it. Whoever exits LAST tears it
  # down — via the creator's pid file (the live `ssh -N` pid persists as an orphan after an early
  # creator exit, so killing that pid still closes the tunnel) — so an early exit by the creator no
  # longer strands another project's mount. Runs for reusers too (their own TUNNEL_PID is empty).
  if [ "$MOUNTED" = 1 ] || [ -n "$TUNNEL_PID" ]; then
    if tunnel_still_needed; then
      warn "another session's mount still uses this reverse tunnel — leaving it up"
    else
      _sp="$(tunnel_state_path)"; _pid="${TUNNEL_PID:-}"
      [ -z "$_pid" ] && [ -f "$_sp" ] && _pid="$(cat "$_sp" 2>/dev/null)"
      [ -n "$_pid" ] && kill "$_pid" 2>/dev/null || true
      rm -f "$_sp" 2>/dev/null || true
    fi
  fi
  cleanup_reverse_authorized_key
  if [ -n "${LOCAL_SESSION_DIR:-}" ]; then
    rm -rf "$LOCAL_SESSION_DIR" 2>/dev/null || true
    ok "local temp ssh config removed"
  fi
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
if [ "$YOLO" = 1 ]; then
  case "$LAUNCH_BASE" in
    claude)   EFF_LAUNCH="$LAUNCH --dangerously-skip-permissions";              warn "YOLO: claude --dangerously-skip-permissions";;
    codex)    EFF_LAUNCH="$LAUNCH --dangerously-bypass-approvals-and-sandbox";  warn "YOLO: codex --dangerously-bypass-approvals-and-sandbox";;
    opencode) warn "YOLO: opencode permission=allow (set in this session's config only — nothing global)";;
    *)        warn "YOLO requested but unknown agent '$LAUNCH' — launching without bypass";;
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

# -- SSH authentication boundary -------------------------------------------
if [ -n "$PUBKEY" ]; then
  ok "box key visible: $(printf '%s' "$PUBKEY" | awk '{print $1, substr($2,1,14)"...", $3}')"
fi
say  "  Reverse auth: remote-harness may add a tagged temporary entry to ~/.ssh/authorized_keys."
say  "  A matching unrestricted key is rejected; only the managed forced-gateway entry is reusable."

# -- ensure SSH server running --
ssh_listening() { (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null && { exec 3>&-; return 0; }; return 1; }
if ssh_listening; then
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
LOCAL_SSH_CONFIG="$LOCAL_SESSION_DIR/ssh_config"
CFG="$LOCAL_SSH_CONFIG"; touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
write_session_ssh_defaults "$LOCAL_SESSION_DIR" \
  || { err "could not create session SSH runtime directory"; exit 1; }
write_target_forward() {
  local _port="$1" _rf_line
  _rf_line="    RemoteForward $_port 127.0.0.1:22"
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
write_target_forward "$PORT" || exit 2
say "    Session ssh alias: ${_B}ssh $TARGET${_0}"
chmod 600 "$CFG" 2>/dev/null || true

# -- default box-alias --
if [ -z "$BOX_ALIAS" ]; then
  LUSER=$(id -un 2>/dev/null || echo user)
  BOX_ALIAS="${LUSER}-mac"
fi

# == Phase 1 done ==
sep
if [ "$SETUP_ONLY" = 1 ]; then
  ok "Phase 1 done (--setup-only)."
  say "  Session config: ${_B}$LOCAL_SSH_CONFIG${_0}"
  say "  Reconnect: ${_B}ssh -F $(sq "$LOCAL_SSH_CONFIG") -O exit $TARGET 2>/dev/null; ssh -F $(sq "$LOCAL_SSH_CONFIG") $TARGET${_0}"
  exit 0
fi
[ -n "$BOX_SSH_CONFIG" ] || {
  err "need --box-ssh-config for a full reverse session; run through simple-laptop-setup.sh"
  exit 2
}
trap cleanup EXIT INT TERM HUP   # auto-cleanup for authorization, mount, rule, config, tunnel
prepare_reverse_authorized_key || exit 1

# ===========================================================================
# Phase 2: Reconnect — establish the reverse tunnel automatically
# ===========================================================================
hdr "Phase 2: establishing tunnel"
# Kill the session-local master connection to the harness target, if any.
ssh -O exit "$TARGET" 2>/dev/null || true

remote_port_listening() {
  local _port="$1"
  # Portable listener check on the box (ss -> netstat -an [GNU/BSD] -> lsof), matching
  # check-tunnel.sh; extracts the port from host:PORT or BSD host.PORT and matches exactly.
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=3 "$TARGET" \
    "{ if command -v ss >/dev/null 2>&1; then ss -tlnH 2>/dev/null | awk '{print \$4}';
       elif command -v netstat >/dev/null 2>&1; then netstat -an 2>/dev/null | awk '/^tcp/ && /LISTEN/{print \$4}';
       elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print \$9}';
       fi; } | sed -E 's/.*[:.]([0-9]+)\$/\1/' | grep -qx $(sq "$_port")" 2>/dev/null
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
    laptop_host=$(printf '%s\n' "$out" | awk -F= '/^LAPTOP_HOSTNAME=/{print $2; exit}')
    laptop_user=$(printf '%s\n' "$out" | awk -F= '/^LAPTOP_USER=/{print $2; exit}')
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

find_next_remote_port() {
  local _start="$1" _port _end
  _port="$_start"
  _end=$((_start + 200))
  [ "$_end" -le 65535 ] || _end=65535
  while [ "$_port" -le "$_end" ]; do
    if ! remote_port_listening "$_port"; then
      printf '%s' "$_port"
      return 0
    fi
    _port=$((_port + 1))
  done
  return 1
}

remote_box_alias_info() {
  ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" "
    cfg=\$(ssh $(box_ssh_f_arg) -G $(sq "$BOX_ALIAS") 2>/dev/null || true)
    user=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"user\"{print \$2; exit}')
    identity=\$(printf '%s\n' \"\$cfg\" | awk 'tolower(\$1)==\"identityfile\"{print \$2; exit}')
    case \"\$identity\" in \"~/\"*) identity=\"\$HOME/\${identity#~/}\";; esac
    [ -f \"\$identity\" ] || identity=\"\"
    printf 'USER=%s\nIDENTITY=%s\n' \"\$user\" \"\$identity\"
  " 2>/dev/null || true
}

update_box_alias_port() {
  local _port="$1" info identity identity_arg="" out
  info=$(remote_box_alias_info)
  identity=$(printf '%s\n' "$info" | awk -F= '/^IDENTITY=/{print $2; exit}')
  [ -n "$identity" ] && identity_arg=" --identity $(sq "$identity")"
  out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    [ -x \"\$rh/scripts/setup-tunnel.sh\" ] || { printf 'ERROR=missing setup-tunnel.sh\n'; exit 2; }
    \"\$rh/scripts/setup-tunnel.sh\"$(box_setup_config_arg) --alias $(sq "$BOX_ALIAS") --port $(sq "$_port") --user $(sq "$LAPTOP_USER")$identity_arg
  " 2>&1) || {
    err "Could not update remote alias '$BOX_ALIAS' to port $_port."
    printf '%s\n' "$out" >&2
    return 1
  }
  ok "box alias: updated '$BOX_ALIAS' to remote port $_port (login user $LAPTOP_USER)"
}

# Force the box alias's login user to THIS laptop's `id -un` (see LAPTOP_USER note above), overriding
# any box-side guess. No-op when already correct. Non-fatal: the tunnel_alias_up/switch fallback still
# guards a stale mismatch, so we never abort here.
ensure_box_alias_user() {
  local info cur identity identity_arg="" out
  info=$(remote_box_alias_info)
  cur=$(printf '%s\n' "$info" | awk -F= '/^USER=/{print $2; exit}')
  [ "$cur" = "$LAPTOP_USER" ] && return 0
  identity=$(printf '%s\n' "$info" | awk -F= '/^IDENTITY=/{print $2; exit}')
  [ -n "$identity" ] && identity_arg=" --identity $(sq "$identity")"
  out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    [ -x \"\$rh/scripts/setup-tunnel.sh\" ] || { printf 'ERROR=missing setup-tunnel.sh\n'; exit 2; }
    \"\$rh/scripts/setup-tunnel.sh\"$(box_setup_config_arg) --alias $(sq "$BOX_ALIAS") --port $(sq "$PORT") --user $(sq "$LAPTOP_USER")$identity_arg
  " 2>&1) \
    && ok "box alias: login user set to '$LAPTOP_USER' (this laptop account)" \
    || { warn "could not set box alias '$BOX_ALIAS' login user to '$LAPTOP_USER'"; printf '%s\n' "$out" >&2; }
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
  ssh -N "$TARGET" >/dev/null 2>&1 &
  TUNNEL_PID=$!

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

# Record who owns the tunnel (the live `ssh -N` pid) so the LAST session out — which may be a
# different, reusing session — can drop it cleanly. Only the creator writes it; reusers (which broke
# out via tunnel_alias_up) have an empty TUNNEL_PID and rely on the creator's file.
if [ -n "$TUNNEL_PID" ]; then
  mkdir -p "$HOME/.remote-harness" 2>/dev/null || true
  printf '%s\n' "$TUNNEL_PID" > "$(tunnel_state_path)" 2>/dev/null || true
fi

# ===========================================================================
# Phase 3: Pick a project directory ON THIS LAPTOP
# ===========================================================================
hdr "Phase 3: select a laptop project directory"

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
hdr "Phase 4: mounting on remote"

# Determine the remote mountpoint:
#  - explicit --remote-mountpoint (e.g. the dir you invoked /remote-harness from) wins;
#  - otherwise default to <remote $RH_HOME>/mounts/<project-name>.
if [ -n "$REMOTE_MP" ]; then
  REMOTE_MOUNTPOINT="$REMOTE_MP"
else
  REMOTE_MOUNTPOINT=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" \
    "rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"; printf '%s/mounts/%s' \"\$rh\" $(sq "$PROJ_NAME")" 2>/dev/null || true)
  [ -z "$REMOTE_MOUNTPOINT" ] && { warn "could not resolve remote RH_HOME; please pass --remote-mountpoint <empty-dir>"; exit 1; }
fi

# Mount, with interactive retry: a recoverable failure (sshfs missing / target not empty) loops
# back instead of exiting, so the tunnel we just established is NOT thrown away.
while :; do
  say "  Remote mountpoint: ${_B}${REMOTE_MOUNTPOINT}${_0}"
  MOUNT_OUT=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "
    mkdir -p $(sq "$REMOTE_MOUNTPOINT")
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    \"\$rh/scripts/mount-project.sh\" \
      --alias $(sq "$BOX_ALIAS") \
      --remote-path $(sq "$PROJ_DIR") \
      --mountpoint $(sq "$REMOTE_MOUNTPOINT")$(box_check_config_arg)
  " 2>/dev/null || true)
  STATUS=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^STATUS=/{print $2; exit}')
  case "$STATUS" in
    mounted|already-mounted)
      ok "Mounted ${PROJ_DIR} → remote:${REMOTE_MOUNTPOINT}"
      MOUNTED=1   # arm auto-unmount in cleanup()
      break
      ;;
    need-sshfs)
      INSTALL_CMD=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^INSTALL_CMD=/{print $2; exit}')
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
      ERR=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^ERROR=/{print $2; exit}')
      err "Mount failed (STATUS=${STATUS:-unknown}): ${ERR:-(no error detail)}"
      say "  Check: is the tunnel active? Is '${BOX_ALIAS}' the right alias on the remote?"
      exit 1
      ;;
  esac
done

# AGENTS.md-only project: only matters for Claude Code (reads CLAUDE.md, not AGENTS.md); codex and
# opencode read AGENTS.md natively. remote-harness does not create repo guidance files implicitly.
AGENTS_ONLY=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^AGENTS_MD_ONLY=/{print $2; exit}')
if [ "$AGENTS_ONLY" = 1 ] && [ "$LAUNCH_BASE" = claude ]; then
  say ""
  warn "this project has AGENTS.md but no CLAUDE.md; Claude Code may not read that guidance."
fi

# ===========================================================================
# Phase 5: Launch Claude Code on the remote
# ===========================================================================
# Inject the run-on-laptop rule SCOPED TO THIS SESSION: inject-rule builds box-side, per-session
# artifacts (nothing global, nothing in the mounted repo, so other projects on this box are
# unaffected) and prints how to launch so ONLY this agent reads it — a session flag for claude, or
# an env/config prefix (Codex developer_instructions / OPENCODE_CONFIG) for codex/opencode. For opencode, YOLO's
# permission=allow is folded into that per-session config too.
rh_out=$(ssh -n -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=8 "$TARGET" \
     "\"\${RH_HOME:-\$HOME/.remote-harness}/scripts/inject-rule.sh\" on $(sq "$LAUNCH_BASE") $(sq "$PROJ_DIR") $(sq "$BOX_ALIAS") $(sq "$REMOTE_MOUNTPOINT") $(sq "$YOLO") $(sq "$BOX_SSH_CONFIG")" \
     2>/dev/null || printf 'RH_STATUS=ERROR\n')
rh_status=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_STATUS=//p' | head -1)
if [ "$rh_status" = INJECTED ]; then
  RULE_INJECTED=1
  rh_env=$(printf  '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_ENV=//p'   | head -1)
  rh_flags=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_FLAGS=//p' | head -1)
  rh_ready=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_READY_FILE=//p' | head -1)
  EFF_LAUNCH="${rh_env:+$rh_env }${EFF_LAUNCH}${rh_flags:+ $rh_flags}"
  ok "Injected session-scoped run-on-laptop rule for ${LAUNCH_BASE} (removed on exit)"
else
  err "could not install strict run-on-laptop routing ($rh_status); refusing to launch the agent"
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

hdr "Phase 5: launching ${LAUNCH}"
say "  Remote dir: ${_B}${REMOTE_MOUNTPOINT}${_0}"
say "  Your terminal becomes the remote ${LAUNCH} session. Exit ${LAUNCH} to return here."
sep

# Use a LOGIN+INTERACTIVE shell so the remote PATH (e.g. ~/.local/bin from ~/.profile / ~/.zshrc)
# is sourced — `ssh host cmd` alone runs a non-login non-interactive shell and won't find claude.
# ClearAllForwardings=yes: don't re-request the RemoteForward (Phase 2's tunnel already holds it).
# The simple bootstrap path runs this script from a pipe (`ssh cat ... | bash -s`), so stdin is not
# a terminal even though the user has a controlling tty. Attach the final interactive ssh to
# /dev/tty explicitly; otherwise OpenSSH refuses to allocate a pty and TUI agents fail immediately.
launch_remote_agent() {
  local _remote_cmd _rc
  _remote_cmd="cd $(sq "$REMOTE_MOUNTPOINT") && exec \"\${SHELL:-/bin/bash}\" -lic $(sq "$EFF_LAUNCH")"
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

# ===========================================================================
# Post-session cleanup offer
# ===========================================================================
sep
if [ "$CLAUDE_EXIT" = 0 ]; then
  ok "${LAUNCH} session ended."
else
  warn "${LAUNCH} session ended (exit code $CLAUDE_EXIT)."
fi
# cleanup() (armed via trap) auto-unmounts and drops the tunnel as this script exits.
printf "\n${_B}Done.${_0}\n"
