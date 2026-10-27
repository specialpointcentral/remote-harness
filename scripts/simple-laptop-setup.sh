#!/usr/bin/env bash
# remote-harness / simple-laptop-setup.sh - run ON THE LAPTOP.
#
# A local, privacy-preserving wizard for the reverse flow. The coding agent
# prints one generic bootstrap command; this script collects the concrete SSH
# target, project dir, optional remote mountpoint, and launch preference in the
# user's terminal, then delegates to laptop-setup.sh for the proven
# tunnel/mount/launch phases.
set -uo pipefail
set -f

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RH_COMMON="${RH_COMMON:-$SCRIPT_DIR/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else
  printf 'error: missing _common.sh next to %s\n' "$0" >&2
  exit 2
fi

prompt_line() {  # $1=label $2=default $3=required [$4=path: Tab completes local file names]
  _label="$1"
  _default="${2:-}"
  _required="${3:-0}"
  _answer=""
  while :; do
    if [ -n "$_default" ]; then
      _shown=$(printf '%s [%s]: ' "$_label" "$_default")
    else
      _shown=$(printf '%s: ' "$_label")
    fi
    if [ "${4:-}" = path ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
      # readline (read -e): Tab completes file names and the arrow keys edit. It draws the prompt and
      # the echo itself, so both go to the terminal. The default is shown, never prefilled: with -i a
      # pasted absolute path would be appended to it.
      IFS= read -r -e -p "$_shown" _answer </dev/tty 2>/dev/tty || _answer=""
    elif [ -r /dev/tty ]; then
      printf '%s' "$_shown" >/dev/tty
      IFS= read -r _answer </dev/tty || _answer=""
    else
      printf '%s' "$_shown" >/dev/tty
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    if [ "$_required" != 1 ] || [ -n "$_answer" ]; then
      printf '%s' "$_answer"
      return 0
    fi
    if is_zh; then warn "该值必填。" >&2; else warn "This value is required." >&2; fi
  done
}

prompt_yes_no() {
  _label="$1"
  _default="${2:-n}"
  if [ "$ASSUME_YES" = 1 ]; then
    [ "$_default" = y ] || [ "$_default" = Y ]
    return $?
  fi
  while :; do
    case "$_default" in y|Y) _suffix="[Y/n]";; *) _suffix="[y/N]";; esac
    printf '%s %s ' "$_label" "$_suffix" >/dev/tty
    _answer=""
    if [ -r /dev/tty ]; then
      IFS= read -r _answer </dev/tty || _answer=""
    else
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    case "$_answer" in
      y|Y|yes|YES|Yes|是|好) return 0;;
      n|N|no|NO|No|否|不) return 1;;
      *) if is_zh; then warn "请输入 y 或 n。" >&2; else warn "Please answer y or n." >&2; fi;;
    esac
  done
}

trim_via() {
  _v="$1"
  _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_v" in
    ssh[[:space:]]*) _v="${_v#ssh }"; _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//')";;
  esac
  printf '%s' "$_v"
}

sanitize_namespace() {
  _v="$(printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//; s/[._-]*$//')"
  [ -n "$_v" ] || _v="user"
  printf '%s' "$_v"
}

# The prompts run inside $(...), so their warnings go to stderr: on stdout they would become part of
# the answer.
# Blanks around a typed path are a typo, not part of it: ASCII ones, and those that input methods and
# copy-paste bring along (no-break, ideographic and zero-width spaces, a byte-order mark).
trim_blanks() {
  _tb=$1
  while :; do
    _tb_before=$_tb
    _tb="${_tb#"${_tb%%[![:space:]]*}"}"
    _tb="${_tb%"${_tb##*[![:space:]]}"}"
    for _tb_blank in $'\xc2\xa0' $'\xe3\x80\x80' $'\xe2\x80\x8b' $'\xef\xbb\xbf'; do
      _tb="${_tb#"$_tb_blank"}"
      _tb="${_tb%"$_tb_blank"}"
    done
    [ "$_tb" != "$_tb_before" ] || break
  done
  printf '%s' "$_tb"
}

expand_project_dir() {
  # `${_v#??}` drops the "~/": an unquoted ~ in a pattern is itself tilde-expanded and never matches.
  _v=$(trim_blanks "$1")
  case "$_v" in
    "~") _v="$HOME";;
    "~/"*) _v="$HOME/${_v#??}";;
  esac
  printf '%s' "${_v%/}"
}

