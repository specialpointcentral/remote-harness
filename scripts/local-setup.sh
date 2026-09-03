#!/usr/bin/env bash
# remote-harness / local-setup.sh — run ON YOUR LOCAL MACHINE (where the agent runs).
#
# FORWARD direction: the coding agent runs LOCALLY; the project lives on a directly ssh-reachable
# REMOTE server. This sshfs-mounts the server's project onto an empty LOCAL dir, injects a
# "run builds on the server" rule, and launches the agent locally in the mount. No reverse tunnel.
# SSH args and aliases are wrapped in a session-local ssh config; ~/.ssh is never written.
#
# Usage (emitted by the skill — invokes the locally-installed copy):
#   "$HOME/.remote-harness/scripts/local-setup.sh" --via '<ssh-args|alias>' \
#     --remote-path '<server project dir>' [--mountpoint '<local empty dir>'] \
#     --launch <claude|codex|opencode> [--yolo]
#
# Flags:
#   --via <ssh-args|alias>  how you ssh to the server (e.g. "-p 2222 dev@host" or "myserver")
#   --remote-path <dir>     absolute project dir ON THE SERVER to mount
#   --mountpoint <dir>      local empty dir to mount onto (default: ~/.remote-harness/mounts/<name>)
#   --launch <cmd>          agent CLI to start locally (default: claude)
#   --yolo                  bypass approvals on the launched agent
#   --yes                   non-interactive (skip confirm prompts)
set -uo pipefail

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

VIA="" RPATH="" MP="" LAUNCH="claude" YOLO=0 ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --via)         need_arg "$1" "${2-}"; VIA="$2";        shift 2;;
    --remote-path) need_arg "$1" "${2-}"; RPATH="$2";      shift 2;;
    --mountpoint)  need_arg "$1" "${2-}"; MP="$2";         shift 2;;
    --launch)      need_arg "$1" "${2-}"; LAUNCH="$2";     shift 2;;
    --yolo)        YOLO=1;          shift;;
    --yes|-y)      ASSUME_YES=1;    shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$VIA" ]   || { printf 'need --via (how to ssh to the server)\n' >&2; exit 2; }
[ -n "$RPATH" ] || { printf 'need --remote-path (project dir on the server)\n' >&2; exit 2; }

# Shared helpers (colors, say/ok/warn/ask, sq, OS vars, parse_via, write_managed_alias).
RH_COMMON="${RH_COMMON:-$(dirname "$0")/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else printf 'error: missing _common.sh next to %s\n' "$0" >&2; exit 2; fi
SCRIPTS="$(dirname "$0")"

case "$LAUNCH" in claude|codex|opencode) ;; *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;; esac
LAUNCH_BASE="$LAUNCH"
EFF_LAUNCH="$LAUNCH"
if [ "$YOLO" = 1 ]; then
  case "$LAUNCH_BASE" in
    claude)   EFF_LAUNCH="$LAUNCH --dangerously-skip-permissions";              warn "YOLO: claude --dangerously-skip-permissions";;
    codex)    EFF_LAUNCH="$LAUNCH --dangerously-bypass-approvals-and-sandbox";  warn "YOLO: codex --dangerously-bypass-approvals-and-sandbox";;
    opencode) warn "YOLO: opencode permission=allow (this session's config only)";;
  esac
fi

printf "\n${_B}remote-harness${_0} local setup ${_C}(forward)${_0}  platform=%s\n\n" "$PLAT"

# ---- auto-cleanup on exit (local unmount + rule removal) -------------------
MOUNTED=0; CLEANED=0; RULE_INJECTED=0; LOCAL_MP=""; SALIAS=""
LOCAL_SESSION_DIR=""; LOCAL_SSH_CONFIG=""
cleanup() {
  [ "$CLEANED" = 1 ] && return 0; CLEANED=1
  if [ "$MOUNTED" = 1 ]; then
    printf '\n'; say "  Session ended — unmounting ${LOCAL_MP:-}..."
    "$SCRIPTS/mount-project.sh" --alias "${SALIAS:-}" --unmount --mountpoint "${LOCAL_MP:-}" >/dev/null 2>&1 \
      && ok "Unmounted" || warn "unmount failed — run: fusermount -u '${LOCAL_MP:-}' (or umount)"
    case "${LOCAL_MP:-}" in "$HOME/.remote-harness/mounts/"*) rmdir "${LOCAL_MP:-}" 2>/dev/null || true;; esac
  fi
  if [ "${RULE_INJECTED:-0}" = 1 ]; then
    "$SCRIPTS/inject-rule.sh" off "$LAUNCH_BASE" "${LOCAL_MP:-}" >/dev/null 2>&1 \
      && ok "session rule removed" || true
  fi
  if [ -n "${LOCAL_SESSION_DIR:-}" ]; then
    rm -rf "$LOCAL_SESSION_DIR" 2>/dev/null || true
    ok "session ssh config removed"
  fi
}

