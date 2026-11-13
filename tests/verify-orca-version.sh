#!/usr/bin/env bash
# Check an Orca Server build against Harness before adding it to ORCA_VERSIONS in
# scripts/orca_native.py. Pass an orcad bundle directory (as the Orca desktop pushes it to
# ~/.orca-remote) or an Orca CLI that can serve. With a previous build as well, the restart tests
# switch from it to the new one, as an automatic update does. Set RH_TEST_CODEX_CLI to the pinned
# codex executable to include native Codex chats. Servers use throwaway profiles; tests run one
# at a time.
#
# usage: tests/verify-orca-version.sh <new-bundle-or-cli> [<previous-bundle-or-cli>]
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  sed -n '2,9p' "$0" | cut -c3-
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rh-verify-orca.XXXXXX")
trap 'rm -rf "$work"' EXIT

cli_for() {
  if [ -d "$1" ]; then
    python3 "$here/fixtures/orca_bundle.py" "$1" "$work/$2"
  elif [ -f "$1" ] && [ -x "$1" ]; then
    printf '%s\n' "$1"
  else
    echo "verify-orca-version: $1 is neither an orcad bundle directory nor an executable Orca CLI" >&2
    exit 2
  fi
}

new=$(cli_for "$1" new)
version=$("$new" --version)
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "verify-orca-version: unexpected Orca version output: $version" >&2; exit 2 ;;
esac
previous=""
[ "$#" -lt 2 ] || previous=$(cli_for "$2" previous)

# The bridge refuses builds outside its list, so test a copy of the scripts that lists this one.
cp -R "$here/../scripts" "$work/scripts"
python3 - "$work/scripts/orca_native.py" "$version" <<'PY'
import ast, re, sys
path, version = sys.argv[1:]
text = open(path, encoding="utf8").read()
listed = re.search(r"^ORCA_VERSIONS = (\(.*\))$", text, re.M)
if not listed:
    sys.exit("verify-orca-version: ORCA_VERSIONS not found")
versions = ast.literal_eval(listed.group(1))
if version not in versions:
    text = text.replace(listed.group(0), f"ORCA_VERSIONS = {versions + (version,)!r}")
open(path, "w", encoding="utf8").write(text)
PY
export RH_TEST_SCRIPTS="$work/scripts"
cd "$here"

run() {
  printf '\n== %s\n' "$1"
  shift
  "$@"
}

run "Claude through Orca $version" \
  env RH_TEST_ORCA_CLI="$new" python3 test_orca_live.py -v
if [ -n "$previous" ]; then
  run "Claude across an update to Orca $version" \
    env RH_TEST_ORCA_CLI="$previous" RH_TEST_ORCA_AFTER="$new" \
    python3 test_orca_live.py -v OrcaLiveTests.test_orca_claude_chat_survives_server_restart
fi
if [ -n "${RH_TEST_CODEX_CLI:-}" ]; then
  run "native Codex through Orca $version" \
    env RH_TEST_ORCA_CLI="$new" python3 test_native_codex_managers.py -v \
    NativeCodexManagerTests.test_orca_approves_child_command_and_applies_child_edit \
    NativeCodexManagerTests.test_orca_revokes_lease_with_child_approval_pending \
    NativeCodexManagerTests.test_orca_codex_chat_survives_server_restart
  if [ -n "$previous" ]; then
    run "native Codex across an update to Orca $version" \
      env RH_TEST_ORCA_CLI="$previous" RH_TEST_ORCA_AFTER="$new" python3 test_native_codex_managers.py -v \
      NativeCodexManagerTests.test_orca_codex_chat_survives_server_restart
  fi
else
  printf '\nSkipped native Codex chats: set RH_TEST_CODEX_CLI to include them.\n'
fi
printf '\nOrca Server %s passed. Add "%s" to ORCA_VERSIONS in scripts/orca_native.py.\n' "$version" "$version"