choose_project_dir() {
  _candidate="${1:-}"
  _prompt="${2:-0}"
  while :; do
    if [ "$_prompt" = 1 ] || [ -z "$_candidate" ]; then
      _default="${_candidate:-$PWD}"
      if is_zh; then
        _candidate="$(prompt_line '本地项目目录' "$_default" 1 path)"
      else
        _candidate="$(prompt_line 'Local project directory' "$_default" 1 path)"
      fi
      _prompt=0
    fi
    _candidate="$(expand_project_dir "$_candidate")"
    if [ -d "$_candidate" ]; then
      (cd "$_candidate" 2>/dev/null && pwd -P) || printf '%s' "$_candidate"
      return 0
    fi
    if is_zh; then warn "项目目录不存在：'$_candidate'" >&2; else warn "Project directory does not exist: '$_candidate'" >&2; fi
    _candidate=""
  done
}

cache_file() {
  printf '%s' "${RH_SIMPLE_CACHE:-$HOME/.remote-harness/simple-cache.env}"
}

cache_get() {
  _key="$1"
  _cache="$(cache_file)"
  [ -r "$_cache" ] || return 0
  sed -n "s/^${_key}=//p" "$_cache" | tail -1
}

cache_save() {
  _cache="$(cache_file)"
  mkdir -p "$(dirname "$_cache")" 2>/dev/null || true
  _tmp="$(mktemp "${_cache}.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$_cache" ]; then
    grep -v -E '^(LAST_VIA|LAST_PROJECT_DIR|LAST_REMOTE_MOUNTPOINT|LAST_MOUNT_PROJECT|LAST_LAUNCH|LAST_YOLO|LAST_APPROVAL|LAST_LOCAL_SSHD)=' "$_cache" 2>/dev/null > "$_tmp" || true
  fi
  for _kv in \
    "LAST_VIA=$VIA" \
    "LAST_PROJECT_DIR=$PROJECT_DIR" \
    "LAST_REMOTE_MOUNTPOINT=$REMOTE_MP" \
    "LAST_MOUNT_PROJECT=$PROJECT_DIR" \
    "LAST_LAUNCH=$LAUNCH" \
    "LAST_APPROVAL=$APPROVAL" \
    "LAST_LOCAL_SSHD=$LOCAL_SSHD"; do
    case "$_kv" in *'
'*|LAST_LOCAL_SSHD=auto) continue;; esac
    printf '%s\n' "$_kv" >> "$_tmp"
  done
  mv "$_tmp" "$_cache" 2>/dev/null && chmod 600 "$_cache" 2>/dev/null || true
}

VIA="" LAUNCH="codex" APPROVAL=""
NAMESPACE="" PROJECT_DIR="" REMOTE_MP="" ASSUME_YES=0
LOCAL_SSHD="${RH_LOCAL_SSHD:-auto}"
while [ $# -gt 0 ]; do
  case "$1" in
    --via)               need_arg "$1" "${2-}"; VIA="$2"; shift 2;;
    --launch)            need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --approval)          need_arg "$1" "${2-}"; APPROVAL="$2"; shift 2;;
    --yolo)              APPROVAL=yolo; shift;;
    --namespace)         need_arg "$1" "${2-}"; NAMESPACE="$2"; shift 2;;
    --project-dir)       need_arg "$1" "${2-}"; PROJECT_DIR="$2"; shift 2;;
    --remote-mountpoint) need_arg "$1" "${2-}"; REMOTE_MP="$2"; shift 2;;
    --local-sshd)        need_arg "$1" "${2-}"; LOCAL_SSHD="$2"; shift 2;;
    --yes|-y)            ASSUME_YES=1; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac
case "$APPROVAL" in
  ""|normal|auto|yolo) ;;
  *) printf 'unsupported --approval %s (expected normal|auto|yolo)\n' "$APPROVAL" >&2; exit 2;;