# ---- resolve the server alias (ground truth = --via) -----------------------
hdr "Reaching the server"
parse_via "$VIA"
[ -z "${V_UNSUPPORTED_SSH_OPTIONS:-}" ] || {
  printf 'unsupported ssh option(s) in --via:%s\n' "$V_UNSUPPORTED_SSH_OPTIONS" >&2
  printf 'Put complex ssh options in ~/.ssh/config as a Host alias, then pass that alias.\n' >&2
  exit 2
}
[ -n "$V_HOST" ] || { printf 'could not parse --via into an ssh host/alias\n' >&2; exit 2; }
safe_ssh_token "$V_HOST" || { printf 'unsafe ssh host in --via: %s\n' "$V_HOST" >&2; exit 2; }
# Always use a session-local ssh config so known_hosts stays under ~/.remote-harness.
safe_alias_base="$(printf '%s' "$V_HOST" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//; s/[._-]*$//')"
[ -n "$safe_alias_base" ] || safe_alias_base=server
mkdir -p "$HOME/.remote-harness/.sessions" 2>/dev/null || true
LOCAL_SESSION_DIR="$(mktemp -d "$HOME/.remote-harness/.sessions/fwd.XXXXXX")" || exit 2
LOCAL_SSH_CONFIG="$LOCAL_SESSION_DIR/ssh_config"
CFG="$LOCAL_SSH_CONFIG"; touch "$CFG"; chmod 600 "$CFG" 2>/dev/null || true
write_session_ssh_defaults "$LOCAL_SESSION_DIR" \
  || { err "could not create session SSH runtime directory"; exit 1; }

# Raw connection (explicit user/port/key/jump host) → create a session-local managed alias carrying
# those exact params, so sshfs and the rule's `ssh <alias>` are stable. A bare alias/host is used
# through the session config's read-only Include of the user's ~/.ssh/config plus Host * defaults.
RAW_CONN=0; { [ -n "$V_PORT" ] || [ -n "$V_USER" ] || [ -n "$V_IDENTITY" ] || [ -n "$V_PROXYJUMP" ]; } && RAW_CONN=1
if [ "$RAW_CONN" = 0 ]; then
  SALIAS="$V_HOST"
  ok "Using ssh target: ${_B}$SALIAS${_0} (session config keeps runtime files under ~/.remote-harness)"
else
  SALIAS="$(printf '%s' "$V_HOST" | LC_ALL=C tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')-dev"
  if write_managed_alias "$SALIAS" \
      "    ServerAliveInterval 30" "    ServerAliveCountMax 3"; then
    chmod 600 "$CFG" 2>/dev/null || true
    ok "ssh config: prepared session Host '$SALIAS' (HostName ${V_HOST:-?}, port ${V_PORT:-22}, user ${V_USER:-<login default>})"
  else
    err "ssh config: could not write session Host '$SALIAS'"
    exit 2
  fi
