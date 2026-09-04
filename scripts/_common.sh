#!/usr/bin/env bash
# remote-harness / _common.sh — shared helpers, SOURCED (not executed) by the two setup scripts:
#   laptop-setup.sh  (reverse: agent on a remote box, code on the laptop — reverse tunnel)
#   local-setup.sh   (disabled compatibility entry; local agents are not supported)
# Both source it via:  . "$(dirname "$0")/_common.sh"
# For the reverse flow the skill's one-command fetches THIS file next to laptop-setup.sh so the
# laptop (which usually has no install) still finds it. Sets colors + OS vars at source time and
# defines output/quoting/ssh-config helpers. Sourced files must NOT set -e or exit.
# shellcheck disable=SC2034 # this library intentionally sets variables for callers.

# ---- colors (ANSI, only when stdout is a real terminal) --------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1 \
     && [ "$(tput colors 2>/dev/null)" -ge 8 ]; then
  _B=$(tput bold 2>/dev/null)     # bold
  _G=$(tput setaf 2 2>/dev/null)  # green
  _Y=$(tput setaf 3 2>/dev/null)  # yellow
  _C=$(tput setaf 6 2>/dev/null)  # cyan
  _R=$(tput setaf 1 2>/dev/null)  # red
  _D=$(tput setaf 4 2>/dev/null)  # dim blue (for headers)
  _0=$(tput sgr0 2>/dev/null)     # reset
else
  _B="" _G="" _Y="" _C="" _R="" _D="" _0=""
fi

# ---- output helpers --------------------------------------------------------
say()  { printf '%s\n' "$*"; }
ok()   { printf "  ${_G}✓${_0} %s\n" "$*"; }
warn() { printf "  ${_Y}⚠${_0} %s\n" "$*"; }
err()  { printf "  ${_R}✗${_0} %s\n" "$*" >&2; }
hdr()  { printf "\n${_B}${_D}── %s${_0}\n" "$*"; }
sep()  { printf '\n'; }
# Yes/no prompt on the tty. Honors a caller-set ASSUME_YES=1 (non-interactive).
ask() {
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  printf "${_Y}?${_0} %s [y/N] " "$1" >/dev/tty
  local a=""; read -r a </dev/tty || true
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# Shell-quote a value for SAFE interpolation into a remote command string: wrap in single quotes,
# escaping any embedded single quote as '\''. Prevents paths with apostrophes (legal on macOS) from
# breaking — or injecting into — the ssh command strings the setup scripts build.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    return 2
  fi
  return 0
}

safe_ssh_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]]*) return 1;;
    *) return 0;;
  esac
}

ssh_config_value() {
  case "$1" in
    *[[:space:]\"\\]*)
      printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      ;;
    *) printf '%s' "$1";;
  esac
}

# Write per-session SSH defaults that keep SSH runtime files out of ~/.ssh.
# Callers may append Host blocks after this prelude. If a user-managed
# ~/.ssh/config exists it is included read-only, after the defaults, so HostName,
# User, Port, IdentityFile, ProxyJump, etc. still resolve for aliases while
# known_hosts stays inside the remote-harness session directory.
#
# Multiplexing is deliberately disabled. OpenSSH ControlPath is a Unix socket path; on macOS the
# effective path limit is short enough that otherwise-valid session dirs can fail before sshfs starts.
write_session_ssh_defaults() {
  _wssd_dir="$1"
  _wssd_runtime="$_wssd_dir/runtime"
  mkdir -p "$_wssd_runtime" 2>/dev/null || return 1
  chmod 700 "$_wssd_runtime" 2>/dev/null || true
  _wssd_kh="${2:-$_wssd_runtime/known_hosts}"
  {
    printf 'Host *\n'
    printf '    UserKnownHostsFile %s\n' "$(ssh_config_value "$_wssd_kh")"
    printf '    GlobalKnownHostsFile /dev/null\n'
    printf '    StrictHostKeyChecking accept-new\n'
    printf '    ControlMaster no\n'
    if [ -r "$HOME/.ssh/config" ]; then
      printf 'Include %s\n' "$(ssh_config_value "$HOME/.ssh/config")"
    fi
  } >> "$CFG"
}

# ---- OS detection (sets OS / PLAT / IS_WSL at source time) -----------------
OS="$(uname -s 2>/dev/null || echo unknown)"; IS_WSL=0
case "$OS" in
  Darwin) PLAT=macos;;
  Linux)  PLAT=linux; grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && IS_WSL=1;;
  *)      PLAT=other;;
esac

