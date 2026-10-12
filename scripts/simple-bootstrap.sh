#!/usr/bin/env bash
# remote-harness / simple-bootstrap.sh - run ON THE LOCAL MACHINE.
#
# Unified simple bootstrap. If it is run from a local remote-harness install, it
# delegates to simple-dispatch.sh directly. If it is run from stdin after being
# fetched from a remote skill install, it fetches the local-side helper scripts
# into a temp dir and then delegates to simple-dispatch.sh there.
set -uo pipefail
set -f
umask 077

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

bootstrap_fail() {
  if is_zh; then printf '%s\n' "$1" >&2; else printf '%s\n' "$2" >&2; fi
  exit 1
}

if is_zh; then
  printf '正在从远端读取 remote-harness simple 设置...\n'
else
  printf 'Fetching remote-harness simple setup from the remote source...\n'
fi
helpers=(_common.sh simple-dispatch.sh simple-laptop-setup.sh laptop-setup.sh
         mount-project.sh inject-rule.sh run-on-project-host.sh project-host-gateway.sh)
bundle_files=(simple-bootstrap.sh "${helpers[@]}")
sha256_manifest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"
  else return 1
  fi
}

# Stage a fixed file set before streaming one archive. Neither shell chatter nor partial SSH
# output is executable locally. The bootstrap copy detects an install change between downloads.
remote_bundle=$(cat <<'REMOTE'
set -eu
umask 077
rh="${RH_HOME:-$HOME/.remote-harness}"
mkdir -p "$rh/.sessions"
stage=$(mktemp -d "$rh/.sessions/helpers.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
set -- simple-bootstrap.sh _common.sh simple-dispatch.sh simple-laptop-setup.sh laptop-setup.sh mount-project.sh inject-rule.sh run-on-project-host.sh project-host-gateway.sh
cd "$rh/scripts"
cp "$@" "$stage/"
cd "$stage"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" > SHA256SUMS
elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@" > SHA256SUMS
else printf 'remote-harness: SHA-256 tool required\n' >&2; exit 1
fi
tar -cf - SHA256SUMS "$@"
REMOTE
)
archive="$tmp/helpers.tar"
# $VIA is intentionally word-split into SSH args, never evaluated. Keep the user's HostKeyAlias
# and known-hosts configuration; strict checking plus disabled updates avoids changing ~/.ssh.
# shellcheck disable=SC2086
if ! ssh -n -o ClearAllForwardings=yes \
    -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o CheckHostIP=no \
    -o ControlMaster=no -o ControlPath=none \
    $VIA "$remote_bundle" > "$archive"; then
  bootstrap_fail '无法下载 helper 包；请检查 SSH 和已验证的主机身份配置。' \
    'failed to download helper bundle; check SSH and the verified host identity configuration'
fi

# Check names, duplicates and entry types before extracting anything. Only flat regular files
# from the fixed list are allowed; the manifest is compared with locally computed hashes rather
# than interpreted as a list of arbitrary paths to read.
printf '%s\n' SHA256SUMS "${bundle_files[@]}" | LC_ALL=C sort > "$tmp/expected-files"
if ! tar -tf "$archive" > "$tmp/archive-files" \
    || ! LC_ALL=C sort "$tmp/archive-files" > "$tmp/sorted-files" \
    || ! cmp -s "$tmp/expected-files" "$tmp/sorted-files" \
    || ! tar -tvf "$archive" | awk 'substr($0,1,1) != "-" {bad=1} END {exit bad}'; then
  bootstrap_fail 'helper 包文件清单或类型无效。' 'invalid helper bundle file list or entry type'
fi
unpack="$tmp/helpers"
mkdir "$unpack" || exit 1
if ! tar -xf "$archive" -C "$unpack" \
    || ! (cd "$unpack" && sha256_manifest "${bundle_files[@]}") > "$tmp/computed-sha256" \
    || ! cmp -s "$unpack/SHA256SUMS" "$tmp/computed-sha256"; then
  bootstrap_fail 'helper 包解包或 SHA-256 校验失败。' 'helper bundle extraction or SHA-256 verification failed'
fi
if [ -f "${BASH_SOURCE[0]}" ] && ! cmp -s "${BASH_SOURCE[0]}" "$unpack/simple-bootstrap.sh"; then
  bootstrap_fail '远端 bootstrap 在下载期间发生变化，请重新启动。' \
    'remote bootstrap changed between downloads; restart the bootstrap'
fi
for script in "${bundle_files[@]}"; do
  if ! bash -n "$unpack/$script"; then
    bootstrap_fail 'helper 包包含无效的 Bash 脚本。' 'helper bundle contains invalid Bash syntax'
  fi
  chmod +x "$unpack/$script" || exit 1
done

bash "$unpack/simple-dispatch.sh" "${dispatch_args[@]}"
exit $?