fi
# Reachability (best effort) — warn if it'd prompt for a password (sshfs + builds would too).
ssh_probe=(ssh -F "$LOCAL_SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=8)
if "${ssh_probe[@]}" "$SALIAS" true 2>/dev/null; then
  ok "Server reachable (key auth): $SALIAS"
else
  warn "Couldn't key-auth to '$SALIAS' non-interactively — sshfs and build commands may prompt for"
  say  "  a password. Set up an ssh key to the server for a smooth, non-interactive session."
fi

# ---- local mountpoint ------------------------------------------------------
PROJ_NAME="$(basename "$RPATH")"
[ -n "$MP" ] || MP="$HOME/.remote-harness/mounts/$PROJ_NAME"
MP="${MP%/}"; LOCAL_MP="$MP"
mkdir -p "$(dirname "$MP")" 2>/dev/null || true

trap cleanup EXIT INT TERM HUP

# ---- mount (reuse mount-project.sh LOCALLY) with interactive retry ---------
hdr "Mounting the server project locally"
while :; do
  say "  ${_B}$SALIAS:$RPATH${_0} → ${_B}$MP${_0}"
  mount_args=(--alias "$SALIAS" --remote-path "$RPATH" --mountpoint "$MP" --ssh-config "$LOCAL_SSH_CONFIG")
  MOUNT_OUT=$("$SCRIPTS/mount-project.sh" "${mount_args[@]}" 2>/dev/null || true)
  STATUS=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^STATUS=/{print $2; exit}')
  case "$STATUS" in
    mounted|already-mounted) ok "Mounted ${RPATH} (on $SALIAS) → $MP"; MOUNTED=1; break;;
    need-sshfs)
      INSTALL_CMD=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^INSTALL_CMD=/{print $2; exit}')
      warn "sshfs not installed on THIS machine."
      say "  Run: ${_B}${INSTALL_CMD:-install sshfs via your package manager}${_0}"
      ask "  Installed sshfs — retry the mount?" && continue
      err "Aborted (sshfs missing)."; exit 1;;
    not-empty)
      warn "Mountpoint is not empty: $MP (sshfs would hide its contents)."
      if [ "$ASSUME_YES" = 1 ] || [ ! -e /dev/tty ]; then
        say "  Re-run with ${_B}--mountpoint <empty-dir>${_0}."; exit 1; fi
      printf '  Enter a different EMPTY local dir (blank to abort): ' >/dev/tty
      newmp=""; IFS= read -r newmp </dev/tty || true
      [ -z "$newmp" ] && { err "Aborted."; exit 1; }
      MP="${newmp%/}"; LOCAL_MP="$MP"; mkdir -p "$(dirname "$MP")" 2>/dev/null || true; continue;;
    *)
      ERR=$(printf '%s\n' "$MOUNT_OUT" | awk -F= '/^ERROR=/{print $2; exit}')
      err "Mount failed (STATUS=${STATUS:-unknown}): ${ERR:-(no detail)}"
      say "  Check: can you 'ssh $SALIAS' and is '$RPATH' a valid dir there?"; exit 1;;
  esac
done

# ---- inject the run-on-server rule (locally; scoped to this session) -------
rh_out=$("$SCRIPTS/inject-rule.sh" on "$LAUNCH_BASE" "$RPATH" "$SALIAS" "$MP" "$YOLO" "$LOCAL_SSH_CONFIG" 2>/dev/null || printf 'RH_STATUS=ERROR\n')
if [ "$(printf '%s\n' "$rh_out" | sed -n 's/^RH_STATUS=//p' | head -1)" = INJECTED ]; then
  RULE_INJECTED=1
  rh_env=$(printf  '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_ENV=//p'   | head -1)
  rh_flags=$(printf '%s\n' "$rh_out" | sed -n 's/^RH_LAUNCH_FLAGS=//p' | head -1)
  EFF_LAUNCH="${rh_env:+$rh_env }${EFF_LAUNCH}${rh_flags:+ $rh_flags}"
  ok "Injected session rule: run builds on '$SALIAS' (removed on exit)"
else
  err "could not install strict run-on-server routing; refusing to launch the agent"
  exit 1
fi

# ---- launch the agent LOCALLY, in the mount cwd ----------------------------
hdr "Launching ${LAUNCH}"
say "  Local dir: ${_B}$MP${_0}   (builds/tests run on ${_B}$SALIAS${_0})"
say "  Exit ${LAUNCH} to unmount and return."
sep
# Subshell + exec: the agent replaces the subshell (gets the tty) while THIS script waits, so the
# cleanup trap still fires on exit. Login+interactive shell so ~/.local/bin CLIs resolve. The
# RH_LAUNCH_ENV prefix (currently OPENCODE_CONFIG=; Codex uses -c developer_instructions) in EFF_LAUNCH uses the VAR=val form, which
# fish/csh/tcsh do not support — guard to bash/zsh so the env-prefix reliably reaches the agent.
_launch_shell="${SHELL:-/bin/bash}"
case "$(basename "$_launch_shell")" in fish|csh|tcsh) _launch_shell=bash;; esac
( cd "$MP" && exec "$_launch_shell" -lic "$EFF_LAUNCH" )
AGENT_EXIT=$?
sep
[ "$AGENT_EXIT" = 0 ] && ok "${LAUNCH} session ended." || warn "${LAUNCH} session ended (exit $AGENT_EXIT)."
printf "\n${_B}Done.${_0}\n"
