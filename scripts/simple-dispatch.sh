#!/usr/bin/env bash
# remote-harness / simple-dispatch.sh - run ON THE LOCAL MACHINE.
#
# Remote-only local dispatcher. The coding agent always runs on the remote box;
# this script only hands off to the reverse local wizard.
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

normalize_mode() {
  _m="$(printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$_m" in
    ""|1|r|R|reverse|Reverse|REV|远程开发本地|远程开发本地项目|远端开发本地|远端开发本地项目)
      printf 'reverse'; return 0;;
    2|f|F|forward|Forward|FWD|本地开发远程|本地开发远程项目|本地开发服务器项目|本地开发远端项目)
      printf 'forward'; return 0;;
    *) return 1;;
  esac
}

MODE="" SOURCE_VIA="" LAUNCH="codex" APPROVAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)       need_arg "$1" "${2-}"; MODE="$2"; shift 2;;
    --source-via) need_arg "$1" "${2-}"; SOURCE_VIA="$2"; shift 2;;
    --launch)     need_arg "$1" "${2-}"; LAUNCH="$2"; shift 2;;
    --approval)   need_arg "$1" "${2-}"; APPROVAL="$2"; shift 2;;
    --yolo)       APPROVAL=yolo; shift;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2;;
  esac
done
case "$LAUNCH" in
  claude|codex|opencode) ;;
  *) printf 'unsupported --launch %s (expected claude|codex|opencode)\n' "$LAUNCH" >&2; exit 2;;
esac

if [ -n "$MODE" ]; then
  MODE="$(normalize_mode "$MODE")" || { printf 'unsupported --mode %s\n' "$MODE" >&2; exit 2; }
else
  MODE=reverse
fi
[ "$MODE" = reverse ] || {
  err "$(tr2 "remote-only mode cannot launch an agent locally; use reverse." "remote-only 模式不允许在本机启动 Agent；请使用 reverse。")"
  exit 2
}

[ -x "$SCRIPT_DIR/simple-laptop-setup.sh" ] || { err "missing simple-laptop-setup.sh in $SCRIPT_DIR"; exit 2; }
args=(--launch "$LAUNCH")
[ -n "$SOURCE_VIA" ] && args+=(--via "$SOURCE_VIA")
[ -n "$APPROVAL" ] && args+=(--approval "$APPROVAL")
exec bash "$SCRIPT_DIR/simple-laptop-setup.sh" "${args[@]}"
