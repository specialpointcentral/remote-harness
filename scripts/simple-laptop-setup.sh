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

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RH_COMMON="${RH_COMMON:-$SCRIPT_DIR/_common.sh}"
if [ -f "$RH_COMMON" ]; then
  # shellcheck source=./_common.sh
  . "$RH_COMMON"
else
  printf 'error: missing _common.sh next to %s\n' "$0" >&2
  exit 2
fi

LANG_MODE="${RH_LANG:-en}"
is_zh() {
  case "$LANG_MODE" in zh|zh_*|zh-*|cn|CN|中文) return 0;; *) return 1;; esac
}

prompt_line() {
  _label="$1"
  _default="${2:-}"
  _required="${3:-0}"
  _answer=""
  while :; do
    if [ -n "$_default" ]; then
      printf '%s [%s]: ' "$_label" "$_default" >/dev/tty
    else
      printf '%s: ' "$_label" >/dev/tty
    fi
    if [ -r /dev/tty ]; then
      IFS= read -r _answer </dev/tty || _answer=""
    else
      IFS= read -r _answer || _answer=""
    fi
    [ -n "$_answer" ] || _answer="$_default"
    if [ "$_required" != 1 ] || [ -n "$_answer" ]; then
      printf '%s' "$_answer"
      return 0
    fi
    if is_zh; then warn "该值必填。"; else warn "This value is required."; fi
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
      *) if is_zh; then warn "请输入 y 或 n。"; else warn "Please answer y or n."; fi;;
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

expand_project_dir() {
  _v="$1"
  case "$_v" in
    "~") _v="$HOME";;
    "~/"*) _v="$HOME/${_v#~/}";;
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
        _candidate="$(prompt_line '本地项目目录' "$_default" 1)"
      else
        _candidate="$(prompt_line 'Local project directory' "$_default" 1)"
      fi
      _prompt=0
    fi
    _candidate="$(expand_project_dir "$_candidate")"
    if [ -d "$_candidate" ]; then
      (cd "$_candidate" 2>/dev/null && pwd -P) || printf '%s' "$_candidate"
      return 0
    fi
    if is_zh; then warn "项目目录不存在：$_candidate"; else warn "Project directory does not exist: $_candidate"; fi
    _candidate=""
  done
}

kv_value() {
  _key="$1"
  sed -n "s/^${_key}=//p" | head -1
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
    grep -v -E '^(LAST_VIA|LAST_PROJECT_DIR|LAST_REMOTE_MOUNTPOINT|LAST_LAUNCH|LAST_YOLO)=' "$_cache" 2>/dev/null > "$_tmp" || true
  fi
  for _kv in \
    "LAST_VIA=$VIA" \
    "LAST_PROJECT_DIR=$PROJECT_DIR" \
    "LAST_REMOTE_MOUNTPOINT=$REMOTE_MP" \
    "LAST_LAUNCH=$LAUNCH" \
    "LAST_YOLO=$YOLO"; do
    case "$_kv" in *'
'*) continue;; esac
    printf '%s\n' "$_kv" >> "$_tmp"
  done
  mv "$_tmp" "$_cache" 2>/dev/null && chmod 600 "$_cache" 2>/dev/null || true
}

VIA="" LAUNCH="codex" YOLO=0 YOLO_REQUESTED=0
NAMESPACE="" PROJECT_DIR="" REMOTE_MP="" ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --via)               need_arg "$1" "${2-}"; VIA="$2"; shift 2;;
    --launch)            need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --yolo)              YOLO=1; YOLO_REQUESTED=1; shift;;
    --namespace)         need_arg "$1" "${2-}"; NAMESPACE="$2"; shift 2;;
    --project-dir)       need_arg "$1" "${2-}"; PROJECT_DIR="$2"; shift 2;;
    --remote-mountpoint) need_arg "$1" "${2-}"; REMOTE_MP="$2"; shift 2;;
    --yes|-y)            ASSUME_YES=1; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
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
  cached_mp="$(cache_get LAST_REMOTE_MOUNTPOINT)"
  if [ -n "$cached_mp" ]; then
    if is_zh; then
      REMOTE_MP="$(prompt_line '远端挂载点（auto = 远端 ~/.remote-harness/mounts/<project>）' "$cached_mp" 0)"
    else
      REMOTE_MP="$(prompt_line 'Remote mountpoint (auto = remote ~/.remote-harness/mounts/<project>)' "$cached_mp" 0)"
    fi
  else
    if is_zh; then
      REMOTE_MP="$(prompt_line '远端挂载点（留空 = 远端 ~/.remote-harness/mounts/<project>）' '' 0)"
    else
      REMOTE_MP="$(prompt_line 'Remote mountpoint (blank = remote ~/.remote-harness/mounts/<project>)' '' 0)"
    fi
  fi
fi
REMOTE_MP="${REMOTE_MP%/}"
case "$REMOTE_MP" in auto|AUTO|-) REMOTE_MP="";; esac

if [ "$YOLO_REQUESTED" = 1 ]; then
  YOLO=1
else
  cached_yolo="$(cache_get LAST_YOLO)"
  if [ "$cached_yolo" = 0 ]; then
    default_yolo=n
  else
    default_yolo=y
  fi
  if is_zh; then
    if prompt_yes_no "启动 ${LAUNCH} 时开启 YOLO/免审批模式？" "$default_yolo"; then YOLO=1; else YOLO=0; fi
  else
    if prompt_yes_no "Launch ${LAUNCH} with YOLO/bypass approvals?" "$default_yolo"; then YOLO=1; else YOLO=0; fi
  fi
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
if [ "$YOLO" = 1 ]; then
  if is_zh; then say "启动命令：       ${LAUNCH} --yolo"; else say "Launch:           ${LAUNCH} --yolo"; fi
else
  if is_zh; then say "启动命令：       ${LAUNCH}"; else say "Launch:           ${LAUNCH}"; fi
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

if is_zh; then hdr "准备远端临时隧道别名"; else hdr "Preparing remote tunnel alias"; fi
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
if is_zh; then
  ok "远端临时别名 '$ALIAS' 已准备好，端口 $PORT"
else
  ok "Remote alias '$ALIAS' prepared on port $PORT"
fi

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
[ "$YOLO" = 1 ] && cmd+=(--yolo)

sep
if is_zh; then
  say "交给 laptop-setup.sh 继续处理 SSH server、隧道、挂载、规则注入和启动。"
else
  say "Handing off to laptop-setup.sh for SSH server, tunnel, mount, rule injection, and launch."
fi
exec "${cmd[@]}"