esac
case "$LOCAL_SSHD" in
  auto|"") LOCAL_SSHD=auto;;
  system|user) ;;
  *) printf 'unsupported --local-sshd %s (expected auto|system|user)\n' "$LOCAL_SSHD" >&2; exit 2;;
esac

if is_zh; then
  hdr "Simple 反向连接设置"
  say "这个向导只在本地运行。Agent 不会收到你的 SSH 目标、项目路径或挂载路径。"
else
  hdr "Simple reverse setup"
  say "This wizard runs locally. The coding agent does not receive your SSH target, project path, or mount path."
fi
sep

if [ -z "$VIA" ]; then
  cached_via="$(cache_get LAST_VIA)"
  default_via="${cached_via:-${RH_DEFAULT_VIA:-}}"
  if is_zh; then
    VIA="$(prompt_line '远端 SSH 目标/参数（不要带开头的 ssh；推荐 Host 别名）' "$default_via" 1)"
  else
    VIA="$(prompt_line 'Remote box SSH target/args (omit leading ssh; Host alias is best)' "$default_via" 1)"
  fi
fi
VIA="$(trim_via "$VIA")"
[ -n "$VIA" ] || { if is_zh; then err "未提供 SSH 目标/参数。"; else err "No SSH target/args provided."; fi; exit 2; }

parse_via "$VIA"
[ -z "${V_UNSUPPORTED_SSH_OPTIONS:-}" ] || {
  if is_zh; then
    err "不支持这些原始 ssh 选项：${V_UNSUPPORTED_SSH_OPTIONS}"
    say "请把复杂 SSH 选项放进 ~/.ssh/config 的 Host 别名里，然后重新运行并输入该别名。"
  else
    err "Unsupported raw ssh option(s):${V_UNSUPPORTED_SSH_OPTIONS}"
    say "Put complex SSH options in ~/.ssh/config as a Host alias, then rerun and enter that alias."
  fi
  exit 2
}
[ -n "$V_HOST" ] || { if is_zh; then err "无法从 SSH 目标中解析 host。"; else err "Could not parse a host from the SSH target."; fi; exit 2; }
[ -z "$V_HOST" ] || safe_ssh_token "$V_HOST" || { if is_zh; then err "SSH host token 不安全：$V_HOST"; else err "Unsafe SSH host token: $V_HOST"; fi; exit 2; }
[ -z "${V_USER:-}" ] || safe_ssh_token "$V_USER" || { if is_zh; then err "SSH user token 不安全：$V_USER"; else err "Unsafe SSH user token: $V_USER"; fi; exit 2; }

if [ -z "$NAMESPACE" ]; then
  NAMESPACE="${RH_NAMESPACE:-rlocal}"
fi
NAMESPACE="$(sanitize_namespace "$NAMESPACE")"
BOX_ALIAS="$NAMESPACE"

cached_project="$(cache_get LAST_PROJECT_DIR)"
if [ -n "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(choose_project_dir "$PROJECT_DIR" 0)"
elif [ -n "$cached_project" ] && [ -d "$(expand_project_dir "$cached_project")" ]; then
  PROJECT_DIR="$(choose_project_dir "$cached_project" 1)"
else
  PROJECT_DIR="$(choose_project_dir "$PWD" 1)"
fi

if [ -z "$REMOTE_MP" ]; then
  # A remembered mountpoint belongs to the project it was chosen for; any other project (or a cache
  # written before that was recorded) defaults to auto, shown with the name it will actually use.
  cached_mp=""
  if [ "$(cache_get LAST_MOUNT_PROJECT)" = "$PROJECT_DIR" ]; then cached_mp="$(cache_get LAST_REMOTE_MOUNTPOINT)"; fi
  auto_mp="~/.remote-harness/mounts/$(basename "$PROJECT_DIR")"
  if [ -n "$cached_mp" ]; then mp_hint="$(tr2 auto auto)"; else mp_hint="$(tr2 blank 留空)"; fi
  REMOTE_MP="$(prompt_line "$(tr2 "Remote mountpoint ($mp_hint = remote $auto_mp)" "远端挂载点（${mp_hint} = 远端 ${auto_mp}）")" "$cached_mp" 0)"
fi
REMOTE_MP="${REMOTE_MP%/}"
case "$REMOTE_MP" in auto|AUTO|-) REMOTE_MP="";; esac

