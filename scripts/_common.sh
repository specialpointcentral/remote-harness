#!/usr/bin/env bash
# remote-harness / _common.sh — shared helpers, SOURCED (not executed) on the local machine by
# laptop-setup.sh, simple-laptop-setup.sh and simple-dispatch.sh, each from beside itself (or
# $RH_COMMON). The bootstrap fetches THIS file next to them, so a laptop without an install still
# finds it. Sets colors + OS vars at source time and defines output/quoting/ssh-config helpers.
# Sourcing must not set -e or exit; only need_arg exits, on a usage error.
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
say()  { step_freeze; printf '%s\n' "$*"; }
ok()   { step_freeze; printf "  ${_G}✓${_0} %s\n" "$*"; }
warn() { step_freeze; printf "  ${_Y}⚠${_0} %s\n" "$*"; }
err()  { step_freeze; printf "  ${_R}✗${_0} %s\n" "$*" >&2; }
hdr()  { step_freeze; printf "\n${_B}${_D}── %s${_0}\n" "$*"; }
sep()  { step_freeze; printf '\n'; }
is_zh() { case "${RH_LANG:-en}" in zh|zh_*|zh-*|cn|CN|中文) return 0;; *) return 1;; esac; }
tr2()   { if is_zh; then printf '%s' "$2"; else printf '%s' "$1"; fi; }  # $1 English, $2 Chinese
# Package install hint for this machine (macOS: Homebrew; Linux: the detected package manager).
pkg_install_hint() {  # $1 = package name
  case "$(uname -s 2>/dev/null)" in Darwin) printf 'brew install %s' "$1"; return;; esac
  if   command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$1"
  elif command -v dnf     >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$1"
  elif command -v pacman  >/dev/null 2>&1; then printf 'sudo pacman -S --noconfirm %s' "$1"
  elif command -v zypper  >/dev/null 2>&1; then printf 'sudo zypper install -y %s' "$1"
  elif command -v apk     >/dev/null 2>&1; then printf 'sudo apk add %s' "$1"
  else printf "install '%s' with your package manager" "$1"; fi
}

# ---- step progress -----------------------------------------------------------
# One line per step: "[n/T] ⠹ label…  12s" with a live spinner on a terminal, then
# "[n/T] ✓ label  3s" (⚠ / ✗ on warn / fail). Elapsed time, not a percentage: network-bound steps
# have no predictable duration. Off a terminal (pipes, tests, RH_NO_PROGRESS=1) every step prints a
# plain start line and a plain end line. Any other output or prompt during a step first freezes the
# spinner line, so nothing it prints, and no prompt, is ever overwritten. The counter continues
# across exec through RH_STEP_BASE; laptop-setup.sh contributes RH_LAPTOP_STEPS steps.
RH_LAPTOP_STEPS=6
STEP_N="${RH_STEP_BASE:-0}" STEP_TOTAL=0 STEP_LABEL="" STEP_T0=0 STEP_SPIN_PID=""
step_tty() { [ -t 1 ] && [ -z "${RH_NO_PROGRESS:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
step_stop_spinner() {
  [ -n "$STEP_SPIN_PID" ] || return 0
  # SIGKILL: the spinner needs no cleanup, and a trapped TERM in a subshell makes macOS bash 3.2
  # print "run_pending_traps: bad value in trap_list" warnings.
  kill -KILL "$STEP_SPIN_PID" 2>/dev/null || true
  wait "$STEP_SPIN_PID" 2>/dev/null || true
  STEP_SPIN_PID=""
  printf '\r\033[K'
}
step_spin() {  # draw the current step until stopped; exits on its own if the main shell dies
  local _prefix="[$STEP_N/$STEP_TOTAL]"
  (
    _owner=$$ _i=0 _frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while kill -0 "$_owner" 2>/dev/null; do
      printf "\r\033[K  %s ${_C}%s${_0} %s…  ${_D}%ss${_0}" "$_prefix" "${_frames[$_i]}" "$STEP_LABEL" "$((SECONDS - STEP_T0))"
      _i=$(( (_i + 1) % 10 )); sleep 0.15
    done
  ) 2>/dev/null &
  STEP_SPIN_PID=$!
}
# Freeze a running spinner into a static line. Only the main shell owns the spinner; output from a
# command substitution must not touch it.
step_freeze() {
  [ -n "$STEP_SPIN_PID" ] && [ "${BASH_SUBSHELL:-0}" = 0 ] || return 0
  step_stop_spinner
  printf "  [%s/%s] ${_C}⋯${_0} %s…\n" "$STEP_N" "$STEP_TOTAL" "$STEP_LABEL"
}
step_begin() {  # [-s] LABEL   (-s: no spinner, for steps that may prompt or run sudo)
  local _spin=1
  [ "${1:-}" = -s ] && { _spin=0; shift; }
  [ -z "$STEP_LABEL" ] || step_end ok
  STEP_N=$((STEP_N + 1)) STEP_LABEL="$1" STEP_T0=$SECONDS
  [ "$STEP_TOTAL" -ge "$STEP_N" ] || STEP_TOTAL=$STEP_N
  if [ "$_spin" = 1 ] && step_tty; then step_spin
  else printf "  [%s/%s] %s…\n" "$STEP_N" "$STEP_TOTAL" "$STEP_LABEL"; fi
}
step_label() {  # rename the running step (e.g. while waiting on something specific); keeps its timer
  [ -n "$STEP_LABEL" ] || return 0
  STEP_LABEL="$1"
  if [ -n "$STEP_SPIN_PID" ]; then step_stop_spinner; step_spin
  else printf "  [%s/%s] %s…\n" "$STEP_N" "$STEP_TOTAL" "$1"; fi
}
step_end() {  # ok|warn|fail [detail]
  [ -n "$STEP_LABEL" ] || return 0
  local _mark
  case "${1:-ok}" in warn) _mark="${_Y}⚠${_0}";; fail) _mark="${_R}✗${_0}";; *) _mark="${_G}✓${_0}";; esac
  step_stop_spinner
  printf "  [%s/%s] %s %s%s  ${_D}%ss${_0}\n" "$STEP_N" "$STEP_TOTAL" "$_mark" "$STEP_LABEL" "${2:+ — $2}" "$((SECONDS - STEP_T0))"
  STEP_LABEL=""
}
step_reset() {  # $1 = total steps of a new sequence (e.g. the exit cleanup)
  step_stop_spinner
  STEP_LABEL="" STEP_N=0 STEP_TOTAL="$1"
}

