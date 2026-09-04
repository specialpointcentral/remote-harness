#!/usr/bin/env bash
# remote-harness / simple-bootstrap.sh - run ON THE LOCAL MACHINE.
#
# Unified simple bootstrap. If it is run from a local remote-harness install, it
# delegates to simple-dispatch.sh directly. If it is run from stdin after being
# fetched from a remote skill install, it fetches the local-side helper scripts
# into a temp dir and then delegates to simple-dispatch.sh there.
set -uo pipefail
set -f

LANG_MODE="${RH_LANG:-en}"
is_zh() {
  case "$LANG_MODE" in zh|zh_*|zh-*|cn|CN|中文) return 0;; *) return 1;; esac
}

need_arg() {
  if [ -z "${2+x}" ] || [ -z "$2" ]; then
    printf 'missing value for %s\n' "$1" >&2
    exit 2
  fi
}

prompt_tty() {
  _p="$1"
  _v=""
  if [ -e /dev/tty ]; then
    printf '%s' "$_p" >/dev/tty
    IFS= read -r _v </dev/tty || true
  else
    printf '%s' "$_p" >&2
    IFS= read -r _v || true
  fi
  printf '%s' "$_v"
}

trim_via() {
  _v="$1"
  # Trim leading/trailing whitespace and allow users to paste either
  # "ssh -p 2222 user@host" or just "-p 2222 user@host".
  _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_v" in
    ssh[[:space:]]*) _v="${_v#ssh }"; _v="$(printf '%s' "$_v" | sed 's/^[[:space:]]*//')";;
  esac
  printf '%s' "$_v"
}

cache_file() {
  printf '%s' "${RH_SIMPLE_CACHE:-$HOME/.remote-harness/simple-cache.env}"
}

cache_get_last_via() {
  _cache="$(cache_file)"
  [ -r "$_cache" ] || return 0
  sed -n 's/^LAST_VIA=//p' "$_cache" | tail -1
}

cache_set_last_via() {
  _cache="$(cache_file)"
  case "$VIA" in *'
'*) return 0;; esac
  mkdir -p "$(dirname "$_cache")" 2>/dev/null || true
  _tmp="$(mktemp "${_cache}.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$_cache" ]; then
    grep -v '^LAST_VIA=' "$_cache" 2>/dev/null > "$_tmp" || true
  fi
  printf 'LAST_VIA=%s\n' "$VIA" >> "$_tmp"
  mv "$_tmp" "$_cache" 2>/dev/null && chmod 600 "$_cache" 2>/dev/null || true
}

self_dir=""
case "${BASH_SOURCE[0]:-}" in
  */*) self_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir="";;
esac

VIA="${RH_VIA:-}" MODE="" LAUNCH="codex" YOLO=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)   need_arg "$1" "${2-}"; MODE="$2"; shift 2;;
    --via)    need_arg "$1" "${2-}"; VIA="$2"; shift 2;;
    --launch) need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --yolo)   YOLO=1; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in claude|codex|opencode) ;; *) printf 'unsupported --launch %s\n' "$LAUNCH" >&2; exit 2;; esac

dispatch_args=(--launch "$LAUNCH")
[ -n "$MODE" ] && dispatch_args=(--mode "$MODE" "${dispatch_args[@]}")
[ "$YOLO" = 1 ] && dispatch_args+=(--yolo)

if [ -n "$self_dir" ] && [ -f "$self_dir/simple-dispatch.sh" ]; then
  [ -n "$VIA" ] && dispatch_args+=(--source-via "$VIA")
  exec bash "$self_dir/simple-dispatch.sh" "${dispatch_args[@]}"
fi

if [ -z "$VIA" ]; then
  cached_via="$(cache_get_last_via)"
  default_via="${cached_via:-${RH_DEFAULT_VIA:-}}"
  if is_zh; then
    if [ -n "$default_via" ]; then
      VIA="$(prompt_tty "remote-harness 来源 SSH 目标/参数（不要带开头的 ssh；推荐 Host 别名） [$default_via]: ")"
    else
      VIA="$(prompt_tty 'remote-harness 来源 SSH 目标/参数（不要带开头的 ssh；推荐 Host 别名）：')"
    fi
  else
    if [ -n "$default_via" ]; then
      VIA="$(prompt_tty "remote-harness source SSH target/args (omit leading ssh; Host alias is best) [$default_via]: ")"
    else
      VIA="$(prompt_tty 'remote-harness source SSH target/args (omit leading ssh; Host alias is best): ')"
    fi
  fi
  [ -n "$VIA" ] || VIA="$default_via"
fi
VIA="$(trim_via "$VIA")"
[ -n "$VIA" ] || { if is_zh; then printf '已取消：未提供 SSH 目标/参数\n' >&2; else printf 'aborted: no SSH target/args provided\n' >&2; fi; exit 2; }
cache_set_last_via
dispatch_args+=(--source-via "$VIA")

mkdir -p "$HOME/.remote-harness/.sessions" 2>/dev/null || true
tmp="$(mktemp -d "$HOME/.remote-harness/.sessions/bootstrap.XXXXXX")" || exit 1
cleanup() { rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT INT TERM HUP

fetch_script() {
  _name="$1"
  # $VIA is intentionally word-split into ssh args, never eval'd. For complex
  # quoted SSH options, put them in ~/.ssh/config and enter the Host alias.
  # shellcheck disable=SC2086
  ssh -n -o ClearAllForwardings=yes \
    -o UserKnownHostsFile="$tmp/known_hosts_source" \
    -o GlobalKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=accept-new \
    -o ControlMaster=no -o ControlPath=none \
    $VIA \
    "rh=\"\${RH_HOME:-\$HOME/.remote-harness}\"; cat \"\$rh/scripts/$_name\"" \
    > "$tmp/$_name"
}

if is_zh; then
  printf '正在从远端读取 remote-harness simple 设置...\n'
else
  printf 'Fetching remote-harness simple setup from the remote source...\n'
fi
for script in \
  _common.sh \
  simple-dispatch.sh \
  simple-laptop-setup.sh \
  laptop-setup.sh \
  mount-project.sh \
  inject-rule.sh \
  run-on-project-host.sh \
  project-host-gateway.sh; do
  if ! fetch_script "$script"; then
    if is_zh; then
      printf '无法从远端 remote-harness 读取 %s\n' "$script" >&2
      printf '请检查 SSH 是否可用，以及远端是否安装了 ~/.remote-harness\n' >&2
    else
      printf 'failed to fetch %s from remote-harness on the remote source\n' "$script" >&2
      printf 'check that SSH works and ~/.remote-harness is installed there\n' >&2
    fi
    exit 1
  fi
  chmod +x "$tmp/$script" 2>/dev/null || true
done

bash "$tmp/simple-dispatch.sh" "${dispatch_args[@]}"
exit $?