# An explicit --approval/--yolo is final; otherwise ask, defaulting to the last choice or auto.
if [ -z "$APPROVAL" ]; then
  APPROVAL="$(cache_get LAST_APPROVAL)"
  case "$APPROVAL" in normal|auto|yolo) ;; *) APPROVAL=auto;; esac
  if [ "$ASSUME_YES" != 1 ]; then
    say "$(tr2 "Approval mode for ${LAUNCH}:" "${LAUNCH} 的审批模式：")"
    say "  1) auto   $(tr2 "the agent reviews approvals automatically (recommended)" "由 Agent 自动审核审批请求（推荐）")"
    say "  2) normal $(tr2 "the agent asks you before risky actions" "高风险操作前逐项询问你")"
    say "  3) yolo   $(tr2 "bypass all approvals" "跳过所有审批")"
    while :; do
      _approval="$(prompt_line "$(tr2 "Choose 1-3 or a name" "输入 1-3 或模式名")" "$APPROVAL")"
      case "$_approval" in
        1|auto) APPROVAL=auto; break;;
        2|normal) APPROVAL=normal; break;;
        3|yolo|YOLO) APPROVAL=yolo; break;;
        *) warn "$(tr2 "Please answer 1, 2 or 3." "请输入 1、2 或 3。")";;
      esac
    done
  fi
fi

# Which SSH server the reverse tunnel reaches here. An explicit choice (flag, RH_LOCAL_SSHD or the
# answer below) is remembered; auto stays the system sshd unless it looks like it cannot work.
if [ "$LOCAL_SSHD" = auto ]; then
  cached_sshd="$(cache_get LAST_LOCAL_SSHD)"
  case "$cached_sshd" in
    system|user) LOCAL_SSHD="$cached_sshd";;
    *)
      if sshd_hint="$(local_sshd_user_mode_hint)"; then
        case "$sshd_hint" in
          no-sshd) warn "$(tr2 "No SSH server is listening on :22 on this machine." "本机 :22 上没有 SSH 服务在监听。")";;
          *) warn "$(tr2 "This machine's sshd looks up keys outside ~/.ssh/authorized_keys (e.g. FreeIPA/sssd)." "本机 sshd 从 ~/.ssh/authorized_keys 之外查找公钥（例如 FreeIPA/sssd）。")";;
        esac
        say "  $(tr2 "A per-session sshd run as you on a free loopback port needs no root and no ~/.ssh change." "可改用以你自己身份运行、只监听回环空闲端口的会话级 sshd：不需要 root，也不修改 ~/.ssh。")"
        if prompt_yes_no "$(tr2 "Use the per-session user-mode sshd?" "使用会话级用户态 sshd？")" y; then
          LOCAL_SSHD=user
        else
          LOCAL_SSHD=system
        fi
      fi
      ;;
  esac
fi

if is_zh; then
  hdr "执行计划"
  say "远端机器：       ${VIA}"
  say "本次远端别名：   ${BOX_ALIAS}（会话临时配置）"
  say "本地项目：       ${PROJECT_DIR}"
else
  hdr "Plan"
  say "Remote box:       ${VIA}"
  say "Remote alias:     ${BOX_ALIAS} (session-local config)"
  say "Local project:    ${PROJECT_DIR}"
fi
if [ -n "$REMOTE_MP" ]; then
  if is_zh; then say "远端挂载点：     ${REMOTE_MP}"; else say "Remote mountpoint: ${REMOTE_MP}"; fi
else
  if is_zh; then say "远端挂载点：     远端 ~/.remote-harness/mounts/$(basename "$PROJECT_DIR")"; else say "Remote mountpoint: remote ~/.remote-harness/mounts/$(basename "$PROJECT_DIR")"; fi
fi
if is_zh; then say "启动命令：       ${LAUNCH}（审批模式 ${APPROVAL}）"; else say "Launch:           ${LAUNCH} (approval: ${APPROVAL})"; fi
if [ "$LOCAL_SSHD" = user ]; then
  say "$(tr2 "Local SSH server: per-session user-mode sshd (RH_LOCAL_SSHD=system switches back)" "本机 SSH 服务：   会话级用户态 sshd（RH_LOCAL_SSHD=system 可改回）")"
