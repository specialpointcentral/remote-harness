#!/usr/bin/env bash
# remote-harness / suggest-via.sh - run ON THE REMOTE BOX.
#
# Suggest a default SSH target for the laptop-side bootstrap command. This uses
# only server-side facts. When SSH_CONNECTION exists, its format is:
#   <client-ip> <client-port> <server-ip> <server-port>
# The first two fields describe the user's local/client side and must never be
# emitted.
set -uo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

unavailable() {
  emit STATUS unavailable
  emit VIA ""
  emit REASON "${1:-unknown}"
  exit 0
}

safe_token() {
  case "${1:-}" in
    ""|-*|*[[:space:]\"\'\\]*) return 1;;
    *) return 0;;
  esac
}

valid_port() {
  case "${1:-}" in
    ""|*[!0-9]*) return 1;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

is_bad_host() {
  case "${1:-}" in
    ""|0.0.0.0|127.*|localhost|::|::1|\[::1\]) return 0;;
    *[[:space:]\"\'\\]*) return 0;;
    *) return 1;;
  esac
}

is_ipv4() {
  case "${1:-}" in
    *.*.*.*) ;;
    *) return 1;;
  esac
  OLDIFS=$IFS
  IFS=.
  # shellcheck disable=SC2086 # intentional split on dots.
  set -- $1
  IFS=$OLDIFS
  [ "$#" -eq 4 ] || return 1
  for oct in "$@"; do
    case "$oct" in ""|*[!0-9]*) return 1;; esac
    [ "$oct" -ge 0 ] 2>/dev/null && [ "$oct" -le 255 ] 2>/dev/null || return 1
  done
}

is_private_v4() {
  is_ipv4 "$1" || return 1
  OLDIFS=$IFS
  IFS=.
  # shellcheck disable=SC2086 # intentional split on dots.
  set -- $1
  IFS=$OLDIFS
  case "$1" in
    10|127|169) return 0;;
    192) [ "${2:-}" = 168 ] && return 0;;
    172) [ "${2:-0}" -ge 16 ] 2>/dev/null && [ "${2:-0}" -le 31 ] 2>/dev/null && return 0;;
  esac
  return 1
}

format_host() {
  case "$1" in
    \[*\]) printf '%s' "$1";;
    *:*) printf '[%s]' "$1";;
    *) printf '%s' "$1";;
  esac
}

candidate_hosts() {
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n'
    hostname -f 2>/dev/null || true
    hostname 2>/dev/null || true
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | sed 's#/.*##'
    ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | sed 's#/.*##'
  fi
}

pick_host() {  # first public IPv4, else the first usable candidate
  _all="$(candidate_hosts | sed '/^$/d')"
  for _h in $_all; do
    is_bad_host "$_h" && continue
    is_ipv4 "$_h" && ! is_private_v4 "$_h" && { printf '%s' "$_h"; return 0; }
  done
  for _h in $_all; do
    is_bad_host "$_h" && continue
    printf '%s' "$_h"
    return 0
  done
  return 1
}

user="$(id -un 2>/dev/null || whoami 2>/dev/null || true)"
safe_token "$user" || unavailable unsafe_user

host=""
port="22"
source="fallback"

if [ -n "${SSH_CONNECTION:-}" ]; then
  # Use only fields 3 and 4. Fields 1 and 2 are client/local-side data.
  # shellcheck disable=SC2086 # intentional whitespace split of OpenSSH metadata.
  set -- $SSH_CONNECTION
  if [ "$#" -ge 4 ]; then
    if ! is_bad_host "$3"; then
      host="$3"
      source="ssh_connection"
    fi
    valid_port "$4" && port="$4"
  fi
fi

if [ -z "$host" ]; then
  host="$(pick_host || true)"
  [ -n "$host" ] || unavailable no_server_address
fi

# Defense in depth: re-check whatever source produced the host before it is emitted.
is_bad_host "$host" && unavailable unsafe_host
valid_port "$port" || unavailable unsafe_port

target="${user}@$(format_host "$host")"
if [ "$port" = 22 ]; then
  via="$target"
else
  via="-p $port $target"
fi

emit STATUS ok
emit VIA "$via"
emit SOURCE "$source"