# ---- parse an ssh-args / alias string into V_* fields ----------------------
# Accepts either a bare alias ("myserver") or raw args ("-J jump -p 2222 user@host -i ~/.k"). The
# value is intentionally word-split (unquoted) — NOT eval'd — so a crafted/mistyped string can't run
# locally. Quoted ProxyCommand-style values with spaces are not supported; use a Host alias for that.
parse_ssh_option() {
  local _pso_name _pso_value
  _pso_name="${1%%=*}"
  _pso_value="${1#*=}"
  [ "$_pso_name" = "$1" ] && _pso_value=""
  case "$(printf '%s' "$_pso_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    hostname)     [ -n "$_pso_value" ] && V_HOST="$_pso_value";;
    port)         [ -n "$_pso_value" ] && V_PORT="$_pso_value";;
    user)         [ -n "$_pso_value" ] && V_USER="$_pso_value";;
    identityfile) [ -n "$_pso_value" ] && V_IDENTITY="$_pso_value";;
    proxyjump)    [ -n "$_pso_value" ] && V_PROXYJUMP="$_pso_value";;
    *)            V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -o $_pso_name";;
  esac
}
parse_via() {
  V_HOST="" V_PORT="" V_USER="" V_IDENTITY="" V_PROXYJUMP="" V_UNSUPPORTED_SSH_OPTIONS=""
  [ -n "${1:-}" ] || return 0
  # shellcheck disable=SC2086 # intentional ssh-arg word splitting; never eval'd.
  set -- $1
  [ "${1:-}" = "ssh" ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -p)  if [ $# -ge 2 ]; then V_PORT="$2"; shift 2; else V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -p"; shift; fi;;
      -p*) V_PORT="${1#-p}"; shift;;
      -l)  if [ $# -ge 2 ]; then V_USER="$2"; shift 2; else V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -l"; shift; fi;;
      -i)  if [ $# -ge 2 ]; then V_IDENTITY="$2"; shift 2; else V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -i"; shift; fi;;
      -i*) V_IDENTITY="${1#-i}"; shift;;
      -J)  if [ $# -ge 2 ]; then V_PROXYJUMP="$2"; shift 2; else V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -J"; shift; fi;;
      -J*) V_PROXYJUMP="${1#-J}"; shift;;
      -o)
        if [ -n "${2:-}" ]; then
          case "$2" in
            *=*) parse_ssh_option "$2"; shift 2;;
            HostName|hostname|Port|port|User|user|IdentityFile|identityfile|ProxyJump|proxyjump)
              if [ $# -ge 3 ]; then parse_ssh_option "$2=$3"; shift 3
              else V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -o $2"; shift $#; fi;;
            *) V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} -o $2"; if [ $# -ge 2 ]; then shift 2; else shift; fi;;
          esac
        else
          shift
        fi
        ;;
      -o*) parse_ssh_option "${1#-o}"; shift;;
      -F|-b|-c|-m|-w|-D|-L|-R|-W|-E|-Q|-S)
        V_UNSUPPORTED_SSH_OPTIONS="${V_UNSUPPORTED_SSH_OPTIONS:-} $1"
        if [ $# -ge 2 ]; then shift 2; else shift; fi;;
      -*)  shift;;
      *)   if [ -z "$V_HOST" ]; then case "$1" in *@*) V_USER="${1%@*}"; V_HOST="${1##*@}";; *) V_HOST="$1";; esac; fi; shift;;
    esac
  done
}

# True if a "Host <name>" block exists in $CFG (exact token match, ignoring inline comments).
block_exists() { awk -v h="$1" '/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/{for(i=2;i<=NF;i++){if($i=="#")break;if($i==h)f=1}}END{exit !f}' "$CFG"; }
# Drop the whole "Host <name>" block (Host line .. next Host / EOF) from $CFG, in place.
remove_host_block() {
  awk -v h="$1" '
    function H(s){return s~/^[ \t]*[Hh][Oo][Ss][Tt][ \t]/}
    H($0){drop=0;n=split($0,a,/[ \t]+/);for(i=2;i<=n;i++){if(a[i]=="#")break;if(a[i]==h)drop=1}}
    drop!=1{print}' "$CFG" > "$CFG.rhtmp" && mv "$CFG.rhtmp" "$CFG"
}
# Create-or-replace a managed Host block in $CFG from the parsed V_* vars. $1 = alias name;
# any further args are extra indented lines appended verbatim (e.g. a RemoteForward line, or
# ControlMaster/keepalive lines). Idempotent (removes any prior block of the same name first).
write_managed_alias() {
  _wma_alias="$1"; shift
  safe_ssh_token "$_wma_alias" || { printf 'unsafe ssh Host alias: %s\n' "$_wma_alias" >&2; return 2; }
  [ -z "${V_HOST:-}" ] || safe_ssh_token "$V_HOST" || { printf 'unsafe ssh HostName: %s\n' "$V_HOST" >&2; return 2; }
  [ -z "${V_USER:-}" ] || safe_ssh_token "$V_USER" || { printf 'unsafe ssh User: %s\n' "$V_USER" >&2; return 2; }
  [ -z "${V_PROXYJUMP:-}" ] || safe_ssh_token "$V_PROXYJUMP" || { printf 'unsafe ssh ProxyJump: %s\n' "$V_PROXYJUMP" >&2; return 2; }
  remove_host_block "$_wma_alias"
  { printf '\nHost %s\n' "$_wma_alias"
    [ -n "${V_HOST:-}" ]                            && printf '    HostName %s\n' "$(ssh_config_value "$V_HOST")"
    [ -n "${V_PORT:-}" ] && [ "${V_PORT}" != 22 ]   && printf '    Port %s\n' "$V_PORT"
    [ -n "${V_USER:-}" ]                            && printf '    User %s\n' "$(ssh_config_value "$V_USER")"
    [ -n "${V_IDENTITY:-}" ]                        && printf '    IdentityFile %s\n' "$(ssh_config_value "$V_IDENTITY")"
    [ -n "${V_PROXYJUMP:-}" ]                       && printf '    ProxyJump %s\n' "$(ssh_config_value "$V_PROXYJUMP")"
    for _wma_line in "$@"; do printf '%s\n' "$_wma_line"; done
  } >> "$CFG"
}