# Yes/no prompt on the tty. Honors a caller-set ASSUME_YES=1 (non-interactive).
ask() {  # question [y]   (y: default yes)
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  step_freeze
  local a=""
  if [ "${2:-n}" = y ]; then
    printf "${_Y}?${_0} %s [Y/n] " "$1" >/dev/tty
    read -r a </dev/tty || true
    case "$a" in n|N|no|NO|否) return 1;; *) return 0;; esac
  fi
  printf "${_Y}?${_0} %s [y/N] " "$1" >/dev/tty
  read -r a </dev/tty || true
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# A process's start time as `ps -o lstart` prints it, trimmed: with the pid it identifies the process.
proc_start() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# Shell-quote a value for SAFE interpolation into a remote command string: wrap in single quotes,
# escaping any embedded single quote as '\''. Prevents paths with apostrophes (legal on macOS) from
# breaking — or injecting into — the ssh command strings the setup scripts build.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# First value of KEY in KEY=VALUE lines on stdin (values may contain '=').
kv_value() { sed -n "s/^$1=//p" | head -1; }

# Option parsing: a flag without a value is a usage error that ends the script.
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
  V_HOST="" V_PORT="" V_USER="" V_IDENTITY="" V_PROXYJUMP="" V_PROXYCOMMAND="" V_IDENTITIESONLY=""
  V_UNSUPPORTED_SSH_OPTIONS=""
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
  case "${V_PROXYCOMMAND:-}" in *"$(printf '\r')"*|*'
'*) printf 'unsafe ssh ProxyCommand: contains a line break\n' >&2; return 2;; esac
  case "${V_IDENTITIESONLY:-}" in ""|yes|no) ;; *) printf 'unsafe ssh IdentitiesOnly: %s\n' "$V_IDENTITIESONLY" >&2; return 2;; esac
  remove_host_block "$_wma_alias"
  { printf '\nHost %s\n' "$_wma_alias"
    [ -n "${V_HOST:-}" ]                            && printf '    HostName %s\n' "$(ssh_config_value "$V_HOST")"
    [ -n "${V_PORT:-}" ] && [ "${V_PORT}" != 22 ]   && printf '    Port %s\n' "$V_PORT"
    [ -n "${V_USER:-}" ]                            && printf '    User %s\n' "$(ssh_config_value "$V_USER")"
    [ -n "${V_IDENTITY:-}" ]                        && printf '    IdentityFile %s\n' "$(ssh_config_value "$V_IDENTITY")"
    [ -n "${V_PROXYJUMP:-}" ]                       && printf '    ProxyJump %s\n' "$(ssh_config_value "$V_PROXYJUMP")"
    # ProxyCommand takes the rest of the line verbatim (quoting it would break the command). It only
    # comes from the user's own resolved Host alias (ssh -G), never from parsed --via words.
    [ -z "${V_PROXYJUMP:-}" ] && [ -n "${V_PROXYCOMMAND:-}" ] && printf '    ProxyCommand %s\n' "$V_PROXYCOMMAND"
    [ -n "${V_IDENTITIESONLY:-}" ]                  && printf '    IdentitiesOnly %s\n' "$V_IDENTITIESONLY"
    for _wma_line in "$@"; do printf '%s\n' "$_wma_line"; done
  } >> "$CFG"
}

