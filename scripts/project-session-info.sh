#!/usr/bin/env bash
# Project-owned presentation adapter. No Python, eval/source, gateway verb, or generic output filter.
set -euo pipefail
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/_common.sh"
fail() { printf 'remote-harness: session presentation unavailable: %s\n' "$1" >&2; exit 125; }
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else fail 'SHA-256 tool required'; fi
}
private_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && \
    [ "$(find "$1" -prune -type d -perm 700 -print)" = "$1" ] || fail 'unsafe directory'
}
private_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && \
    [ "$(find "$1" -prune -type f -perm 600 -print)" = "$1" ] || fail 'unsafe file'
  [ "$(wc -c < "$1")" -le 16384 ] || fail 'oversized file'
}
decode() { printf '%s' "$1" | { base64 --decode 2>/dev/null || base64 -D; }; }
validate_records() {
  # Ordered allowlist rejects duplicates, unknown fields, shell syntax and malformed values.
  LC_ALL=C awk "$(effective_timezone_awk)"'
  BEGIN { split("HOSTNAME IPV4 IPV6 MACHINE_ID TIMEZONE EFFECTIVE_TZ EFFECTIVE_TZDIR COUNTRY REGION", keys, " ") }
  {
    key=substr($0,1,index($0,"=")-1); value=substr($0,index($0,"=")+1)
    if (NR>9 || key!=keys[NR] || length(value)>255) exit 1
    if (key=="IPV4" && value!="") {
      n=split(value,ip,"."); if(n!=4) exit 1
      for(i=1;i<=4;i++) if(ip[i]!~/^[0-9]+$/ || ip[i]>255) exit 1
    } else if (key=="IPV6" && value!="" && (value!~/^[0-9A-Fa-f:]+$/ || value!~/:/)) exit 1
    else if (key=="MACHINE_ID" && value!~/^[0-9A-Fa-f-]*$/) exit 1
    else if (key=="TIMEZONE" && value!~/^[A-Za-z0-9_+\/-]*$/) exit 1
    else if (key=="EFFECTIVE_TZ" && !valid_effective_timezone(value)) exit 1
    else if (key=="EFFECTIVE_TZDIR" && value!~/^[A-Za-z0-9_+\/:,.-]*$/) exit 1
    else if (key=="COUNTRY" && value!="" && value!~/^[A-Z][A-Z]$/) exit 1
    else if ((key=="HOSTNAME" || key=="REGION") && value!~/^[A-Za-z0-9._-]*$/) exit 1
  }
  END { if(NR!=9) exit 1 }'
}
validate_table() {
  private_file "$1"
  [ "$(sed -n '1p' "$1")" = VERSION=3 ] && \
    [ "$(sed -n '2p' "$1")" = TARGET_SOURCE=agent_center ] && \
    [ "$(sed -n '3p' "$1")" = EXECUTION_OWNER=project_host ] || fail 'unsupported table'
  [ "$(wc -l < "$1")" -eq 24 ] || fail 'invalid table length'
  sed -n '4,6p' "$1" | LC_ALL=C awk '
    BEGIN { split("CENTER_DIGEST LOGICAL_DIGEST REGISTRATION_DIGEST",k," ") }
    { if(index($0,k[NR] "=")!=1) exit 1; v=substr($0,index($0,"=")+1); if(length(v)!=64 || v~/[^0-9a-f]/) exit 1 }
    END { if(NR!=3) exit 1 }' || fail 'invalid binding'
  sed -n '7,15p' "$1" | sed 's/^SOURCE_//' | validate_records || fail 'invalid source records'
  sed -n '16,24p' "$1" | sed 's/^TARGET_//' | validate_records || fail 'invalid target records'
  [ "$(sed -n '16,24p' "$1" | sed 's/^TARGET_//' | digest)" = "$(sed -n '4s/^CENTER_DIGEST=//p' "$1")" ] || fail 'profile digest mismatch'
}
case "${1:-}" in
  prepare)
    [ "$#" -eq 6 ] || fail 'prepare arguments'
    # args: gateway-dir, persistent-base, project-root, logical-id, center-profile-b64.
    gateway=$2 base=$3 root=$4 logical=$5 encoded=$6
    case "$base/" in "$root/"*) fail 'presentation storage must be outside the project';; esac
    case "$logical" in ""|*[!A-Za-z0-9-]*) fail 'invalid logical identity';; esac
    private_dir "$gateway"
    [ ! -L "$base" ] || fail 'symlink storage'
    if [ ! -e "$base" ]; then mkdir -m 700 "$base" || [ -d "$base" ]; fi
    private_dir "$base"
    profile=$(decode "$encoded") || fail 'profile encoding'
    # Bash command substitution drops NUL and trailing newlines. Require the exact canonical
    # record bytes, so malformed control bytes cannot disappear before the syntax validator.
    [ "$(printf '%s\n' "$profile" | base64 | tr -d '\n')" = "$encoded" ] || fail 'noncanonical profile encoding'
    printf '%s\n' "$profile" | validate_records || fail 'center profile'
    center=$(printf '%s\n' "$profile" | digest)
    registration=$(printf '%s' "$root" | digest)
    identity=$(printf '%s\n%s' "$registration" "$logical" | digest)
    store="$base/$identity"
    if [ ! -e "$store" ]; then mkdir -m 700 "$store" 2>/dev/null || [ -d "$store" ]; fi
    private_dir "$store"
    table="$store/table"
    if [ ! -e "$table" ] && [ ! -L "$table" ]; then
      work=$(mktemp "$store/.table.XXXXXX") || fail 'temporary table'
      trap 'rm -f "$work"' EXIT
      {
        printf 'VERSION=3\nTARGET_SOURCE=agent_center\nEXECUTION_OWNER=project_host\nCENTER_DIGEST=%s\nLOGICAL_DIGEST=%s\nREGISTRATION_DIGEST=%s\n' "$center" "$identity" "$registration"
        host_profile_records | sed 's/^/SOURCE_/'
        printf '%s\n' "$profile" | sed 's/^/TARGET_/'
      } > "$work"
      chmod 600 "$work"
      validate_table "$work"
      ln "$work" "$table" 2>/dev/null || [ -f "$table" ] || fail 'atomic table creation'
      rm -f "$work"
      trap - EXIT
    fi
    validate_table "$table"
    [ "$(sed -n '4p' "$table")" = "CENTER_DIGEST=$center" ] && \
      [ "$(sed -n '5p' "$table")" = "LOGICAL_DIGEST=$identity" ] && \
      [ "$(sed -n '6p' "$table")" = "REGISTRATION_DIGEST=$registration" ] || fail 'binding changed; start a new logical session'
    table_digest=$(digest < "$table")
    # Freeze a command wrapper, never copy the source/target table to the center.
    shim="$gateway/session-info"
    work=$(mktemp "$gateway/.session-info.XXXXXX")
    trap 'rm -f "$work"' EXIT
    printf '#!/usr/bin/env bash\nexec %s view %s %s\n' "$(sq "$SCRIPT_DIR/project-session-info.sh")" "$(sq "$table")" "$(sq "$table_digest")" > "$work"
    chmod 700 "$work"
    [ ! -L "$shim" ] || fail 'unsafe shim'
    # A transport key may be reused, but its presentation identity is immutable. Publish once;
    # concurrent identical prepares converge, while a different logical session must use a new key.
    if ! ln "$work" "$shim" 2>/dev/null; then
      [ -f "$shim" ] && [ -O "$shim" ] && \
        [ "$(find "$shim" -prune -type f -perm 700 -print)" = "$shim" ] && \
        cmp -s "$work" "$shim" || fail 'gateway presentation binding changed; use a new session key'
    fi
    rm -f "$work"
    trap - EXIT
    printf '%s:%s:%s:%s\n' "$center" "$table_digest" "$identity" "$registration"
    ;;
  view)
    [ "$#" -eq 3 ] || fail 'view arguments'
    table=$2 expected=$3
    private_dir "$(dirname "$table")"
    validate_table "$table"
    [ "$(digest < "$table")" = "$expected" ] || fail 'table changed'
    # Only this adapter creates a session view. Ordinary stdout never reaches this parser.
    # First release exposes no clock records: reliable historical conversion is unavailable.
    LC_ALL=C awk '
      BEGIN { printf "{\"schema_version\":3,\"view\":\"session\",\"target_source\":\"agent_center\",\"capabilities\":{\"timestamp_conversion\":false},\"identity\":{" }
      NR>=16 {
        key=tolower(substr($0,8,index($0,"=")-8)); value=substr($0,index($0,"=")+1)
        if(count++) printf ","; printf "\"%s\":",key
        if(value=="") printf "null"; else printf "\"%s\"",value
      }
      END { print "}}" }' "$table"
    ;;
  *) fail 'unsupported operation';;
esac