else
  say "$(tr2 "Local SSH server: system sshd on :22 (RH_LOCAL_SSHD=user for FreeIPA-style hosts)" "本机 SSH 服务：   系统 sshd（:22；FreeIPA 这类主机用 RH_LOCAL_SSHD=user）")"
fi
if is_zh; then
  prompt_yes_no "继续执行这个设置？" y
else
  prompt_yes_no "Continue with this setup?" y
fi
if [ "$?" -ne 0 ]; then
  if is_zh; then err "已取消。"; else err "Aborted."; fi
  exit 1
fi
cache_save

# This step, then laptop-setup.sh's RH_LAPTOP_STEPS (the counter continues across exec).
step_reset $((RH_LAPTOP_STEPS + 1))
trap '[ -z "$STEP_LABEL" ] || step_end fail' EXIT
sep
step_begin "$(tr2 "Preparing remote tunnel alias" "准备远端临时隧道别名")"
LAPTOP_USER="$(id -un 2>/dev/null || echo user)"
setup_out="$(
  # shellcheck disable=SC2086 # intentional ssh-arg word splitting; never evaluated.
  ssh -n -o ClearAllForwardings=yes \
    -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o CheckHostIP=no \
    -o ControlMaster=no -o ControlPath=none \
    -o BatchMode=yes -o ConnectTimeout=10 $VIA "
    rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"
    parent=\"\$rh/.sessions\"
    mkdir -p \"\$parent\" 2>/dev/null || exit 1
    sd=\$(mktemp -d \"\$parent/simple.XXXXXX\") || exit 1
    cfg=\"\$sd/ssh_config\"
    [ -x \"\$rh/scripts/setup-tunnel.sh\" ] || { printf 'ERROR=missing setup-tunnel.sh\n'; exit 2; }
    \"\$rh/scripts/setup-tunnel.sh\" --config \"\$cfg\" --alias $(sq "$BOX_ALIAS") --namespace $(sq "$NAMESPACE") --user $(sq "$LAPTOP_USER") --gen-key
  " 2>&1
)"
setup_rc=$?
if [ "$setup_rc" -ne 0 ]; then
  step_end fail
  err "Remote setup-tunnel.sh failed."
  printf '%s\n' "$setup_out" >&2
  exit "$setup_rc"
fi

PORT="$(printf '%s\n' "$setup_out" | kv_value PORT)"
PUBKEY="$(printf '%s\n' "$setup_out" | kv_value PUBKEY)"
ALIAS="$(printf '%s\n' "$setup_out" | kv_value ALIAS)"
BOX_SSH_CONFIG="$(printf '%s\n' "$setup_out" | kv_value CONFIG)"
[ -n "$PORT" ] || { err "Remote setup did not return PORT."; printf '%s\n' "$setup_out" >&2; exit 1; }
[ -n "$BOX_SSH_CONFIG" ] || { err "Remote setup did not return CONFIG."; printf '%s\n' "$setup_out" >&2; exit 1; }
[ -n "$ALIAS" ] || ALIAS="$BOX_ALIAS"
step_end ok "$(tr2 "Remote alias '$ALIAS' prepared on port $PORT" "远端临时别名 '$ALIAS' 已准备好，端口 $PORT")"

cmd=(bash "$SCRIPT_DIR/laptop-setup.sh"
  --host "$V_HOST"
  --port "$PORT"
  --via "$VIA"
  --box-alias "$BOX_ALIAS"
  --box-ssh-config "$BOX_SSH_CONFIG"
  --project-dir "$PROJECT_DIR"
  --launch "$LAUNCH")
[ -n "$PUBKEY" ] && cmd+=(--pubkey "$PUBKEY")
[ -n "$REMOTE_MP" ] && cmd+=(--remote-mountpoint "$REMOTE_MP")
cmd+=(--approval "$APPROVAL")
cmd+=(--local-sshd "$LOCAL_SSHD")

export RH_STEP_BASE="$STEP_N"
step_reset 0
trap - EXIT
exec "${cmd[@]}"