# ---- user-mode sshd (reverse tunnel target) --------------------------------
# Some laptops run an sshd that never reads ~/.ssh/authorized_keys (FreeIPA/sssd or LDAP key lookup,
# AuthorizedKeysFile none, a root-squashed NFS home), or have no SSH server and no root. For those,
# laptop-setup.sh starts a per-session sshd as the current user instead: loopback only, public keys
# only from a session-private authorized_keys file, no PAM, no forwarding, no TTY. The tunnel then
# forwards to its port rather than 127.0.0.1:22.

# Absolute sshd path (sshd re-executes itself by argv[0], so a relative path breaks every connection).
user_sshd_bin() {
  local _usb_c
  for _usb_c in /usr/sbin/sshd /usr/local/sbin/sshd /opt/homebrew/sbin/sshd "$(command -v sshd 2>/dev/null)"; do
    case "$_usb_c" in /*) [ -x "$_usb_c" ] && { printf '%s' "$_usb_c"; return 0; };; esac
  done
  return 1
}

local_port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# A free loopback port from a random start in 20000-59999, so concurrent sessions rarely probe the
# same ports; the bind in user_sshd_start is the real check and retries on a lost race.
user_sshd_pick_port() {
  local _usp_port _usp_n=0
  _usp_port=$((20000 + (RANDOM * 32768 + RANDOM) % 40000))
  while [ "$_usp_n" -lt 200 ]; do
    if local_port_free "$_usp_port"; then printf '%s' "$_usp_port"; return 0; fi
    _usp_port=$((_usp_port + 1)); [ "$_usp_port" -lt 60000 ] || _usp_port=20000
    _usp_n=$((_usp_n + 1))
  done
  return 1
}

# Hint for the wizard: does the system sshd look up keys outside ~/.ssh/authorized_keys, or is no SSH
# server listening on :22? Prints the reason. Unreadable config files simply give no hint.
local_sshd_user_mode_hint() {
  local _lsh_files
  if local_port_free 22; then printf 'no-sshd'; return 0; fi
  _lsh_files=$( { printf '%s\n' "${RH_SSHD_CONFIG:-/etc/ssh/sshd_config}"
                  find "${RH_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}" -name '*.conf' 2>/dev/null; } )
  # shellcheck disable=SC2086 # newline-separated config paths without spaces.
  if (IFS='
'; awk 'tolower($1)=="authorizedkeyscommand" && tolower($2)!="none" {f=1}
        tolower($1)=="authorizedkeysfile" && tolower($2)=="none" {f=1}
        END {exit !f}' $_lsh_files 2>/dev/null); then
    printf 'external-keys'; return 0
  fi
  return 1
}

user_sshd_write_config() {  # dir port user
  local _usw_allow=""
  case "$3" in ""|*[!A-Za-z0-9._-]*) ;; *) _usw_allow="AllowUsers $3";; esac
  cat > "$1/sshd_config" <<EOF || return 1
# remote-harness user-mode sshd: loopback only, this session's forced-gateway key only.
ListenAddress 127.0.0.1
Port $2
HostKey $(ssh_config_value "$1/host_ed25519_key")
PidFile $(ssh_config_value "$1/sshd.pid")
AuthorizedKeysFile $(ssh_config_value "$1/authorized_keys")
AuthorizedKeysCommand none
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
HostbasedAuthentication no
UsePAM no
PermitRootLogin no
$_usw_allow
PermitTTY no
DisableForwarding yes
PermitTunnel no
PermitUserRC no
PermitUserEnvironment no
PrintMotd no
UseDNS no
ClientAliveInterval 30
ClientAliveCountMax 3
# With the forced gateway, an sftp request reaches it as SSH_ORIGINAL_COMMAND=internal-sftp.
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF
  chmod 600 "$1/sshd_config" 2>/dev/null || true
}

# sshd StrictModes refuses a key file when a directory above it (up to the home directory, or / for a
# file outside it) is writable by group or others, or owned by anyone but the user or root. A umask of
# 002 (common for FreeIPA user-private groups) leaves ~/.remote-harness group-writable, so this drops
# group/other write from the user's own directories below the home directory, then prints the first
# directory that StrictModes would still refuse; it fails when there is none.
user_sshd_unsafe_dir() {  # dir (absolute, physical)
  local _uud_d="$1" _uud_home _uud_uid _uud_ls _uud_mode _uud_links _uud_owner
  _uud_home=$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd -P) || _uud_home=""
  _uud_uid=$(id -u)
  while :; do
    case "$_uud_d" in "$_uud_home"/*) [ ! -O "$_uud_d" ] || chmod go-w "$_uud_d" 2>/dev/null;; esac
    _uud_ls=$(ls -ldn "$_uud_d" 2>/dev/null) || { printf '%s' "$_uud_d"; return 0; }
    read -r _uud_mode _uud_links _uud_owner _ <<EOF
$_uud_ls
EOF
    case "$_uud_owner" in "$_uud_uid"|0) ;; *) printf '%s' "$_uud_d"; return 0;; esac
    case "$_uud_mode" in ?????w*|????????w*) printf '%s' "$_uud_d"; return 0;; esac
    if [ "$_uud_d" = "$_uud_home" ] || [ "$_uud_d" = / ]; then return 1; fi
    _uud_d=$(dirname "$_uud_d")
  done
}

# Start the session sshd in <dir> (absolute; holds its host key, authorized_keys, config, pid, log)
# on a free loopback port, retrying another port when the bind loses a race. Sets USER_SSHD_PORT,
# USER_SSHD_PID, USER_SSHD_START, USER_SSHD_CFG and USER_SSHD_LOG. Returns 2 when no sshd binary
# exists, and 3 with USER_SSHD_UNSAFE_DIR set when StrictModes would refuse its authorized_keys.
user_sshd_start() {  # dir user
  local _uss_dir="$1" _uss_user="$2" _uss_port _uss_bin _uss_try=0 _uss_n _uss_pid
  USER_SSHD_PORT="" USER_SSHD_PID="" USER_SSHD_START="" USER_SSHD_UNSAFE_DIR=""
  _uss_bin=$(user_sshd_bin) || return 2
  mkdir -p "$_uss_dir" 2>/dev/null && chmod 700 "$_uss_dir" 2>/dev/null || return 1
  _uss_dir=$(CDPATH= cd -- "$_uss_dir" 2>/dev/null && pwd -P) || return 1
  if USER_SSHD_UNSAFE_DIR=$(user_sshd_unsafe_dir "$_uss_dir"); then return 3; fi
  USER_SSHD_CFG="$_uss_dir/sshd_config"
  USER_SSHD_LOG="$_uss_dir/sshd.log"
  if [ ! -f "$_uss_dir/host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C remote-harness-user-sshd -f "$_uss_dir/host_ed25519_key" \
      </dev/null >/dev/null 2>&1 || return 1
  fi
  [ -f "$_uss_dir/authorized_keys" ] || : > "$_uss_dir/authorized_keys" || return 1
  chmod 600 "$_uss_dir/authorized_keys" "$_uss_dir/host_ed25519_key" 2>/dev/null || true
  while [ "$_uss_try" -lt 5 ]; do
    _uss_try=$((_uss_try + 1))
    _uss_port=$(user_sshd_pick_port) || return 1
    user_sshd_write_config "$_uss_dir" "$_uss_port" "$_uss_user" || return 1
    rm -f "$_uss_dir/sshd.pid"
    # sshd binds before it daemonizes, so a lost port race fails here and the loop picks another.
    if "$_uss_bin" -f "$USER_SSHD_CFG" -E "$USER_SSHD_LOG" </dev/null >/dev/null 2>&1; then
      _uss_n=0
      while [ "$_uss_n" -lt 25 ]; do
        _uss_pid=""; read -r _uss_pid 2>/dev/null < "$_uss_dir/sshd.pid"
        case "$_uss_pid" in
          ''|*[!0-9]*) ;;
          *) if kill -0 "$_uss_pid" 2>/dev/null && ! local_port_free "$_uss_port"; then
               USER_SSHD_PORT="$_uss_port" USER_SSHD_PID="$_uss_pid" USER_SSHD_START=$(proc_start "$_uss_pid")
               return 0
             fi;;
        esac
        sleep 0.2; _uss_n=$((_uss_n + 1))
      done
      case "$_uss_pid" in ''|*[!0-9]*) ;; *) kill "$_uss_pid" 2>/dev/null || true;; esac
    fi
  done
  return 1
}

# The last sshd log lines that explain a refused or failed connection.
user_sshd_log_reasons() {
  [ -r "${1:-}" ] || return 0
  grep -E 'refused|Failed|fatal|error|Cannot|bad ownership|Authentication' "$1" 2>/dev/null | tail -"${2:-5}"
}
