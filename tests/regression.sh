#!/usr/bin/env bash
set -euo pipefail

# Ordinary fixtures have no SSH channel. CI may give this script an already-closed pipe; only the
# explicit pipelines below should exercise channel-EOF cancellation.
exec </dev/null

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise the enabled Unix-socket paths even when macOS supplies a long private TMPDIR.
tmp="$(mktemp -d /tmp/rh-regression.XXXXXX)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"
}
assert_grep() {
  grep -F -- "$2" "$1" >/dev/null || fail "$3: missing '$2' in $1"
}
refute_grep() {
  ! grep -F -- "$2" "$1" >/dev/null || fail "$3: unexpected '$2' in $1"
}
assert_grep_e() {  # extended-regex variants
  grep -E -- "$2" "$1" >/dev/null || fail "$3: no match for /$2/ in $1"
}
refute_grep_e() {
  ! grep -E -- "$2" "$1" >/dev/null 2>&1 || fail "$3: unexpected match for /$2/ in $1"
}

. "$ROOT/scripts/_common.sh"

# --- strict command routing: hook rewrite + project-host dispatch -----------------------------
router_tmp="$tmp/router"
mkdir -p "$router_tmp/mount/packages/api" "$router_tmp/outside" "$router_tmp/project/packages/api"
printf '#!/bin/sh\nexit 0\n' > "$router_tmp/rh-run"
chmod +x "$router_tmp/rh-run"
router_input="$router_tmp/input.json"
cat > "$router_input" <<EOF
{
  "hook_event_name": "PreToolUse",
  "cwd": "$router_tmp/mount",
  "agent_id": "agent-child-1",
  "agent_type": "general-purpose",
  "tool_name": "Bash",
  "tool_input": {
    "command": "printf routed",
    "workdir": "$router_tmp/mount/packages/api",
    "timeout_ms": 12345
  }
}
EOF
router_output="$router_tmp/output.json"
python3 "$ROOT/scripts/route-command.py" \
  --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
  < "$router_input" > "$router_output"
python3 - "$router_output" "$router_tmp/rh-run" <<'PY'
import base64
import json
import shlex
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
specific = payload["hookSpecificOutput"]
assert specific["hookEventName"] == "PreToolUse"
assert specific["permissionDecision"] == "allow"
updated = specific["updatedInput"]
assert updated["timeout_ms"] == 12345
argv = shlex.split(updated["command"])
assert argv[0] == sys.argv[2]
assert base64.b64decode(argv[1]).decode() == "packages/api"
assert base64.b64decode(argv[2]).decode() == "printf routed"
PY

python3 - "$router_tmp/root-input.json" "$router_tmp/mount" <<'PY'
import json
import sys

json.dump({
    "hook_event_name": "PreToolUse",
    "cwd": sys.argv[2],
    "tool_name": "Bash",
    "tool_input": {"command": "printf root-cwd"},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
python3 "$ROOT/scripts/route-command.py" \
  --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
  < "$router_tmp/root-input.json" > "$router_tmp/root-output.json"
python3 - "$router_tmp/root-output.json" <<'PY'
import base64
import json
import shlex
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
argv = shlex.split(payload["hookSpecificOutput"]["updatedInput"]["command"])
assert base64.b64decode(argv[1]).decode() == "."
PY

cat > "$router_tmp/agent.json" <<EOF
{
  "hook_event_name": "PreToolUse",
  "cwd": "$router_tmp/mount",
  "tool_name": "Agent",
  "tool_input": {"subagent_type": "general-purpose", "name": "reviewer"}
}
EOF
python3 "$ROOT/scripts/route-command.py" \
  --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
  < "$router_tmp/agent.json" > "$router_tmp/agent-output.json"
python3 - "$router_tmp/agent-output.json" <<'PY'
import json
import sys

assert json.load(open(sys.argv[1], encoding="utf-8")) == {}
PY

cat > "$router_tmp/agent-worktree.json" <<EOF
{
  "hook_event_name": "PreToolUse",
  "cwd": "$router_tmp/mount",
  "tool_name": "Agent",
  "tool_input": {"subagent_type": "general-purpose", "isolation": "worktree"}
}
EOF
python3 "$ROOT/scripts/route-command.py" \
  --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
  < "$router_tmp/agent-worktree.json" > "$router_tmp/agent-worktree-output.json"
python3 - "$router_tmp/agent-worktree-output.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
specific = payload["hookSpecificOutput"]
assert specific["permissionDecision"] == "deny"
assert "worktree" in specific["permissionDecisionReason"].lower()
PY

python3 - "$router_tmp/outside.json" "$router_tmp/outside" <<'PY'
import json
import sys

json.dump({
    "hook_event_name": "PreToolUse",
    "cwd": sys.argv[2],
    "tool_name": "Bash",
    "tool_input": {"command": "uname -a"},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
python3 "$ROOT/scripts/route-command.py" \
  --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
  < "$router_tmp/outside.json" > "$router_tmp/outside-output.json"
python3 - "$router_tmp/outside-output.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
specific = payload["hookSpecificOutput"]
assert specific["permissionDecision"] == "deny"
assert "outside" in specific["permissionDecisionReason"].lower()
PY

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
dispatch_out=$(SHELL=/bin/sh sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
  "$(b64 "$router_tmp/project")" "$(b64 packages/api)" \
  "$(b64 'printf "%s|%s" "$PWD" "$GIT_OPTIONAL_LOCKS"')")
assert_eq "project-host cwd and git lock policy" "$dispatch_out" "$router_tmp/project/packages/api|0"
if sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
    "$(b64 "$router_tmp/project")" "$(b64 ../outside)" "$(b64 true)" \
    >/dev/null 2>"$router_tmp/traversal.err"; then
  fail "project-host dispatcher accepted a parent-directory traversal"
fi
assert_grep "$router_tmp/traversal.err" "invalid relative working directory" "dispatch traversal denial"

mkdir -p "$router_tmp/bin"
cat > "$router_tmp/bin/ssh" <<'EOS'
#!/usr/bin/env sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -F|-o) shift 2 ;;
    -T) shift ;;
    *) shift; remote_command=${1:-}; break ;;
  esac
done
set -- $remote_command
[ "$#" -eq 4 ] && [ "$1" = remote-harness-exec ] || exit 2
exec "${TEST_DISPATCHER:?}" --dispatch "$2" "$3" "$4"
EOS
chmod +x "$router_tmp/bin/ssh"
printf 'Host project-host\n    HostName 127.0.0.1\n' > "$router_tmp/ssh_config"
client_out=$(PATH="$router_tmp/bin:$PATH" SHELL=/bin/sh TEST_DISPATCHER="$ROOT/scripts/run-on-project-host.sh" \
  sh "$ROOT/scripts/run-on-project-host.sh" \
    --ssh-config "$router_tmp/ssh_config" --alias project-host \
    --project-root "$router_tmp/project" --cwd-relative-b64 "$(b64 packages/api)" \
    --command-b64 "$(b64 'printf "%s" "$PWD"')")
assert_eq "project-host client transport" "$client_out" "$router_tmp/project/packages/api"

for blocked_command in \
  'claude -p local-child' \
  '/usr/local/bin/codex exec local-child' \
  'env TEST=1 opencode run'; do
  python3 - "$router_tmp/blocked.json" "$router_tmp/mount" "$blocked_command" <<'PY'
import json
import sys

json.dump({
    "hook_event_name": "PreToolUse",
    "cwd": sys.argv[2],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[3]},
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  python3 "$ROOT/scripts/route-command.py" \
    --runner "$router_tmp/rh-run" --mount-root "$router_tmp/mount" \
    < "$router_tmp/blocked.json" > "$router_tmp/blocked-output.json"
  python3 - "$router_tmp/blocked-output.json" <<'PY'
import json
import sys

specific = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]
assert specific["permissionDecision"] == "deny"
assert "agent" in specific["permissionDecisionReason"].lower()
PY
done

if SHELL=/bin/sh sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
    "$(b64 "$router_tmp/project")" "$(b64 packages/api)" "$(b64 'claude -p local-child')" \
    >"$router_tmp/local-agent.out" 2>"$router_tmp/local-agent.err"; then
  fail "project-host dispatcher allowed a direct local Claude launch"
fi
assert_grep "$router_tmp/local-agent.err" "Agent processes must run on the remote" "dispatcher direct agent denial"
indirect_agent_command="sh -c 'codex exec local-child'"
if SHELL=/bin/sh sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
    "$(b64 "$router_tmp/project")" "$(b64 packages/api)" "$(b64 "$indirect_agent_command")" \
    >"$router_tmp/indirect-agent.out" 2>"$router_tmp/indirect-agent.err"; then
  fail "project-host dispatcher allowed an indirect local Codex launch"
fi
assert_grep "$router_tmp/indirect-agent.err" "Agent processes must run on the remote" "dispatcher PATH guard denial"

gateway_home="$router_tmp/gateway-home"
gateway_tag="session-test"
mkdir -p "$gateway_home/.remote-harness/bin" "$gateway_home/.remote-harness/.sessions/gateways/$gateway_tag"
cp "$ROOT/scripts/run-on-project-host.sh" "$gateway_home/.remote-harness/bin/"
cp "$ROOT/scripts/project-host-gateway.sh" "$gateway_home/.remote-harness/bin/"
chmod +x "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_home/.remote-harness/bin/run-on-project-host.sh"
printf '%s' "$(b64 "$router_tmp/project")" > "$gateway_home/.remote-harness/.sessions/gateways/$gateway_tag/project-root.b64"
gateway_health=$(HOME="$gateway_home" SSH_ORIGINAL_COMMAND=remote-harness-health \
  sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag")
case "$gateway_health" in RH_OK*) ;; *) fail "gateway health response invalid: $gateway_health";; esac
gateway_exec=$(HOME="$gateway_home" \
  SSH_ORIGINAL_COMMAND="remote-harness-exec $(b64 "$router_tmp/project") $(b64 packages/api) $(b64 'printf gateway-ok')" \
  sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag")
assert_eq "forced-command gateway execution" "$gateway_exec" "gateway-ok"
if HOME="$gateway_home" SSH_ORIGINAL_COMMAND='uname -a' \
    sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag" \
    >"$router_tmp/gateway-shell.out" 2>"$router_tmp/gateway-shell.err"; then
  fail "forced-command gateway accepted an arbitrary local shell command"
fi
assert_grep "$router_tmp/gateway-shell.err" "unsupported SSH command" "gateway arbitrary shell denial"
if HOME="$gateway_home" SSH_ORIGINAL_COMMAND='internal-sftp -h' \
    sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag" \
    </dev/null >"$router_tmp/gateway-sftp.out" 2>"$router_tmp/gateway-sftp.err"; then
  :
fi
refute_grep "$router_tmp/gateway-sftp.err" "unsupported SSH command" "forced-command gateway rejected the standard internal-sftp request"

# A waiting channel takes one complete exec/tool request line from stdin and nothing else.
gw_wait() {  # $1 = stdin bytes
  printf '%s' "$1" | HOME="$gateway_home" SSH_ORIGINAL_COMMAND=remote-harness-wait \
    sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag"
}
wait_marker="$router_tmp/wait-ran"
wait_out=$(gw_wait "remote-harness-exec $(b64 "$router_tmp/project") $(b64 packages/api) $(b64 'printf wait-ok')
")
assert_eq "waiting channel acknowledges and runs one exec request" "$wait_out" "$(printf 'RH_WAIT_READY\nRH_WAIT_GOT\nwait-ok')"
for wait_bad in \
    "remote-harness-exec $(b64 "$router_tmp/project") $(b64 .) $(b64 ": > $wait_marker")" \
    "remote-harness-health
" \
    "remote-harness-wait
" \
    "internal-sftp
" \
    "remote-harness-exec $(b64 /elsewhere) $(b64 .) $(b64 ": > $wait_marker")
"; do
  if gw_wait "$wait_bad" >"$router_tmp/wait-bad.out" 2>"$router_tmp/wait-bad.err"; then
    fail "waiting channel accepted: $(printf '%s' "$wait_bad" | head -c 40)"
  fi
done
[ ! -e "$wait_marker" ] || fail "waiting channel ran a rejected or incomplete request"
assert_grep "$router_tmp/wait-bad.err" "project root does not match" "waiting channel checks the project root"

# --- direct project-host tools: gateway verb, dispatcher, agent-host shim -----------------------
tool_proj="$router_tmp/tool-project"
tool_mount="$router_tmp/tool-mount"
mkdir -p "$tool_proj/src" "$tool_mount/src"
git -C "$tool_proj" init -q
printf 'hello\n' > "$tool_proj/src/a.txt"
git -C "$tool_proj" add . && git -C "$tool_proj" -c user.email=t@example.com -c user.name=t commit -qm init
printf 'changed\n' >> "$tool_proj/src/a.txt"
printf 'new\n' > "$tool_proj/src/new.txt"
printf 'mount only\n' > "$tool_mount/src/mount-only.txt"
tool_tag="tool-test"
mkdir -p "$gateway_home/.remote-harness/.sessions/gateways/$tool_tag"
printf '%s' "$(b64 "$tool_proj")" > "$gateway_home/.remote-harness/.sessions/gateways/$tool_tag/project-root.b64"
tool_gateway="$gateway_home/.remote-harness/bin/project-host-gateway.sh"
targs() {
  local out="" a
  for a in "$@"; do out="${out:+$out,}$(b64 "x$a")"; done
  printf '%s' "${out:--}"
}
tool_status=$(HOME="$gateway_home" \
  SSH_ORIGINAL_COMMAND="remote-harness-tool $(b64 "$tool_proj") $(b64 .) git $(targs status --porcelain)" \
  sh "$tool_gateway" "$tool_tag")
assert_grep <(printf '%s\n' "$tool_status") " M src/a.txt" "gateway tool git sees modified files"
assert_grep <(printf '%s\n' "$tool_status") "?? src/new.txt" "gateway tool git sees untracked files"
tool_quote=$(HOME="$gateway_home" \
  SSH_ORIGINAL_COMMAND="remote-harness-tool $(b64 "$tool_proj") $(b64 src) git $(targs rev-parse --sq-quote 'a b' '' "$(printf 'tail\n.')")" \
  sh "$tool_gateway" "$tool_tag")
assert_eq "gateway tool argument fidelity" "$tool_quote" "$(git rev-parse --sq-quote 'a b' '' "$(printf 'tail\n.')")"
# Each public tool entry must reject invalid requests before running a tool or contacting SSH.
# A shell request would create the marker if it escaped the allowlist; the client-side fake SSH
# creates the same marker if validation is deferred to the other end of the connection.
tool_rejected_marker="$router_tmp/tool-rejected-ran"
tool_validation_bin="$router_tmp/tool-validation-bin"
mkdir -p "$tool_validation_bin"
cat > "$tool_validation_bin/ssh" <<'EOS'
#!/bin/sh
: > "${TOOL_REJECTED_MARKER:?}"
exit 0
EOS
chmod +x "$tool_validation_bin/ssh"
: > "$router_tmp/tool-validation.ssh_config"
for tool_entry in gateway dispatch client; do
  for tool_invalid in name encoding; do
    case "$tool_invalid" in
      name)
        invalid_tool=sh
        invalid_args=$(targs -c ": > '$tool_rejected_marker'")
        invalid_message='unsupported project tool'
        ;;
      encoding)
        invalid_tool=git
        invalid_args='a;b'
        invalid_message='invalid tool argument encoding'
        ;;
    esac
    rejected_status=0
    case "$tool_entry" in
      gateway)
        HOME="$gateway_home" \
          SSH_ORIGINAL_COMMAND="remote-harness-tool $(b64 "$tool_proj") $(b64 .) $invalid_tool $invalid_args" \
          sh "$tool_gateway" "$tool_tag" >"$router_tmp/tool-bad.out" 2>"$router_tmp/tool-bad.err" \
          || rejected_status=$?
        ;;
      dispatch)
        HOME="$gateway_home" sh "$ROOT/scripts/run-on-project-host.sh" --dispatch-tool \
          "$(b64 "$tool_proj")" "$(b64 .)" "$invalid_tool" "$invalid_args" \
          >"$router_tmp/tool-bad.out" 2>"$router_tmp/tool-bad.err" || rejected_status=$?
        ;;
      client)
        PATH="$tool_validation_bin:$PATH" TOOL_REJECTED_MARKER="$tool_rejected_marker" \
          sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/tool-validation.ssh_config" \
          --alias laptop --project-root "$tool_proj" --cwd-relative-b64 "$(b64 .)" \
          --tool "$invalid_tool" --args-b64 "$invalid_args" \
          >"$router_tmp/tool-bad.out" 2>"$router_tmp/tool-bad.err" || rejected_status=$?
        ;;
    esac
    assert_eq "$tool_entry rejects invalid tool $tool_invalid" "$rejected_status" 2
    assert_grep "$router_tmp/tool-bad.err" "$invalid_message" "$tool_entry validates tool $tool_invalid"
    [ ! -e "$tool_rejected_marker" ] || fail "$tool_entry executed a rejected tool request"
  done
done
if HOME="$gateway_home" \
    SSH_ORIGINAL_COMMAND="remote-harness-tool $(b64 "$router_tmp/project") $(b64 .) git -" \
    sh "$tool_gateway" "$tool_tag" >/dev/null 2>"$router_tmp/tool-bad.err"; then
  fail "gateway accepted a tool request for another project root"
fi
# Closing the SSH channel (cancelled caller / dropped link) stops the tool on the project host.
mkfifo "$tool_proj/blocked.fifo"
tool_started=$(date +%s)
{ sleep 1; } | HOME="$gateway_home" \
  SSH_ORIGINAL_COMMAND="remote-harness-tool $(b64 "$tool_proj") $(b64 .) git $(targs hash-object blocked.fifo)" \
  sh "$tool_gateway" "$tool_tag" >/dev/null 2>&1 || true
tool_elapsed=$(( $(date +%s) - tool_started ))
[ "$tool_elapsed" -lt 10 ] || fail "project-host tool kept running after its SSH channel closed (${tool_elapsed}s)"
rm -f "$tool_proj/blocked.fifo"

# Agent-host shim through a fake ssh that invokes the forced gateway.
shim_bin="$router_tmp/shim-bin"
shim_log="$router_tmp/shim-ssh.log"
mkdir -p "$shim_bin"
cat > "$shim_bin/ssh" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> '$shim_log'
while [ "\$#" -gt 0 ]; do
  case "\$1" in -F|-o) shift 2 ;; -T) shift ;; -O) exit 0 ;; *) break ;; esac
done
shift
HOME='$gateway_home' SSH_ORIGINAL_COMMAND="\$1" exec sh '$tool_gateway' '$tool_tag'
EOS
chmod +x "$shim_bin/ssh"
printf 'Host project-host\n    HostName 127.0.0.1\n' > "$router_tmp/shim_ssh_config"
run_shim() {  # $1=tool $2=real $3=control path, rest = tool args
  local tool=$1 real=$2 control=$3
  shift 3
  PATH="$shim_bin:$PATH" python3 -I "$ROOT/scripts/project-host-tool.py" --tool "$tool" --real "$real" \
    --runner "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/shim_ssh_config" \
    --alias project-host --project-root "$tool_proj" --mount-root "$tool_mount" \
    --control-path "$control" --slots-dir "$router_tmp/shim-slots" -- "$@"
}
shim_status=$(cd "$tool_mount" && run_shim git "$(command -v git)" "" status --porcelain)
assert_grep <(printf '%s\n' "$shim_status") "?? src/new.txt" "shim routes git status to the project host"
if printf '%s\n' "$shim_status" | grep -F mount-only >/dev/null; then
  fail "shim scanned the agent-side mount for git status"
fi
assert_grep "$shim_log" "remote-harness-tool" "shim used the tool gateway verb"
: > "$shim_log"
# Claude Code hardens its internal git calls with GIT_CONFIG_PARAMETERS/GIT_CONFIG_COUNT; forward them
# as -c instead of scanning the whole tree over SSHFS. An unparsable value stays local.
hardened_status=$(cd "$tool_mount" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
  GIT_CONFIG_PARAMETERS="'alias.remote-/.command=version' 'fetch.bundleURI=' 'core.quotepath'='off' 'user.name=it'\\''s a!b'" \
  run_shim git "$(command -v git)" "" --no-optional-locks status --porcelain)
assert_grep <(printf '%s\n' "$hardened_status") "?? src/new.txt" "shim routes git status despite GIT_CONFIG_PARAMETERS"
: > "$shim_log"
(cd "$tool_mount" && GIT_CONFIG_PARAMETERS="'unbalanced" run_shim git "$(command -v git)" "" status) >/dev/null 2>&1 || true
[ ! -s "$shim_log" ] || fail "shim routed git with an unparsable GIT_CONFIG_PARAMETERS"
# Read-only discovery runs on the project host, and its absolute paths name the mount again.
shim_top=$(cd "$tool_mount" && run_shim git "$(command -v git)" "" rev-parse --show-toplevel)
assert_eq "shim maps rev-parse --show-toplevel back to the mount" "$shim_top" "$tool_mount"
for shim_wt in "worktree list" "worktree list --porcelain"; do
  # shellcheck disable=SC2086
  shim_wt_out=$(cd "$tool_mount" && run_shim git "$(command -v git)" "" $shim_wt)
  case "$shim_wt_out" in *"$tool_proj"*|"") fail "git $shim_wt leaked the project-host path: $shim_wt_out";; esac
  assert_grep <(printf '%s\n' "$shim_wt_out") "$tool_mount" "git $shim_wt names the mount"
done
assert_grep "$shim_log" "remote-harness-tool" "shim routes read-only git discovery"
: > "$shim_log"
for shim_write in "config user.name tester" "branch -D no-such-branch" "symbolic-ref HEAD refs/heads/x"; do
  # shellcheck disable=SC2086
  (cd "$tool_mount" && run_shim git "$(command -v git)" "" $shim_write) >/dev/null 2>&1 || true
done
[ ! -s "$shim_log" ] || fail "shim routed a git command that writes"
outside_version=$(cd "$router_tmp" && run_shim git "$(command -v git)" "" --version)
assert_eq "shim leaves git outside the mount alone" "$outside_version" "$(git --version)"
[ ! -s "$shim_log" ] || fail "shim contacted the project host for a call outside the mount"
local_cfg=$(cd "$tool_mount" && run_shim git "$(command -v git)" "" config core.checkStat || true)
assert_eq "local git on the mount gets process-level checkStat" "$local_cfg" "minimal"
outside_cfg=$(cd "$router_tmp" && run_shim git "$(command -v git)" "" config core.checkStat || true)
assert_eq "git outside the mount keeps its own config" "$outside_cfg" ""

# Transport failure: retry once without multiplexing, then fail loudly (never clean / no-match).
fail_bin="$router_tmp/fail-bin"
mkdir -p "$fail_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 255\n' "'$router_tmp/fail-ssh.log'" > "$fail_bin/ssh"
chmod +x "$fail_bin/ssh"
if (cd "$tool_mount" && PATH="$fail_bin:$PATH" python3 -I "$ROOT/scripts/project-host-tool.py" --tool git \
    --real "$(command -v git)" --runner "$ROOT/scripts/run-on-project-host.sh" \
    --ssh-config "$router_tmp/shim_ssh_config" --alias project-host --project-root "$tool_proj" \
    --mount-root "$tool_mount" --control-path /tmp/rh-test-mux --slots-dir "$router_tmp/shim-slots" \
    -- status) >"$router_tmp/fail.out" 2>"$router_tmp/fail.err"; then
  fail "shim reported success although the project host was unreachable"
fi
assert_grep "$router_tmp/fail.err" "not falling back" "shim transport failure is explicit"
[ ! -s "$router_tmp/fail.out" ] || fail "shim printed output for an unreachable project host"
assert_eq "shim retries exactly once" "$(grep -c . "$router_tmp/fail-ssh.log")" "2"
assert_grep "$router_tmp/fail-ssh.log" "ControlMaster=auto" "first attempt uses the multiplexing master"
assert_eq "retry bypasses the master" "$(sed -n 2p "$router_tmp/fail-ssh.log" | grep -c 'ControlMaster=no')" "1"

# rg: absolute mount paths go out translated and come back as mount paths.
rg_real=$(command -v rg 2>/dev/null || true)
case "$rg_real" in /*) ;; *) rg_real="" ;; esac
if [ -n "$rg_real" ]; then
  mkdir -p "$gateway_home/.local/bin"
  ln -sf "$rg_real" "$gateway_home/.local/bin/rg"
  rg_out=$(cd "$tool_mount" && run_shim rg "$rg_real" "" -n hello "$tool_mount/src")
  assert_eq "rg output paths are mapped back to the mount" "$rg_out" "$tool_mount/src/a.txt:1:hello"
  if (cd "$tool_mount" && run_shim rg "$rg_real" "" zzzz-no-match) >/dev/null 2>&1; then
    fail "rg no-match did not keep exit status 1"
  fi
fi

# A reachable project host without the tool (a Mac without ripgrep): the session keeps using the
# agent-host tool instead of failing every search, and asks the project host only once.
missing_bin="$router_tmp/missing-bin"
missing_log="$router_tmp/missing-ssh.log"
mkdir -p "$missing_bin" "$router_tmp/missing-runtime"
cat > "$missing_bin/ssh" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> '$missing_log'
printf 'remote-harness: rg is not installed on the project host\n' >&2
exit 127
EOS
cat > "$missing_bin/local-rg" <<'EOS'
#!/bin/sh
printf 'local-rg %s\n' "$*"
EOS
chmod +x "$missing_bin/ssh" "$missing_bin/local-rg"
run_missing_rg() {
  (cd "$tool_mount" && PATH="$missing_bin:$PATH" python3 -I "$ROOT/scripts/project-host-tool.py" \
    --tool rg --real "$missing_bin/local-rg" --runner "$ROOT/scripts/run-on-project-host.sh" \
    --ssh-config "$router_tmp/shim_ssh_config" --alias project-host --project-root "$tool_proj" \
    --mount-root "$tool_mount" --control-path "" --slots-dir "$router_tmp/missing-runtime/tool-slots" \
    -- "$@")
}
assert_eq "rg missing on the project host falls back to the agent-host rg" \
  "$(run_missing_rg --files 2>&1)" "local-rg --files"
assert_eq "later rg calls keep the agent-host rg" "$(run_missing_rg -n hello 2>&1)" "local-rg -n hello"
assert_eq "a missing project-host tool is detected once per session" "$(grep -c . "$missing_log")" "1"

# Concurrency cap: with one slot, routed calls never overlap.
cap_runner="$router_tmp/cap-runner"
printf '#!/bin/sh\nprintf "start\\n" >> %s\nsleep 1\nprintf "end\\n" >> %s\n' \
  "'$router_tmp/cap.log'" "'$router_tmp/cap.log'" > "$cap_runner"
chmod +x "$cap_runner"
for cap_i in 1 2 3; do
  (cd "$tool_mount" && RH_TOOL_CONCURRENCY=1 python3 -I "$ROOT/scripts/project-host-tool.py" --tool git \
    --real "$(command -v git)" --runner "$cap_runner" --ssh-config "$router_tmp/shim_ssh_config" \
    --alias project-host --project-root "$tool_proj" --mount-root "$tool_mount" \
    --slots-dir "$router_tmp/cap-slots" -- status >/dev/null) &
done
wait
assert_eq "concurrency cap serializes routed calls" "$(tr '\n' ' ' < "$router_tmp/cap.log")" "start end start end start end "

# Client transport: per-connection tuning and a short multiplexing socket.
mux_bin="$router_tmp/mux-bin"
mkdir -p "$mux_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > %s\n' "'$router_tmp/mux-ssh.args'" > "$mux_bin/ssh"
chmod +x "$mux_bin/ssh"
PATH="$mux_bin:$PATH" sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/ssh_config" \
  --alias project-host --project-root "$router_tmp/project" --control-path /tmp/rh-mux-test \
  --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 true)"
for mux_opt in ControlMaster=auto ControlPath=/tmp/rh-mux-test ControlPersist=3600 \
    ServerAliveInterval=10 ServerAliveCountMax=3 ConnectTimeout=10 BatchMode=yes; do
  assert_grep "$router_tmp/mux-ssh.args" "-o $mux_opt" "client ssh option $mux_opt"
done
PATH="$mux_bin:$PATH" sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/ssh_config" \
  --alias project-host --project-root "$router_tmp/project" \
  --control-path "/tmp/$(printf 'x%.0s' $(seq 1 90))" \
  --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 true)"
assert_grep "$router_tmp/mux-ssh.args" "-o ControlMaster=no" "overlong control path disables multiplexing"

# --- watched Bash commands: channel EOF stops the whole command tree on the project host ---------
wait_until() {  # tenths-of-a-second command...: poll until the command succeeds
  _wu_n=$1; shift
  while ! "$@"; do
    [ "$_wu_n" -gt 0 ] || return 1
    _wu_n=$((_wu_n - 1)); sleep 0.1
  done
}
tree_alive() { ps -A -o args= 2>/dev/null | grep -Ex "sleep ($1)" >/dev/null; }
tree_gone() { ! tree_alive "$1"; }
watch_started=$(date +%s)
{ sleep 1; } | SHELL=/bin/sh sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
  "$(b64 "$router_tmp/project")" "$(b64 .)" "$(b64 'sleep 47 & sleep 48 & wait')" watch \
  >/dev/null 2>&1 || true
watch_elapsed=$(( $(date +%s) - watch_started ))
[ "$watch_elapsed" -lt 15 ] || fail "watched command outlived its closed channel (${watch_elapsed}s)"
wait_until 20 tree_gone '47|48' || fail "watched command left child processes running after its channel closed"
watch_rc=0
watch_out=$({ sleep 2; } | SHELL=/bin/sh sh "$ROOT/scripts/run-on-project-host.sh" --dispatch \
  "$(b64 "$router_tmp/project")" "$(b64 .)" "$(b64 'printf watched; exit 7')" watch) || watch_rc=$?
assert_eq "watched command output" "$watch_out" "watched"
assert_eq "watched command keeps its exit status" "$watch_rc" "7"
gateway_watch=$(HOME="$gateway_home" \
  SSH_ORIGINAL_COMMAND="remote-harness-exec $(b64 "$router_tmp/project") $(b64 .) $(b64 'printf gw-watch') watch" \
  sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag" </dev/null)
assert_eq "gateway accepts the watch mode" "$gateway_watch" "gw-watch"
if HOME="$gateway_home" \
    SSH_ORIGINAL_COMMAND="remote-harness-exec $(b64 "$router_tmp/project") $(b64 .) $(b64 true) other" \
    sh "$gateway_home/.remote-harness/bin/project-host-gateway.sh" "$gateway_tag" >/dev/null 2>&1; then
  fail "gateway accepted an unknown execution mode"
fi
PATH="$mux_bin:$PATH" sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/ssh_config" \
  --alias project-host --project-root "$router_tmp/project" --watch \
  --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 true)"
assert_grep "$router_tmp/mux-ssh.args" "$(b64 true) watch" "client requests watch mode"
assert_grep "$router_tmp/mux-ssh.args" "remote-harness-exec $(b64 "$router_tmp/project") " "client encodes the project root"
PATH="$mux_bin:$PATH" sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/ssh_config" \
  --alias project-host --project-root "$router_tmp/project" --project-root-b64 "$(b64 "$router_tmp/project")" \
  --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 true)"
assert_grep "$router_tmp/mux-ssh.args" "remote-harness-exec $(b64 "$router_tmp/project") " "client sends a pre-encoded project root"
if PATH="$mux_bin:$PATH" sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/ssh_config" \
    --alias project-host --project-root "$router_tmp/project" --project-root-b64 'x y' \
    --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 true)" >/dev/null 2>&1; then
  fail "client accepted a malformed pre-encoded project root"
fi

# A killed guard (cancelled tool call, crashed agent) closes the channel and stops the command.
PATH="$shim_bin:$PATH" python3 -I "$ROOT/scripts/channel-guard.py" -- \
  sh "$ROOT/scripts/run-on-project-host.sh" --ssh-config "$router_tmp/shim_ssh_config" \
  --alias project-host --project-root "$tool_proj" --watch \
  --cwd-relative-b64 "$(b64 .)" --command-b64 "$(b64 'sleep 49')" >/dev/null 2>&1 &
guard_pid=$!
wait_until 100 tree_alive 49 || fail "guarded command never started"
kill -KILL "$guard_pid" 2>/dev/null || true
wait "$guard_pid" 2>/dev/null || true
wait_until 100 tree_gone 49 || fail "project-host command kept running after its guard was killed"
guard_rc=0
PATH="$shim_bin:$PATH" python3 -I "$ROOT/scripts/channel-guard.py" -- sh -c 'exit 5' || guard_rc=$?
assert_eq "channel guard returns the command status" "$guard_rc" "5"
# Warm channel problems leave the guard on the ordinary path: no pool, or a request it will not send.
guard_out=$(python3 -I -S "$ROOT/scripts/channel-guard.py" --warm "$tmp/no-pool" \
  --warm-request "remote-harness-exec $(b64 /p) $(b64 .) $(b64 true) watch" -- sh -c 'printf cold')
assert_eq "guard without a warm pool runs the ordinary path" "$guard_out" "cold"
guard_out=$(python3 -I -S "$ROOT/scripts/channel-guard.py" --warm "$tmp/no-pool" --warm-request "uname -a" \
  -- sh -c 'printf cold2')
assert_eq "guard never sends a malformed warm request" "$guard_out" "cold2"
RH_WARM_MAX=0 python3 -I -S "$ROOT/scripts/warm_pool.py" serve --socket "$tmp/p" --control-path "$tmp/c" \
  --ssh-config /dev/null --alias a --owner-pid $$ --session-dir "$tmp" --log "$tmp/warm-off.log" \
  || fail "warm pool with RH_WARM_MAX=0 did not exit cleanly"
[ ! -e "$tmp/p" ] || fail "warm pool with RH_WARM_MAX=0 created its socket"
if python3 -I -S "$ROOT/scripts/warm_pool.py" serve --socket "$tmp/p" 2>/dev/null; then
  fail "warm pool accepted incomplete arguments"
fi

parse_via "ssh -J jump -p 2222 -i /tmp/key dev@example.com"
assert_eq "host" "$V_HOST" "example.com"
assert_eq "port" "$V_PORT" "2222"
assert_eq "user" "$V_USER" "dev"
assert_eq "identity" "$V_IDENTITY" "/tmp/key"
assert_eq "proxyjump" "$V_PROXYJUMP" "jump"

parse_via "ssh -o ProxyJump=bastion -o Port=2022 -o User=deploy app.internal"
assert_eq "o-host" "$V_HOST" "app.internal"
assert_eq "o-port" "$V_PORT" "2022"
assert_eq "o-user" "$V_USER" "deploy"
assert_eq "o-proxyjump" "$V_PROXYJUMP" "bastion"

parse_via "ssh -F /tmp/ssh_config app.internal"
assert_eq "unsupported ssh options" "$V_UNSUPPORTED_SSH_OPTIONS" " -F"

CFG="$tmp/config"
touch "$CFG"
parse_via "ssh -J jumpbox -p 2200 -i /tmp/key user@example.com"
write_managed_alias example-dev "    ServerAliveInterval 30"
assert_grep "$CFG" "Host example-dev" "managed alias"
assert_grep "$CFG" "    HostName example.com" "managed hostname"
assert_grep "$CFG" "    Port 2200" "managed port"
assert_grep "$CFG" "    User user" "managed user"
assert_grep "$CFG" "    IdentityFile /tmp/key" "managed identity"
assert_grep "$CFG" "    ProxyJump jumpbox" "managed proxyjump"

parse_via "ssh -J otherjump user@example.com"
write_managed_alias example-dev
host_count="$(awk '$1=="Host" && $2=="example-dev"{n++} END{print n+0}' "$CFG")"
assert_eq "idempotent alias count" "$host_count" "1"
assert_grep "$CFG" "    ProxyJump otherjump" "managed alias replacement"

for removed_script in preflight.sh detect.sh connect-guesses.sh server-guesses.sh list-projects.sh session-cache.sh; do
  [ ! -e "$ROOT/scripts/$removed_script" ] || fail "removed script still exists: $removed_script"
done
if grep -R -E 'preflight|detect\.sh|connect-guesses|server-guesses|list-projects|session-cache|legacy|旧流程' \
    "$ROOT/README.md" "$ROOT/AGENTS.md" "$ROOT/AGENTS.cn.md" "$ROOT/SKILL.md" "$ROOT/SKILL.cn.md" \
    "$ROOT/reference" "$ROOT/docs" >/dev/null 2>&1; then
  fail "docs still reference removed/legacy flows"
fi

mkdir -p "$tmp/bin"

mkdir -p "$tmp/code" "$tmp/mount" "$tmp/home with 'quote/.codex" "$tmp/rh with 'quote"
printf 'personal guidance\n' > "$tmp/home with 'quote/.codex/AGENTS.md"
rh_home="$tmp/rh with 'quote"
home_dir="$tmp/home with 'quote"
session_key="$(printf '%s' "$tmp/mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
session_dir="$rh_home/.sessions/$session_key"
basic_ssh_cfg="$tmp/basic-ssh-config"
printf 'Host laptop\n    HostName 127.0.0.1\n' > "$basic_ssh_cfg"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on codex "$tmp/code" laptop "$tmp/mount" 0 "$basic_ssh_cfg" > "$tmp/inject.out"
assert_grep "$tmp/inject.out" "RH_STATUS=INJECTED" "inject on"
assert_grep "$tmp/inject.out" "RH_LAUNCH_ENV=" "inject codex leaves CODEX_HOME alone"
assert_grep "$tmp/inject.out" "RH_LAUNCH_FLAGS=-c 'developer_instructions=\"" "inject codex developer instructions"
assert_grep "$tmp/inject.out" "hooks.PreToolUse=" "inject codex pre-tool hook"
assert_grep "$tmp/inject.out" "--dangerously-bypass-hook-trust" "inject codex trusts generated session hook"
assert_grep "$tmp/inject.out" "$(command -v python3)" "inject codex pins the Python hook runtime"
assert_grep "$tmp/inject.out" "Remote dev harness strict routing rule" "inject codex strict routing instructions"
assert_grep "$tmp/inject.out" "sandbox_workspace_write.writable_roots=[" "inject codex writable roots present"
assert_grep "$tmp/inject.out" "sandbox_workspace_write.writable_roots=[\"$(dirname "$basic_ssh_cfg")/runtime\"]" "inject codex only makes mutable SSH runtime writable"
if grep -F "sandbox_workspace_write.writable_roots=[\"$session_dir" "$tmp/inject.out" >/dev/null; then
  fail "inject codex made its hook and runner directory writable"
fi
[ -x "$session_dir/bin/rh-run" ] || fail "inject codex session runner missing"
assert_grep "$session_dir/bin/rh-run" "run-on-project-host.sh" "session runner delegates to project host"
refute_grep "$tmp/inject.out" 'writable_roots=["~/.ssh"]' "inject codex made ~/.ssh writable"
[ -f "$session_dir/rule.md" ] || fail "inject rule file missing"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off codex "$tmp/mount" > "$tmp/inject-off.out"
assert_grep "$tmp/inject-off.out" "RH_STATUS=RESTORED" "inject off"
[ ! -d "$session_dir" ] || fail "inject session dir was not removed"

# Heartbeat: an unreachable project host ends the agent after the timeout and leaves a resume marker
# that the next launch of the same mountpoint and agent reports once.
hb_mount="$tmp/mount-heartbeat"
hb_bin="$tmp/heartbeat-bin"
mkdir -p "$hb_mount" "$hb_bin"
printf '#!/bin/sh\n[ -z "${HB_OK:-}" ] || { printf "RH_OK host user"; exit 0; }\nexit 255\n' > "$hb_bin/ssh"
chmod +x "$hb_bin/ssh"
hb_inject() {  # on|off session-id
  if [ "$1" = on ]; then
    RH_HOME="$rh_home" HOME="$home_dir" \
      "$ROOT/scripts/inject-rule.sh" on claude "$tmp/code" laptop "$hb_mount" 0 "$basic_ssh_cfg" "$2"
  else
    RH_HOME="$rh_home" HOME="$home_dir" "$ROOT/scripts/inject-rule.sh" off claude "$hb_mount" "$2" >/dev/null 2>&1 || true
  fi
}
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
wait_gone() { wait_until "${2:-200}" pid_gone "$1"; }  # pid [tenths of a second]
hb_inject on hb.1 > "$tmp/inject-hb1.out"
assert_grep "$tmp/inject-hb1.out" "RH_RESUME_AVAILABLE=" "inject reports resume availability"
assert_grep "$tmp/inject-hb1.out" "RH_RESUME_ARGS=--continue" "inject reports how claude continues"
refute_grep "$tmp/inject-hb1.out" "RH_RESUME_AVAILABLE=heartbeat" "a fresh mountpoint offers no resume"
hb_sd=$(sed -n 's/^RH_SESSION_DIR=//p' "$tmp/inject-hb1.out")
hb_watch() {  # runs the watcher on a sleeping stand-in agent
  hb_owner=$(sh -c 'sleep 120 >/dev/null 2>&1 & echo $!')  # not a job of this shell: no kill notice
  printf 'OWNER_PID=%s\nOWNER_START=%s\nOWNER_TTY=\n' "$hb_owner" "$(b64 "$(proc_start "$hb_owner")")" > "$hb_sd/owner.env"
  RH_HOME="$rh_home" PATH="$hb_bin:$PATH" RH_HEARTBEAT_INTERVAL=1 RH_HEARTBEAT_TIMEOUT=2 \
    RH_REAP_POLL=1 RH_REAP_GRACE=0 "$hb_sd/impl/session-reaper.sh" watch "$hb_sd" </dev/null >/dev/null 2>&1 &
  hb_watcher=$!
}
HB_OK=1 hb_watch  # the watcher inherits HB_OK
sleep 3  # longer than the 2s timeout
kill -0 "$hb_owner" 2>/dev/null || fail "a reachable project host ended the agent"
kill "$hb_watcher" "$hb_owner" 2>/dev/null || true
wait "$hb_watcher" 2>/dev/null || true
hb_watch
wait_gone "$hb_owner" || { kill "$hb_owner" "$hb_watcher"; fail "an unreachable project host did not end the agent"; }
wait_gone "$hb_watcher" || kill "$hb_watcher" 2>/dev/null
wait "$hb_watcher" 2>/dev/null || true
[ -n "$(find "$rh_home/.sessions/.resume" -name '*.claude' -print -quit 2>/dev/null)" ] || fail "heartbeat loss left no resume marker"
hb_inject off hb.1
hb_inject on hb.2 > "$tmp/inject-hb2.out"
assert_grep_e "$tmp/inject-hb2.out" "^RH_RESUME_AVAILABLE=heartbeat,[0-9]+$" "next launch of the mountpoint offers resume"
hb_inject off hb.2
hb_inject on hb.3 > "$tmp/inject-hb3.out"
refute_grep "$tmp/inject-hb3.out" "RH_RESUME_AVAILABLE=heartbeat" "a resume marker is offered only once"
hb_inject off hb.3
# An agent that exits by itself (as most do on the SIGHUP of a dropped connection) leaves a resume
# marker only when the project host is unreachable at that moment.
hb_exit() {  # session-id: the stand-in agent exits on its own, then the watcher finishes
  hb_sd=$(hb_inject on "$1" | sed -n 's/^RH_SESSION_DIR=//p')
  hb_watch
  kill "$hb_owner" 2>/dev/null || true
  wait_gone "$hb_watcher" || { kill "$hb_watcher"; fail "the watcher did not finish after the agent exited"; }
  wait "$hb_watcher" 2>/dev/null || true
  hb_inject off "$1"
}
HB_OK=1 hb_exit hb.4
[ -z "$(find "$rh_home/.sessions/.resume" -type f 2>/dev/null)" ] \
  || fail "an agent exit with a reachable project host left a resume marker"
hb_exit hb.5
hb_inject on hb.6 > "$tmp/inject-hb6.out"
assert_grep_e "$tmp/inject-hb6.out" "^RH_RESUME_AVAILABLE=exited,[0-9]+$" "an agent exit with an unreachable project host offers resume"
hb_inject off hb.6

# Auto approval uses the remote CLI's automatic review when it has one and falls back to normal.
ap_bin="$tmp/approval-bin"
mkdir -p "$ap_bin" "$tmp/mount-approval"
ap_inject() {  # agent approval session-id; output in $tmp/approval-<session-id>.out
  PATH="$ap_bin:$PATH" RH_HOME="$rh_home" HOME="$home_dir" "$ROOT/scripts/inject-rule.sh" on "$1" \
    "$tmp/code" laptop "$tmp/mount-approval" "$2" "$basic_ssh_cfg" "$3" > "$tmp/approval-$3.out"
  RH_HOME="$rh_home" HOME="$home_dir" "$ROOT/scripts/inject-rule.sh" off "$1" "$tmp/mount-approval" "$3" >/dev/null
}
printf '#!/bin/sh\necho "  --permission-mode <mode>  (choices: \\"auto\\", \\"manual\\")"\n' > "$ap_bin/claude"
printf '#!/bin/sh\necho "      --approve-for-me"\n' > "$ap_bin/codex"
chmod +x "$ap_bin/claude" "$ap_bin/codex"
ap_inject claude auto ap.c1
assert_grep "$tmp/approval-ap.c1.out" "--permission-mode auto" "auto approval starts claude in auto mode"
assert_grep "$tmp/approval-ap.c1.out" "RH_APPROVAL=auto" "inject reports claude auto approval"
ap_inject codex auto ap.x1
assert_grep "$tmp/approval-ap.x1.out" "--approve-for-me" "auto approval routes codex approvals to automatic review"
assert_grep "$tmp/approval-ap.x1.out" "-s workspace-write" "codex automatic review keeps the workspace-write sandbox"
ap_inject codex yolo ap.x2
assert_grep "$tmp/approval-ap.x2.out" "RH_APPROVAL=yolo" "inject accepts the yolo approval name"
refute_grep "$tmp/approval-ap.x2.out" "--approve-for-me" "yolo codex also requested automatic review"
printf '#!/bin/sh\necho usage\n' > "$ap_bin/claude"
cp "$ap_bin/claude" "$ap_bin/codex"
ap_inject claude auto ap.c2
assert_grep "$tmp/approval-ap.c2.out" "RH_APPROVAL=normal" "a claude without auto mode falls back to normal approvals"
refute_grep "$tmp/approval-ap.c2.out" "--permission-mode" "a claude without auto mode got --permission-mode"
ap_inject codex auto ap.x3
refute_grep "$tmp/approval-ap.x3.out" "--approve-for-me" "a codex without automatic review got --approve-for-me"
ap_inject opencode auto ap.o1
assert_grep "$tmp/approval-ap.o1.out" "RH_APPROVAL=normal" "opencode auto approval falls back to normal"

ssh_cfg="$tmp/session_ssh_config"
printf 'Host rlocal\n    HostName 127.0.0.1\n' > "$ssh_cfg"
session_key_wrapped="$(printf '%s' "$tmp/mount-wrapped" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
wrapped_dir="$rh_home/.sessions/$session_key_wrapped"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on codex "$tmp/code" rlocal "$tmp/mount-wrapped" 0 "$ssh_cfg" > "$tmp/inject-wrapped.out"
assert_grep "$tmp/inject-wrapped.out" "RH_LAUNCH_ENV=PATH='" "inject wrapper exports PATH"
[ -x "$wrapped_dir/bin/ssh" ] || fail "inject wrapper ssh missing"
assert_grep "$wrapped_dir/bin/ssh" "cfg='$ssh_cfg'" "inject wrapper stores temp ssh config"
assert_grep "$wrapped_dir/bin/ssh" '-F "$cfg"' "inject wrapper uses temp ssh config"
assert_grep "$wrapped_dir/rule.md" 'every Bash command is routed to `rlocal`' "inject rule documents automatic routing"
refute_grep "$wrapped_dir/rule.md" "ssh rlocal 'cd" "strict inject rule still tells Codex to wrap commands in ssh"
assert_grep "$tmp/inject-wrapped.out" "sandbox_workspace_write.writable_roots=[" "inject wrapper writable roots present"
assert_grep "$tmp/inject-wrapped.out" "$(dirname "$ssh_cfg")" "inject wrapper writable roots include session config dir"
refute_grep "$wrapped_dir/rule.md" "-F " "inject rule exposed temp ssh config path"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off codex "$tmp/mount-wrapped" >/dev/null

# Codex standalone bundle: rg is absent from the login PATH, and codex is a symlink.
# Exercise the generated shims and pinned shell-tool environment through the fake gateway.
codex_bundle="$tmp/codex bundle"
codex_tool_bin="$tmp/codex tools 'quoted\""
mkdir -p "$codex_bundle/bin" "$codex_bundle/codex-path" "$codex_tool_bin"
for codex_dep in bash sh dirname mkdir chmod sed tr awk cat rm cp git python3 grep cksum base64; do
  ln -s "$(command -v "$codex_dep")" "$codex_tool_bin/$codex_dep"
done
# The simulated project host has its own PATH, just like a real SSH server does.
printf '#!/bin/sh\nPATH=%s\nexport PATH\nexec %s "$@"\n' \
  "$(sq "$PATH")" "$(sq "$shim_bin/ssh")" > "$codex_tool_bin/ssh"
chmod +x "$codex_tool_bin/ssh"
printf '#!/bin/sh\nexit 0\n' > "$codex_bundle/bin/codex"
chmod +x "$codex_bundle/bin/codex"
ln -s "$codex_bundle/bin/codex" "$codex_tool_bin/codex"
if [ -n "$rg_real" ]; then
  ln -s "$rg_real" "$codex_bundle/codex-path/rg"
else
  printf '#!/bin/sh\nprintf "ripgrep fixture\\n"\n' > "$codex_bundle/codex-path/rg"
  chmod +x "$codex_bundle/codex-path/rg"
fi
for codex_yolo in 0 1; do
  PATH="$codex_tool_bin" RH_HOME="$rh_home" HOME="$home_dir" \
    "$ROOT/scripts/inject-rule.sh" on codex "$tool_proj" project-host "$tool_mount" "$codex_yolo" \
      "$router_tmp/shim_ssh_config" "codex.$codex_yolo" > "$tmp/codex-tools.out"
  codex_tool_sd="$rh_home/.sessions/$(printf '%s' "$tool_mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_').codex.$codex_yolo"
  [ -x "$codex_tool_sd/bin/rg" ] || fail "Codex bundled rg did not get a shim"
  python3 - "$tmp/codex-tools.out" "$tool_mount" "$rg_real" <<'PY'
import json
import os
import shlex
import subprocess
import sys

lines = dict(line.rstrip("\n").split("=", 1) for line in open(sys.argv[1], encoding="utf-8"))
assert lines["RH_STATUS"] == "INJECTED"
flags = shlex.split(lines["RH_LAUNCH_FLAGS"])
config = dict(flags[i + 1].split("=", 1) for i, flag in enumerate(flags) if flag == "-c")
env = os.environ.copy()
# Simulate applying Codex's explicit env override after its own PATH preparation.
env["PATH"] = json.loads(config["shell_environment_policy.set.PATH"])
status = subprocess.check_output(["git", "status", "--porcelain"], cwd=sys.argv[2], env=env, text=True)
assert "?? src/new.txt" in status and "mount-only" not in status, status
if sys.argv[3]:
    found = subprocess.check_output(["rg", "-n", "hello", sys.argv[2] + "/src"],
                                    cwd=sys.argv[2], env=env, text=True)
    assert found == sys.argv[2] + "/src/a.txt:1:hello\n", found
    assert subprocess.run(["rg", "zzzz-no-match"], cwd=sys.argv[2], env=env).returncode == 1
version = subprocess.check_output(["rg", "--version"], cwd=os.path.dirname(sys.argv[2]), env=env, text=True)
assert version.startswith("ripgrep "), version
PY
  RH_HOME="$rh_home" HOME="$home_dir" \
    "$ROOT/scripts/inject-rule.sh" off codex "$tool_mount" "codex.$codex_yolo" >/dev/null
done

# Native Claude install: no rg in the login PATH, but the claude binary serves ripgrep. Claude's
# Grep/Glob then use the session rg shim, which searches on the project host. A claude without an
# embedded ripgrep gets no rg shim and keeps its own search.
claude_tool_bin="$tmp/claude tools"
mkdir -p "$claude_tool_bin"
for claude_dep in bash sh dirname mkdir chmod sed tr awk cat rm cp git python3 grep cksum base64; do
  ln -s "$(command -v "$claude_dep")" "$claude_tool_bin/$claude_dep"
done
cp "$codex_tool_bin/ssh" "$claude_tool_bin/ssh"
for claude_variant in native plain; do
  rm -f "$claude_tool_bin/claude"
  if [ "$claude_variant" = plain ]; then
    printf '#!/bin/sh\nprintf "2.0.0 (Claude Code)\\n"\n' > "$claude_tool_bin/claude"
    chmod +x "$claude_tool_bin/claude"
  elif [ -n "$rg_real" ]; then
    ln -s "$rg_real" "$claude_tool_bin/claude"
  else
    printf '#!/bin/sh\nprintf "ripgrep fixture\\n"\n' > "$claude_tool_bin/claude"
    chmod +x "$claude_tool_bin/claude"
  fi
  PATH="$claude_tool_bin" RH_HOME="$rh_home" HOME="$home_dir" \
    "$ROOT/scripts/inject-rule.sh" on claude "$tool_proj" project-host "$tool_mount" 0 \
      "$router_tmp/shim_ssh_config" "claude.$claude_variant" > "$tmp/claude-tools.out"
  claude_tool_sd="$rh_home/.sessions/$(printf '%s' "$tool_mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_').claude.$claude_variant"
  python3 - "$tmp/claude-tools.out" "$tool_mount" "$claude_tool_sd/bin" "$claude_tool_bin" "$claude_variant" "$rg_real" <<'PY'
import os
import shlex
import subprocess
import sys

out, mount, session_bin, tool_bin, variant, rg_real = sys.argv[1:]
lines = dict(line.rstrip("\n").split("=", 1) for line in open(out, encoding="utf-8"))
assert lines["RH_STATUS"] == "INJECTED"
launch_env = shlex.split(lines["RH_LAUNCH_ENV"])
env = os.environ.copy()
env["PATH"] = session_bin + ":" + tool_bin
status = subprocess.check_output(["git", "status", "--porcelain"], cwd=mount, env=env, text=True)
assert "?? src/new.txt" in status and "mount-only" not in status, status
if variant == "plain":
    assert not os.path.exists(os.path.join(session_bin, "rg")), "rg shim without an rg-capable claude"
    assert "USE_BUILTIN_RIPGREP=0" not in launch_env, launch_env
    sys.exit(0)
assert os.access(os.path.join(session_bin, "rg"), os.X_OK), "native claude rg did not get a shim"
assert "USE_BUILTIN_RIPGREP=0" in launch_env, launch_env
if rg_real:
    # The same calls Claude's Grep and Glob make, relative to the project directory.
    found = subprocess.check_output(["rg", "-l", "--null", "hello", "."], cwd=mount, env=env)
    assert found == b"./src/a.txt\0", found
    files = subprocess.check_output(["rg", "--files", "--null", "--glob", "**/*.txt", "."],
                                    cwd=mount, env=env).split(b"\0")
    assert b"./src/new.txt" in files and b"./src/mount-only.txt" not in files, files
PY
  RH_HOME="$rh_home" HOME="$home_dir" \
    "$ROOT/scripts/inject-rule.sh" off claude "$tool_mount" "claude.$claude_variant" >/dev/null
done

RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on claude "$tmp/code" laptop "$tmp/mount-claude" 0 "$basic_ssh_cfg" > "$tmp/inject-claude.out"
assert_grep "$tmp/inject-claude.out" "RH_LAUNCH_FLAGS=--append-system-prompt-file '" "inject claude flag quoted"
assert_grep "$tmp/inject-claude.out" "--settings '" "inject claude session settings"
assert_grep "$tmp/inject-claude.out" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0" "inject claude disables experimental agent teams"
claude_session_key="$(printf '%s' "$tmp/mount-claude" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
claude_settings="$rh_home/.sessions/$claude_session_key/claude-settings.json"
python3 - "$claude_settings" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
hook = settings["hooks"]["PreToolUse"][0]
assert hook["matcher"] == "Bash|Agent"
assert "route-command.py" in hook["hooks"][0]["command"]
assert "EnterWorktree" in settings["permissions"]["deny"]
assert "ExitWorktree" in settings["permissions"]["deny"]
worktree_hook = settings["hooks"]["WorktreeCreate"][0]["hooks"][0]
assert worktree_hook["type"] == "command"
assert "deny-worktree" in worktree_hook["command"]
PY
claude_worktree_blocker="$rh_home/.sessions/$claude_session_key/bin/deny-worktree"
[ -x "$claude_worktree_blocker" ] || fail "claude worktree blocker missing"
if "$claude_worktree_blocker" >/dev/null 2>"$tmp/claude-worktree.err"; then
  fail "claude worktree blocker exited successfully"
fi
assert_grep "$tmp/claude-worktree.err" "separate remote-harness session" "claude worktree blocker guidance"
claude_rule="$rh_home/.sessions/$claude_session_key/rule.md"
assert_grep "$claude_rule" "Ordinary and nested subagents work" "claude rule documents supported subagents"
assert_grep "$claude_rule" "Do not use Agent Teams" "claude rule documents team boundary"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off claude "$tmp/mount-claude" >/dev/null
missing_cfg_out=$(RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on codex "$tmp/code" laptop "$tmp/mount-no-config" 0 || true)
assert_grep <(printf '%s\n' "$missing_cfg_out") "RH_STATUS=ERROR" "strict codex inject requires ssh config"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on opencode "$tmp/code" laptop "$tmp/mount-opencode" 1 "$basic_ssh_cfg" > "$tmp/inject-opencode.out"
assert_grep "$tmp/inject-opencode.out" "OPENCODE_CONFIG='" "inject opencode env quoted"
assert_grep "$tmp/inject-opencode.out" "RH_READY_FILE=" "inject opencode exposes a plugin readiness marker"
opencode_session_key="$(printf '%s' "$tmp/mount-opencode" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
opencode_session_dir="$rh_home/.sessions/$opencode_session_key"
opencode_plugin="$opencode_session_dir/plugins/remote-harness.js"
opencode_ready="$opencode_session_dir/opencode-plugin.ready"
[ -f "$opencode_plugin" ] || fail "inject opencode routing plugin missing"
[ -x "$opencode_session_dir/bin/rh-run" ] || fail "inject opencode session runner missing"
python3 - "$opencode_session_dir/opencode.json" "$opencode_plugin" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["plugin"] == [sys.argv[2]]
PY
mkdir -p "$tmp/mount-opencode/packages/api"
node --input-type=module - "$opencode_plugin" "$tmp/mount-opencode" "$tmp/opencode-plugin.json" <<'JS'
import fs from "node:fs"
import { pathToFileURL } from "node:url"

const pluginPath = process.argv[2]
const mountRoot = process.argv[3]
const outputPath = process.argv[4]
const module = await import(pathToFileURL(pluginPath).href)
const factory = Object.values(module).find((value) => typeof value === "function")
if (!factory) throw new Error("generated opencode plugin exports no function")
const hooks = await factory({ directory: mountRoot })
const output = { args: { command: "printf opencode-routed", workdir: "packages/api", timeout: 3210 } }
await hooks["tool.execute.before"]({ tool: "bash", sessionID: "test", callID: "call" }, output)
let outsideDenied = false
try {
  await hooks["tool.execute.before"](
    { tool: "bash", sessionID: "test", callID: "outside" },
    { args: { command: "uname -a", workdir: "../outside" } },
  )
} catch {
  outsideDenied = true
}
fs.writeFileSync(outputPath, JSON.stringify({ output, outsideDenied }))
JS
[ -s "$opencode_ready" ] || fail "opencode routing plugin did not write its readiness marker"
python3 - "$tmp/opencode-plugin.json" "$opencode_session_dir/bin/rh-run" "$tmp/mount-opencode" <<'PY'
import base64
import json
import shlex
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
args = payload["output"]["args"]
argv = shlex.split(args["command"])
assert argv[0] == sys.argv[2]
assert base64.b64decode(argv[1]).decode() == "packages/api"
assert base64.b64decode(argv[2]).decode() == "printf opencode-routed"
assert args["workdir"] == sys.argv[3]
assert args["timeout"] == 3210
assert payload["outsideDenied"] is True
PY
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off opencode "$tmp/mount-opencode" >/dev/null
missing_opencode_cfg=$(RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on opencode "$tmp/code" laptop "$tmp/mount-opencode-no-config" 0 || true)
assert_grep <(printf '%s\n' "$missing_opencode_cfg") "RH_STATUS=ERROR" "strict opencode inject requires ssh config"
assert_grep "$ROOT/scripts/laptop-setup.sh" "opencode routing plugin failed to load" "laptop setup fails closed when the opencode plugin is unavailable"

cat > "$tmp/bin/sudo" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/service" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/sshd" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$tmp/bin/sudo" "$tmp/bin/systemctl" "$tmp/bin/service" "$tmp/bin/sshd"
TEST_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test"
laptop_setup() {  # home args...: laptop-setup.sh with the fake bin PATH, the test key and --yes
  HOME="$1" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" bash "$ROOT/scripts/laptop-setup.sh" \
    --pubkey "$TEST_PUBKEY" --box-alias laptop "${@:2}" --yes
}
reverse_session() {  # home port project args...: a full codex reverse session against the fake box
  laptop_setup "$1" --host example.com --port "$2" --via "ssh user@example.com" \
    --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config --remote-mountpoint /tmp/rh-remote \
    --project-dir "$3" --launch codex "${@:4}"
}
setup_home="$tmp/setup-home"
mkdir -p "$setup_home"
laptop_setup "$setup_home" --host example.com --port 32022 \
  --via "ssh -J jumpbox -i /tmp/key user@example.com" --setup-only > "$tmp/setup-only.out"
setup_cfg="$(find "$setup_home/.remote-harness/.sessions" -name ssh_config -print -quit 2>/dev/null)"
[ -n "$setup_cfg" ] || fail "setup-only session ssh config missing"
assert_grep "$setup_cfg" "Host example.com-remote-harness" "setup-only managed alias"
assert_grep "$setup_cfg" "    HostName example.com" "setup-only hostname"
assert_grep "$setup_cfg" "    User user" "setup-only user"
assert_grep "$setup_cfg" "    IdentityFile /tmp/key" "setup-only identity"
assert_grep "$setup_cfg" "    ProxyJump jumpbox" "setup-only proxyjump"
assert_grep "$setup_cfg" "    RemoteForward 32022 127.0.0.1:22" "setup-only remote forward"
assert_grep "$setup_cfg" "UserKnownHostsFile $setup_home/.remote-harness/.sessions/" "setup-only known_hosts under remote-harness"
assert_grep "$setup_cfg" "/runtime/known_hosts" "setup-only separates mutable SSH runtime from config"
assert_grep "$setup_cfg" "    ControlMaster no" "setup-only disables multiplexing"
assert_grep "$setup_cfg" "    ForwardAgent no" "setup-only disables SSH agent forwarding"
[ ! -e "$setup_home/.ssh/config" ] || fail "laptop-setup wrote ~/.ssh/config"
[ ! -e "$setup_home/.ssh/authorized_keys" ] || fail "laptop-setup wrote ~/.ssh/authorized_keys"
[ -z "$(find "$setup_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "laptop-setup created config.rh-bak"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ] && [ "${2:-}" = "mybox" ]; then
  printf 'user mybox\nhostname 203.0.113.7\nport 22\nidentityfile ~/.ssh/id_ed25519\n'
  exit 0
fi
if [ "${1:-}" = "-G" ] && [ "${2:-}" = "iapbox" ]; then
  printf 'user dev\nhostname iapbox\nport 22\nidentitiesonly yes\nidentityfile ~/.ssh/google_compute_engine\nproxyjump none\n'
  printf 'proxycommand gcloud compute start-iap-tunnel iapbox %%p --listen-on-stdin --zone=zone-a --project=demo\n'
  exit 0
fi
exit 0
EOS
chmod +x "$tmp/bin/ssh"
alias_home="$tmp/alias-home"
mkdir -p "$alias_home/.ssh"
cat > "$alias_home/.ssh/config" <<'EOF'
Host mybox
    HostName 203.0.113.7
    User mybox
    RemoteForward 22022 127.0.0.1:22
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    TCPKeepAlive yes
EOF
laptop_setup "$alias_home" --host mybox --port 22022 --via "mybox" --setup-only > "$tmp/setup-alias.out"
alias_cfg="$(find "$alias_home/.remote-harness/.sessions" -name ssh_config -print -quit 2>/dev/null)"
[ -n "$alias_cfg" ] || fail "alias setup-only session ssh config missing"
assert_grep "$alias_cfg" "Host mybox-remote-harness" "dedicated harness alias"
assert_grep "$alias_cfg" "    HostName 203.0.113.7" "dedicated alias resolved hostname"
assert_grep "$alias_cfg" "    RemoteForward 22022 127.0.0.1:22" "dedicated alias remote forward"
assert_grep "$alias_cfg" "Include $alias_home/.ssh/config" "dedicated alias reads user config without editing it"
assert_grep "$alias_cfg" "/runtime/known_hosts" "dedicated alias separates mutable SSH runtime from config"
refute_grep "$alias_home/.ssh/config" "mybox-remote-harness" "laptop-setup wrote dedicated alias to user ~/.ssh/config"
[ -z "$(find "$alias_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "alias setup created config.rh-bak"

iap_home="$tmp/iap-home"; mkdir -p "$iap_home/.ssh"; : > "$iap_home/.ssh/google_compute_engine"
printf 'Host iapbox\n    HostName iapbox\n' > "$iap_home/.ssh/config"
laptop_setup "$iap_home" --host iapbox --port 22023 --via iapbox --setup-only > "$tmp/setup-iap.out" 2>&1
iap_cfg="$(find "$iap_home/.remote-harness/.sessions" -name ssh_config -print -quit)"
assert_grep "$iap_cfg" "    ProxyCommand gcloud compute start-iap-tunnel iapbox %p --listen-on-stdin --zone=zone-a --project=demo" "session alias keeps the user's ProxyCommand"
assert_grep "$iap_cfg" "    IdentitiesOnly yes" "session alias keeps IdentitiesOnly"
assert_grep "$iap_cfg" "    IdentityFile $iap_home/.ssh/google_compute_engine" "session alias expands ~/ identity paths"
refute_grep "$tmp/setup-iap.out" "could not resolve Host" "ssh -G alias resolution reported a spurious failure"

if HOME="$tmp/unsafe-rh" RH_HOME=/ bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-root.err"; then
  fail "manage accepted RH_HOME=/"
fi
assert_grep "$tmp/manage-rh-root.err" "RH_HOME" "manage rejects root RH_HOME"
if HOME="$tmp/unsafe-rh" RH_HOME="$tmp/unsafe-rh" bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-home.err"; then
  fail "manage accepted RH_HOME=\$HOME"
fi
assert_grep "$tmp/manage-rh-home.err" "RH_HOME" "manage rejects HOME RH_HOME"
if HOME="$tmp/unsafe-rh" RH_HOME="../remote-harness" bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-rel.err"; then
  fail "manage accepted relative traversal RH_HOME"
fi
assert_grep "$tmp/manage-rh-rel.err" "RH_HOME" "manage rejects relative RH_HOME"

install_home="$tmp/install-home"
codex_home="$tmp/codex-home"
rh_install="$tmp/.remote-harness"
mkdir -p "$install_home" "$codex_home"
HOME="$install_home" CODEX_HOME="$codex_home" RH_HOME="$rh_install" \
  bash "$ROOT/manage.sh" --dev codex > "$tmp/manage-dev-codex.out"
[ -L "$codex_home/skills/remote-harness" ] || fail "dev codex install did not symlink skill dir"
assert_eq "dev codex link target" "$(readlink "$codex_home/skills/remote-harness")" "$ROOT"
[ -f "$codex_home/skills/remote-harness/SKILL.md" ] || fail "dev codex skill link missing SKILL.md"
HOME="$install_home" CODEX_HOME="$codex_home" RH_HOME="$rh_install" \
  bash "$ROOT/manage.sh" codex > "$tmp/manage-copy-codex.out"
[ -d "$codex_home/skills/remote-harness" ] || fail "copy codex install missing skill dir"
[ ! -L "$codex_home/skills/remote-harness" ] || fail "copy codex install left skill dir symlink"
[ -f "$codex_home/skills/remote-harness/SKILL.md" ] || fail "copy codex install missing SKILL.md"
[ ! -L "$codex_home/skills/remote-harness/SKILL.md" ] || fail "copy codex install left SKILL.md symlink"

if laptop_setup "$tmp/launch-home" --host example.com --port 32022 --via "ssh user@example.com" \
    --launch "codex --flag" --setup-only \
    >"$tmp/laptop-bad-launch.out" 2>"$tmp/laptop-bad-launch.err"; then
  fail "laptop-setup accepted extra --launch words"
fi
assert_grep "$tmp/laptop-bad-launch.err" "unsupported --launch" "laptop launch validation"
if HOME="$tmp/local-launch-home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/local-setup.sh" --via "ssh user@example.com" --remote-path /srv/app \
    --launch "codex --flag" --yes >"$tmp/local-bad-launch.out" 2>"$tmp/local-bad-launch.err"; then
  fail "remote-only local-setup launched locally"
fi
assert_grep "$tmp/local-bad-launch.err" "remote-only" "local setup is permanently disabled"

simple_dir="$tmp/simple-scripts"
simple_project="$tmp/simple project"
mkdir -p "$simple_dir" "$simple_project"
simple_project_real="$(cd "$simple_project" && pwd -P)"
cp "$ROOT/scripts/_common.sh" "$ROOT/scripts/simple-laptop-setup.sh" "$simple_dir/"
cat > "$simple_dir/laptop-setup.sh" <<'EOS'
#!/usr/bin/env bash
i=0
for arg in "$@"; do
  printf 'ARG_%s=%s\n' "$i" "$arg"
  i=$((i + 1))
done > "${SIMPLE_LAPTOP_ARGS:?}"
EOS
chmod +x "$simple_dir/laptop-setup.sh"
cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
remote_cmd="${!#}"
case "$remote_cmd" in
  *'session-reaper.sh'*'config-used'*|*'session-reaper.sh'*'release-config'*) printf 'USED=0\n'; exit 0;;
  *'session-reaper.sh'*'release'*) printf 'STATUS=released\n'; exit 0;;
  *'setup-tunnel.sh'*)
    [ -n "${SIMPLE_REMOTE_CMD:-}" ] && printf '%s\n' "$remote_cmd" > "$SIMPLE_REMOTE_CMD"
    printf 'STATUS=configured\nALIAS=tester\nPORT=24002\nCONFIG=/home/box/.remote-harness/.sessions/simple-tester/ssh_config\nPUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISimple remote-harness@test\n'
    exit 0
    ;;
esac
exit 1
EOS
chmod +x "$tmp/bin/ssh"
HOME="$tmp/simple-home" PATH="$tmp/bin:$PATH" RH_COMMON="$simple_dir/_common.sh" \
  RH_SIMPLE_CACHE="$tmp/simple-cache.env" \
  SIMPLE_REMOTE_CMD="$tmp/simple-remote.cmd" \
  SIMPLE_LAPTOP_ARGS="$tmp/simple-laptop.args" \
  bash "$simple_dir/simple-laptop-setup.sh" \
    --via "ssh -p 2222 bytepilot@42.121.2.119" \
    --namespace tester \
    --project-dir "$simple_project" \
    --remote-mountpoint /tmp/rh-simple-remote \
    --launch codex \
    --yes > "$tmp/simple-laptop.out"
assert_grep "$tmp/simple-laptop.out" "Remote alias 'tester' prepared on port 24002" "simple setup remote alias"
assert_grep "$tmp/simple-laptop.out" "[1/7] ✓ Preparing remote tunnel alias" "simple setup opens the seven-step sequence"
assert_grep "$tmp/simple-remote.cmd" "--config" "simple remote setup uses temp ssh config"
assert_grep "$tmp/simple-remote.cmd" "--alias 'tester'" "simple remote setup uses short alias"
assert_grep "$tmp/simple-remote.cmd" "--gen-key" "simple remote setup generates remote-harness key"
assert_grep "$tmp/simple-laptop.args" "ARG_0=--host" "simple handoff starts with host flag"
assert_grep "$tmp/simple-laptop.args" "ARG_1=42.121.2.119" "simple handoff host"
assert_grep "$tmp/simple-laptop.args" "ARG_5=-p 2222 bytepilot@42.121.2.119" "simple handoff via strips leading ssh"
assert_grep "$tmp/simple-laptop.args" "ARG_6=--box-alias" "simple handoff box alias flag"
assert_grep "$tmp/simple-laptop.args" "ARG_7=tester" "simple handoff box alias"
assert_grep "$tmp/simple-laptop.args" "ARG_8=--box-ssh-config" "simple handoff box ssh config flag"
assert_grep "$tmp/simple-laptop.args" "ARG_9=/home/box/.remote-harness/.sessions/simple-tester/ssh_config" "simple handoff box ssh config"
assert_grep "$tmp/simple-laptop.args" "ARG_11=$simple_project_real" "simple handoff project dir"
assert_grep "$tmp/simple-laptop.args" "ARG_13=codex" "simple handoff launch"
assert_grep "$tmp/simple-laptop.args" "ARG_15=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISimple remote-harness@test" "simple handoff pubkey"
assert_grep "$tmp/simple-laptop.args" "ARG_17=/tmp/rh-simple-remote" "simple handoff mountpoint"
assert_grep "$tmp/simple-laptop.args" "ARG_18=--approval" "simple handoff approval flag"
assert_grep "$tmp/simple-laptop.args" "ARG_19=auto" "simple handoff approval defaults to auto under --yes"
assert_grep "$tmp/simple-cache.env" "LAST_VIA=-p 2222 bytepilot@42.121.2.119" "simple cache via"
if grep -q '^LAST_NAMESPACE=' "$tmp/simple-cache.env"; then
  fail "simple cache should not persist the hidden namespace override"
fi
assert_grep "$tmp/simple-cache.env" "LAST_PROJECT_DIR=$simple_project_real" "simple cache project"
assert_grep "$tmp/simple-cache.env" "LAST_REMOTE_MOUNTPOINT=/tmp/rh-simple-remote" "simple cache mountpoint"
assert_grep "$tmp/simple-cache.env" "LAST_LAUNCH=codex" "simple cache launch"
assert_grep "$tmp/simple-cache.env" "LAST_APPROVAL=auto" "simple cache approval"
# A remembered mountpoint is the default only for the project it was chosen for.
simple_run() {  # cache args...: rerun the wizard under --yes; the handoff lands in simple-laptop.args
  : > "$tmp/simple-laptop.args"
  HOME="$tmp/simple-home" PATH="$tmp/bin:$PATH" RH_COMMON="$simple_dir/_common.sh" RH_SIMPLE_CACHE="$1" \
    SIMPLE_LAPTOP_ARGS="$tmp/simple-laptop.args" bash "$simple_dir/simple-laptop-setup.sh" \
    --via "ssh -p 2222 bytepilot@42.121.2.119" --namespace tester --launch codex --yes "${@:2}" \
    </dev/null >/dev/null 2>&1 || true
}
handoff_after() {  # flag: the value the wizard handed to laptop-setup.sh after that flag
  awk -F= -v f="$1" 'prev {print substr($0, index($0, "=") + 1); exit} $2==f {prev=1}' "$tmp/simple-laptop.args"
}
simple_rerun() {  # $1 = project dir; prints the handed-off arguments
  simple_run "$tmp/simple-cache.env" --project-dir "$1"
  cat "$tmp/simple-laptop.args"
}
assert_grep <(simple_rerun "$simple_project") "=/tmp/rh-simple-remote" "same project reuses its remembered mountpoint"
mkdir -p "$tmp/simple-other-project"
case "$(simple_rerun "$tmp/simple-other-project")" in *rh-simple-remote*) fail "another project inherited the remembered mountpoint";; esac
sed -i.bak '/^LAST_MOUNT_PROJECT=/d; s#^LAST_REMOTE_MOUNTPOINT=.*#LAST_REMOTE_MOUNTPOINT=/tmp/rh-simple-remote#' "$tmp/simple-cache.env"
case "$(simple_rerun "$simple_project")" in *rh-simple-remote*) fail "a cache without the mount's project still forced its mountpoint";; esac
assert_grep "$ROOT/scripts/simple-laptop-setup.sh" 'PROJECT_DIR="$(choose_project_dir "$cached_project" 1)"' "simple cached project prompts for confirmation"
assert_grep "$ROOT/scripts/simple-laptop-setup.sh" 'if [ -z "$APPROVAL" ]; then' "explicit approval has a no-reprompt branch"
# An explicit local sshd choice is handed off last and remembered for later runs.
simple_sshd_run() {  # extra args...; prints the value handed off after --local-sshd
  simple_run "$tmp/simple-sshd-cache.env" --project-dir "$simple_project" "$@"
  handoff_after --local-sshd
}
assert_eq "explicit user-mode sshd handed off" "$(simple_sshd_run --local-sshd user)" "user"
assert_grep "$tmp/simple-sshd-cache.env" "LAST_LOCAL_SSHD=user" "explicit local sshd choice remembered"
assert_eq "remembered user-mode sshd reused" "$(simple_sshd_run)" "user"
assert_eq "RH_LOCAL_SSHD overrides the remembered choice" "$(RH_LOCAL_SSHD=system simple_sshd_run)" "system"
# An explicit approval mode is handed off unchanged and remembered as the next default.
simple_sshd_run --yolo >/dev/null
assert_eq "explicit yolo handed off" "$(handoff_after --approval)" "yolo"
simple_sshd_run --approval normal >/dev/null
assert_eq "explicit normal approval handed off" "$(handoff_after --approval)" "normal"
simple_sshd_run >/dev/null
assert_eq "remembered approval mode reused" "$(handoff_after --approval)" "normal"

if bash "$ROOT/scripts/simple-local-setup.sh" --launch codex \
    >"$tmp/simple-local.out" 2>"$tmp/simple-local.err"; then
  fail "remote-only simple-local-setup launched locally"
fi
assert_grep "$tmp/simple-local.err" "remote-only" "simple local setup is permanently disabled"

dispatch_dir="$tmp/dispatch-scripts"
mkdir -p "$dispatch_dir"
cp "$ROOT/scripts/_common.sh" "$ROOT/scripts/simple-dispatch.sh" "$dispatch_dir/"
cat > "$dispatch_dir/simple-local-setup.sh" <<'EOS'
#!/usr/bin/env bash
printf 'FORWARD_ARGS=%s\n' "$*" > "${DISPATCH_MARKER:?}"
EOS
cat > "$dispatch_dir/simple-laptop-setup.sh" <<'EOS'
#!/usr/bin/env bash
printf 'REVERSE_ARGS=%s\n' "$*" > "${DISPATCH_MARKER:?}"
EOS
chmod +x "$dispatch_dir/simple-dispatch.sh" "$dispatch_dir/simple-local-setup.sh" "$dispatch_dir/simple-laptop-setup.sh"
if HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  DISPATCH_MARKER="$tmp/dispatch-forward.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --mode "本地开发远程项目" --launch codex --yolo \
    >"$tmp/dispatch-forward.stdout" 2>"$tmp/dispatch-forward.stderr"; then
  fail "remote-only dispatcher accepted forward mode"
fi
assert_grep "$tmp/dispatch-forward.stderr" "remote-only" "dispatch rejects local-agent forward mode"
[ ! -e "$tmp/dispatch-forward.out" ] || fail "forward dispatcher launched a local-agent helper"
HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  DISPATCH_MARKER="$tmp/dispatch-cached.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --launch codex --yolo
assert_grep "$tmp/dispatch-cached.out" "REVERSE_ARGS=--launch codex" "dispatch defaults to reverse"
assert_grep "$tmp/dispatch-cached.out" "--approval yolo" "dispatch passes --yolo on as the yolo approval"
# A flag without its value is a usage error, also after _common.sh is sourced.
na_rc=0
RH_COMMON="$dispatch_dir/_common.sh" bash "$dispatch_dir/simple-dispatch.sh" --launch >/dev/null 2>&1 || na_rc=$?
assert_eq "a flag without a value stops the dispatcher" "$na_rc" 2
assert_eq "kv_value returns the first value" \
  "$(bash -c '. "$1"; printf "ERROR=x\nERROR=a=b\n" | kv_value ERROR' _ "$ROOT/scripts/_common.sh")" "x"
assert_eq "kv_value keeps '=' inside a value" \
  "$(bash -c '. "$1"; printf "ERROR=a=b\n" | kv_value ERROR' _ "$ROOT/scripts/_common.sh")" "a=b"
HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  DISPATCH_MARKER="$tmp/dispatch-reverse.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --mode "远程开发本地" --launch codex --source-via sourcebox
assert_grep "$tmp/dispatch-reverse.out" "REVERSE_ARGS=--launch codex --via sourcebox" "dispatch passes source via only to reverse"
refute_grep "$ROOT/scripts/simple-dispatch.sh" 'exec bash "$SCRIPT_DIR/simple-local-setup.sh"' "remote-only dispatcher still contains a local-agent launch path"

bash "$ROOT/tests/bootstrap.sh"
assert_grep "$ROOT/scripts/simple-dispatch.sh" "--source-via" "simple dispatcher accepts bootstrap source"
assert_grep "$ROOT/SKILL.md" "simple-bootstrap.sh" "skill uses unified simple bootstrap"
assert_grep "$ROOT/SKILL.md" "docs/claude-multi-agent.md" "skill routes Claude multi-agent questions"
assert_grep "$ROOT/README.md" "git clone https://github.com/specialpointcentral/remote-harness.git" "README installs maintained fork"
refute_grep "$ROOT/README.md" "git clone https://github.com/chenjh16/remote-harness.git" "README manual install still clones upstream instead of the maintained fork"
assert_grep "$ROOT/SKILL.md" "remote-only" "skill declares remote-only topology"
assert_grep "$ROOT/SKILL.md" "printf '%s' \"\$p\${d:+ [\$d]}: \" >/dev/tty" "skill fetch prompt is zsh-compatible"
assert_grep "$ROOT/SKILL.md" "IFS= read -r h </dev/tty || exit 2" "skill aborts when tty prompt cannot read"
if grep -F "read -r -p" "$ROOT/SKILL.md" "$ROOT/SKILL.cn.md" "$ROOT/docs/simple-flow.cn.md" >/dev/null; then
  fail "fetch command templates must not use read -p; zsh treats -p as coprocess"
fi
assert_grep "$ROOT/SKILL.md" "--mode reverse" "skill documents reverse mode arg"
if grep -F -- "--mode forward" "$ROOT/SKILL.md" "$ROOT/SKILL.cn.md" >/dev/null; then
  fail "remote-only skill still documents a forward launch command"
fi
# The skill text is model input, so its explicit local-agent prohibition needs a guard as well as
# the behavioral launch checks. Permit wrapping of the English instruction and check both entries.
if ! tr '\n' ' ' < "$ROOT/SKILL.md" |
    grep -E 'never launch an[[:space:]]+agent on the local project host' >/dev/null; then
  fail "English skill must explicitly forbid launching an agent on the local project host"
fi
assert_grep "$ROOT/SKILL.cn.md" "绝不在本机项目主机启动 Agent" "Chinese skill forbids local agent launch"
# Executable examples and behavioral launch/approval/privacy tests cover the remaining contract;
# bilingual document presence is checked below, without pinning unrelated prose.

install_home="$tmp/install-home"
mkdir -p "$install_home"
HOME="$install_home" CODEX_HOME="$install_home/.codex" RH_HOME="$install_home/.remote-harness" \
  bash "$ROOT/manage.sh" codex > "$tmp/manage-install.out"
[ -f "$install_home/.remote-harness/docs/complete-flow.md" ] || fail "manage install did not copy shared docs"
[ -f "$install_home/.remote-harness/docs/claude-multi-agent.md" ] || fail "manage install did not copy Claude multi-agent docs"
[ -f "$install_home/.remote-harness/docs/claude-multi-agent.cn.md" ] || fail "manage install did not copy Chinese Claude multi-agent docs"
[ -f "$install_home/.codex/skills/remote-harness/docs/complete-flow.md" ] || fail "codex copy install did not include docs"
[ -f "$install_home/.codex/skills/remote-harness/docs/claude-multi-agent.md" ] || fail "codex copy install did not include Claude multi-agent docs"
[ -f "$install_home/.codex/skills/remote-harness/SKILL.cn.md" ] || fail "codex copy install did not include SKILL.cn.md"
[ -x "$install_home/.remote-harness/scripts/simple-bootstrap.sh" ] || fail "manage install did not install executable simple-bootstrap.sh"
[ -x "$install_home/.remote-harness/scripts/route-command.py" ] || fail "manage install did not install executable route-command.py"
[ -x "$install_home/.remote-harness/scripts/run-on-project-host.sh" ] || fail "manage install did not install project-host runner"
[ -x "$install_home/.remote-harness/scripts/project-host-gateway.sh" ] || fail "manage install did not install forced project-host gateway"
assert_grep "$ROOT/scripts/laptop-setup.sh" 'command="%s"' "authorized key binds a forced command"
assert_grep "$ROOT/scripts/laptop-setup.sh" "project-host-gateway.sh" "authorized key uses project-host gateway"
assert_grep "$ROOT/scripts/check-tunnel.sh" "remote-harness-health" "tunnel check uses the gateway health protocol"

suggest_user="$(id -un)"
SSH_CONNECTION='198.51.100.10 55555 203.0.113.7 2222' \
  bash "$ROOT/scripts/suggest-via.sh" > "$tmp/suggest-via.out"
assert_grep "$tmp/suggest-via.out" "STATUS=ok" "suggest-via ok from SSH_CONNECTION"
assert_grep "$tmp/suggest-via.out" "VIA=-p 2222 $suggest_user@203.0.113.7" "suggest-via uses server address and port"
assert_grep "$tmp/suggest-via.out" "SOURCE=ssh_connection" "suggest-via records source"
refute_grep "$tmp/suggest-via.out" "198.51.100.10" "suggest-via leaked client/local SSH_CONNECTION field"
SSH_CONNECTION='198.51.100.10 55555 203.0.113.7 22' \
  bash "$ROOT/scripts/suggest-via.sh" > "$tmp/suggest-via-22.out"
assert_grep "$tmp/suggest-via-22.out" "VIA=$suggest_user@203.0.113.7" "suggest-via omits default port 22"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
[ -n "${SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$SSH_LOG"
remote_cmd="${!#}"
for arg in "$@"; do
  case "$arg" in
    *'session-reaper.sh'*'config-used'*|*'session-reaper.sh'*'release-config'*) printf 'USED=0\n'; exit 0;;
    *'session-reaper.sh'*'release'*) printf 'STATUS=released\n'; exit 0;;
    -N)
      printf 'open\n' > "${TUNNEL_STATE:?}"
      exec -a "ssh $*" sleep 30
      ;;
  esac
done
case "$remote_cmd" in
  *'check-tunnel.sh'*) printf 'SSH=up\nLAPTOP_HOSTNAME=other-laptop\nLAPTOP_USER=other-user\n'; exit 0;;
  *'setup-tunnel.sh'*) printf '%s\n' "$remote_cmd" > "${SETUP_TUNNEL_LOG:?}"; exit 0;;
  *"grep -qx '32026'"*) exit 0;;
  *"grep -qx '32027'"*)
    [ "$(cat "${TUNNEL_STATE:?}" 2>/dev/null || true)" = open ] && exit 0 || exit 1
    ;;
  *'ss -tlnH'*) printf '32026\n'; exit 0;;  # the bare port list find_next_remote_port scans
  *'mount-project.sh'*) printf 'STATUS=mounted\nMOUNTPOINT=/tmp/rh-remote\n'; exit 0;;
  *'inject-rule.sh'*) printf 'RH_STATUS=ERROR\n'; exit 0;;
esac
exit 0
EOS
chmod +x "$tmp/bin/ssh"
conflict_home="$tmp/conflict-home"
conflict_project="$tmp/conflict-project"
conflict_state="$tmp/tunnel-conflict.state"
conflict_setup_log="$tmp/tunnel-conflict.setup.log"
conflict_ssh_log="$tmp/tunnel-conflict.ssh.log"
mkdir -p "$conflict_home" "$conflict_project"
if TUNNEL_STATE="$conflict_state" SETUP_TUNNEL_LOG="$conflict_setup_log" SSH_LOG="$conflict_ssh_log" \
  reverse_session "$conflict_home" 32026 "$conflict_project" >"$tmp/tunnel-conflict.out" 2>"$tmp/tunnel-conflict.err"; then
  fail "laptop-setup continued after strict rule injection failed"
fi
assert_grep "$tmp/tunnel-conflict.err" "refusing to launch" "laptop setup fails closed"
assert_grep "$tmp/tunnel-conflict.out" "Remote port 32026 is already listening" "tunnel conflict detected"
assert_grep "$tmp/tunnel-conflict.out" "Switching this setup to remote port 32027" "tunnel conflict fallback"
assert_grep "$tmp/tunnel-conflict.out" "RemoteForward 32027" "local RemoteForward switched"
assert_grep "$conflict_setup_log" "--port '32027'" "remote alias switched"
assert_grep "$conflict_setup_log" "--user '$(id -un)'" "box alias login user forced to local id -un"
assert_grep "$tmp/tunnel-conflict.out" "Tunnel active — remote port 32027 is live" "tunnel active after fallback"
[ ! -e "$conflict_home/.ssh/config" ] || fail "full laptop flow wrote ~/.ssh/config"
[ -z "$(find "$conflict_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "full laptop flow created config.rh-bak"

ssh_log="$tmp/ssh-project.log"
cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
[ -n "${SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$SSH_LOG"
case " $* " in  # a multiplexing master request leaves a real socket behind, as OpenSSH would
  *" ControlMaster=yes "*)
    mux=$(printf '%s\n' "$@" | sed -n 's/^ControlPath=//p' | head -1)
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$mux"; exit 0;;
esac
# Run the interactive launch command in a fake project; SHELL=/bin/echo prints the agent command
# instead of starting it.
case " $* " in
  *" -tt "*)
    if [ -n "${LAUNCH_DIR:-}" ]; then
      eval "rcmd=\${$#}"
      SHELL=/bin/echo sh -c "${rcmd//\/tmp\/rh-remote/$LAUNCH_DIR}" > "$LAUNCH_DIR.out" 2>&1
    fi
    [ -z "${TT_EXIT:-}" ] || exit "$TT_EXIT";;
esac
for arg in "$@"; do
  case "$arg" in
    *'session-reaper.sh'*'config-used'*|*'session-reaper.sh'*'release-config'*)
      [ "${RESOURCE_USED:-0}" != error ] || exit 255
      # A remote shell that adds output and fails after the reaper already gave its verdict.
      [ "${RESOURCE_USED:-0}" != noisy ] || { printf 'login banner\nUSED=0\n'; exit 1; }
      printf 'USED=%s\n' "${RESOURCE_USED:-0}"; exit 0;;
    *'session-reaper.sh'*'release'*) printf 'STATUS=released\n'; exit 0;;
    -tt)
      if [ -n "${AUTH_KEYS_SNAPSHOT:-}" ] && [ -f "$HOME/.ssh/authorized_keys" ]; then
        cp "$HOME/.ssh/authorized_keys" "$AUTH_KEYS_SNAPSHOT"
        python3 - "$AUTH_KEYS_SNAPSHOT" <<'PY'
import os
import re
import subprocess
import sys
text = open(sys.argv[1], encoding='utf-8').read()
match = re.search(r'command="((?:\\.|[^"\\])*)"', text)
command = match.group(1).replace('\\\\', '\\').replace('\\"', '"')
env = os.environ.copy()
env['SSH_ORIGINAL_COMMAND'] = 'remote-harness-health'
result = subprocess.run(['sh', '-c', command], env=env, text=True, capture_output=True, check=True)
open(sys.argv[1] + '.health', 'w').write(result.stdout)
PY
      fi
      # User-mode sshd: reach the live session sshd with a real client, as the box's sshfs would.
      if [ -n "${USER_SSHD_PROBE:-}" ]; then
        ucfg=$(find "$HOME/.remote-harness/.sessions" -path '*/sshd/sshd_config' | head -1)
        cp "$ucfg" "$USER_SSHD_PROBE.cfg"
        cat "$HOME"/.remote-harness/.sessions/rev.*/ssh_config > "$USER_SSHD_PROBE.ssh_config"
        cat "$(dirname "$ucfg")/sshd.pid" > "$USER_SSHD_PROBE.pid"
        "$REAL_SSH" -F /dev/null -p "$(awk '$1=="Port"{print $2}' "$ucfg")" -i "$USER_SSHD_KEY" \
          -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          127.0.0.1 remote-harness-health > "$USER_SSHD_PROBE.health" 2> "$USER_SSHD_PROBE.err" || true
      fi
      ;;
    -N) printf 'unexpected ssh -N while reusable tunnel is up\n' >&2; exit 99;;
    *'check-tunnel.sh'*) printf 'SSH=up\n'; exit 0;;
    *'grep -qx'*) exit 0;;
    *'mount-project.sh'*)
      [ -z "${MOUNT_FAIL:-}" ] || { printf 'STATUS=failed\nERROR=read: Connection reset by peer\n'; exit 0; }
      printf 'STATUS=mounted\nMOUNTPOINT=/tmp/rh-remote\n'; exit 0;;
    *'inject-rule.sh'*) printf 'RH_STATUS=INJECTED\nRH_LAUNCH_ENV=\nRH_LAUNCH_FLAGS=\nRH_RESUME_ARGS=--continue\nRH_APPROVAL=auto\n'; exit 0;;
  esac
done
exit 0
EOS
chmod +x "$tmp/bin/ssh"
proj_home="$tmp/project dir 'home"
valid_project="$tmp/valid project"
created_project="$tmp/created project"
file_project="$tmp/not-a-dir"
auth_keys_snapshot="$tmp/authorized_keys.snapshot"
mkdir -p "$proj_home" "$valid_project"
printf 'x\n' > "$file_project"
launch_dir="$tmp/launch-project"
mkdir -p "$launch_dir/.git/refs/heads"
printf 'ref: refs/heads/main\n' > "$launch_dir/.git/HEAD"
printf '[branch "main"]\n\tremote = origin\n\tmerge = refs/heads/main\n' > "$launch_dir/.git/config"
project_launch() {  # output file; the caller's environment is passed through
  LAUNCH_DIR="$launch_dir" reverse_session "$proj_home" 32023 "$valid_project" > "$1"
}
SSH_LOG="$ssh_log" AUTH_KEYS_SNAPSHOT="$auth_keys_snapshot" project_launch "$tmp/project-valid.out"
assert_grep "$tmp/project-valid.out" "authorized_keys: temporarily authorized" "reverse authkey added"
assert_grep "$tmp/project-valid.out" "forced project-host gateway" "reverse authkey uses forced command gateway"
assert_grep "$tmp/project-valid.out" "Project dir (from skill)" "project-dir valid accepted"
assert_grep "$tmp/project-valid.out" "project host: git found" "launch preflight reports the project-host git"
assert_grep "$tmp/project-valid.out" "[2/6] ✓ Establishing the reverse tunnel" "connection steps report progress"
assert_grep "$tmp/project-valid.out" "Connecting the remote session" "launch announces the remote connection"
assert_grep "$launch_dir.out" "Remote session connected" "remote prelude reports the connected session"
assert_grep "$launch_dir.out" "Prewarmed project metadata" "remote prelude prewarms project metadata"
assert_grep "$launch_dir.out" "-lic codex" "remote prelude still execs the agent"
# The agent learns which terminal it draws on; values outside a safe charset are not sent.
SSH_LOG="$tmp/term-env.ssh.log" AUTH_KEYS_SNAPSHOT="$auth_keys_snapshot" TERM_PROGRAM=iTerm.app \
  TERM_PROGRAM_VERSION=3.5.10 LC_TERMINAL='iTerm2;touch x' COLORTERM=truecolor \
  project_launch "$tmp/term-env.out"
assert_grep "$tmp/term-env.ssh.log" "export TERM_PROGRAM='iTerm.app' TERM_PROGRAM_VERSION='3.5.10' COLORTERM='truecolor';" \
  "launch passes the terminal identity to the agent"
refute_grep "$tmp/term-env.ssh.log" "touch x" "launch drops a terminal variable with unsafe characters"
assert_grep "$ssh_log" "/bin/rh-run' Lg== dHJ1ZQ==" "remote prelude opens the routed-command master before the agent starts"
assert_grep "$tmp/project-valid.out" "[2/3] ✓ Waiting for sshfs to flush and exit" "exit cleanup reports progress steps"
assert_grep "$ssh_log" "ControlMaster=yes" "setup starts a multiplexing master"
assert_grep_e "$ssh_log" "ControlMaster=no -o ControlPath=/tmp/rh\.[^ ]+/m -n " "setup calls reuse the multiplexing master"
refute_grep_e "$ssh_log" "ControlPath=/tmp/rh\.[^ ]+/m -tt " "the interactive agent session must keep its own connection"
assert_grep_e "$ssh_log" "ControlPath=/tmp/rh\.[^ ]+/m -O exit" "cleanup stops the multiplexing master"
assert_grep_e "$tmp/project-valid.out" "project host: rg (found|not found)" "launch preflight reports rg"
assert_grep_e "$ssh_log" "inject-rule\.sh[^ ]* on [^ ]*codex[^ ]* .* [^ ]*auto[^ ]* " "setup passes the default auto approval to the injector"
assert_grep "$tmp/project-valid.out" "Approvals: codex automatic review" "setup reports the auto approval mode"
# An interactive ssh that lost its connection (exit 255) makes the next launch of the same remote,
# mountpoint and agent offer to continue, once.
refute_grep "$tmp/project-valid.out" "ended on a lost connection" "a first launch offered resume"
TT_EXIT=255 project_launch "$tmp/resume-lost.out"
assert_grep "$tmp/resume-lost.out" "Lost the connection to the remote codex session" "a dropped interactive ssh is reported"
project_launch "$tmp/resume-next.out"
assert_grep "$tmp/resume-next.out" "ended on a lost connection" "the launch after a dropped ssh offers resume"
assert_grep "$launch_dir.out" "-lic codex --continue" "an accepted resume continues the conversation"
[ -z "$(find "$proj_home/.remote-harness/.sessions/.resume" -type f 2>/dev/null)" ] \
  || fail "a local resume marker was not consumed by the launch that offered it"
! sh "$ROOT/scripts/run-on-project-host.sh" --find-tool rh-no-such-tool >/dev/null 2>&1 || fail "--find-tool reported a missing tool"
assert_grep "$tmp/project-valid.out" "Reusing existing reverse tunnel" "reuses live tunnel"
assert_grep "$ssh_log" "-tt -o ClearAllForwardings=yes" "phase5 forces remote tty"
assert_grep "$ROOT/scripts/laptop-setup.sh" "exec 3</dev/tty" "phase5 attaches stdin to controlling tty"
[ -f "$auth_keys_snapshot" ] || fail "did not capture the live forced-command authorized_keys entry"
assert_grep "$auth_keys_snapshot" 'from="127.0.0.1,::1",command="' "authorized key is loopback-scoped and forced"
assert_grep "$auth_keys_snapshot" '/project-host-gateway.sh' "authorized key invokes the project-host gateway"
assert_grep "$auth_keys_snapshot" ',no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty ssh-ed25519 ' "authorized key disables interactive SSH capabilities"
forced_health=$(cat "$auth_keys_snapshot.health")
case "$forced_health" in RH_OK*) ;; *) fail "generated forced command could not execute from a quoted HOME path";; esac
refute_grep_e "$ssh_log" '(^| )-N( |$)' "laptop-setup opened a new ssh -N despite reusable tunnel"
if [ -f "$proj_home/.ssh/authorized_keys" ] && grep -F "remote-harness:reverse-auth:" "$proj_home/.ssh/authorized_keys" >/dev/null; then
  fail "temporary authorized_keys block was not cleaned"
fi
if [ -f "$proj_home/.ssh/authorized_keys" ] && grep -F "AAAAC3NzaC1lZDI1NTE5AAAAITest" "$proj_home/.ssh/authorized_keys" >/dev/null; then
  fail "temporary authorized_keys key was not cleaned"
fi

# Local cleanup retains the whole transport when shared or unverifiable, then retries on launch.
shared_home="$tmp/shared-project-host"
mkdir -p "$shared_home"
for resource_used in 1 error 0; do
  HOME="$shared_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
    SSH_LOG="$tmp/shared-$resource_used.ssh.log" RESOURCE_USED="$resource_used" RH_RELEASE_RETRY_DELAYS="0 0 0" \
    bash "$ROOT/scripts/laptop-setup.sh" --host example.com --port 32023 --via 'ssh user@example.com' \
      --pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test' \
      --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
      --remote-mountpoint /tmp/rh-remote --project-dir "$valid_project" --launch codex --yes \
      > "$tmp/shared-$resource_used.out"
  if [ "$resource_used" != 0 ]; then
    [ -n "$(find "$shared_home/.remote-harness/.sessions" -name resources.env -print -quit)" ] \
      || fail 'shared or unreachable transport lost its local resource record'
    [ -n "$(find "$shared_home/.remote-harness/.sessions" -name ssh_config -print -quit)" ] \
      || fail 'shared or unreachable transport lost its local SSH config'
    grep -q 'remote-harness:reverse-auth:' "$shared_home/.ssh/authorized_keys" \
      || fail 'shared or unreachable transport lost its authorization'
  fi
done
[ -z "$(find "$shared_home/.remote-harness/.sessions" -name resources.env -print -quit)" ] \
  || fail 'unused deferred transport records were not reclaimed'
if grep -q 'remote-harness:reverse-auth:' "$shared_home/.ssh/authorized_keys"; then
  fail 'unused deferred authorization was not reclaimed'
fi
assert_grep "$tmp/shared-error.out" "remote host unreachable" "retained transport explains the unreachable server"
assert_grep "$tmp/shared-error.out" "Remote host unreachable; retrying in 0s" "unreachable server is retried"
assert_eq "unreachable server retried three times" "$(grep -c 'Remote host unreachable; retrying' "$tmp/shared-error.out")" "3"
assert_grep "$tmp/shared-1.out" "another remote session still uses this transport" "retained transport explains sharing"
noisy_home="$tmp/noisy-release-home"
mkdir -p "$noisy_home"
HOME="$noisy_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  SSH_LOG="$ssh_log" RESOURCE_USED=noisy \
  bash "$ROOT/scripts/laptop-setup.sh" --host example.com --port 32023 --via 'ssh user@example.com' \
    --pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test' \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote --project-dir "$valid_project" --launch codex --yes \
    > "$tmp/noisy-release.out"
[ -z "$(find "$noisy_home/.remote-harness/.sessions" -name resources.env -print -quit)" ] \
  || fail 'a USED=0 verdict wrapped in shell output did not release the transport'
# A launch that fails (here: the mount) runs cleanup from the EXIT trap and must still release.
failed_home="$tmp/failed-mount-home"
mkdir -p "$failed_home"
if HOME="$failed_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  SSH_LOG="$ssh_log" MOUNT_FAIL=1 \
  bash "$ROOT/scripts/laptop-setup.sh" --host example.com --port 32023 --via 'ssh user@example.com' \
    --pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test' \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote --project-dir "$valid_project" --launch codex --yes \
    > "$tmp/failed-mount.out" 2>&1; then
  fail 'laptop-setup succeeded although the mount failed'
fi
assert_grep "$tmp/failed-mount.out" "Mount failed (STATUS=failed)" "failed mount reported"
[ -z "$(find "$failed_home/.remote-harness/.sessions" -name resources.env -print -quit)" ] \
  || { cat "$tmp/failed-mount.out" >&2; fail 'a failed launch retained its unused transport'; }
if grep -q 'remote-harness:reverse-auth:' "$failed_home/.ssh/authorized_keys" 2>/dev/null; then
  fail 'a failed launch retained its temporary authorization'
fi

# User-mode sshd: the tunnel reaches a per-session sshd that reads only its own authorized_keys.
if bash "$ROOT/scripts/laptop-setup.sh" --host example.com --port 32029 --local-sshd user --setup-only \
    >/dev/null 2>"$tmp/user-sshd-setup-only.err"; then
  fail "user-mode sshd accepted --setup-only"
fi
assert_grep "$tmp/user-sshd-setup-only.err" "needs a full session" "user-mode sshd rejects setup-only"
if bash "$ROOT/scripts/laptop-setup.sh" --host example.com --port 32029 --local-sshd bogus \
    >/dev/null 2>"$tmp/user-sshd-bogus.err"; then
  fail "laptop-setup accepted an unknown --local-sshd"
fi
assert_grep "$tmp/user-sshd-bogus.err" "unsupported --local-sshd bogus" "unknown local sshd mode rejected"
printf 'AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys\n' > "$tmp/sshd-ipa.conf"
printf 'AuthorizedKeysCommand none\n' > "$tmp/sshd-plain.conf"
if local_port_free 22; then
  assert_eq "user-mode hint without an sshd" "$(local_sshd_user_mode_hint)" "no-sshd"
else
  assert_eq "user-mode hint for key lookup outside authorized_keys" \
    "$(RH_SSHD_CONFIG="$tmp/sshd-ipa.conf" RH_SSHD_CONFIG_DIR="$tmp/none" local_sshd_user_mode_hint)" "external-keys"
  if RH_SSHD_CONFIG="$tmp/sshd-plain.conf" RH_SSHD_CONFIG_DIR="$tmp/none" local_sshd_user_mode_hint >/dev/null; then
    fail "AuthorizedKeysCommand none suggested user-mode sshd"
  fi
fi
# sshd StrictModes rejects key files below the world-writable /tmp, so this home lives in the real one.
if user_sshd_bin >/dev/null && [ -n "${HOME:-}" ] && user_home=$(mktemp -d "$HOME/.rh-regression-sshd.XXXXXX" 2>/dev/null); then
  trap 'rm -rf "$tmp" "$user_home"' EXIT
  user_project="$user_home/project"
  mkdir -p "$user_project"
  ssh-keygen -q -t ed25519 -N '' -f "$user_home/box_key" </dev/null
  real_ssh=$(command -v ssh)  # resolved before the stub directory joins PATH
  # A umask of 002 leaves remote-harness directories group-writable; setup must tighten them.
  mkdir -p "$user_home/.remote-harness/.sessions" && chmod 775 "$user_home/.remote-harness" "$user_home/.remote-harness/.sessions"
  HOME="$user_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" SSH_LOG="$ssh_log" \
    REAL_SSH="$real_ssh" USER_SSHD_KEY="$user_home/box_key" USER_SSHD_PROBE="$user_home/probe" \
    bash "$ROOT/scripts/laptop-setup.sh" --local-sshd user \
      --host example.com --port 32029 --via "ssh user@example.com" \
      --pubkey "$(cat "$user_home/box_key.pub")" \
      --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
      --remote-mountpoint /tmp/rh-remote --project-dir "$user_project" --launch codex --yes \
      > "$tmp/user-sshd.out" 2>&1 || { cat "$tmp/user-sshd.out" >&2; fail "user-mode sshd session failed"; }
  assert_grep "$tmp/user-sshd.out" "user-mode sshd: authorized the forced project-host gateway" "user-mode sshd authorizes privately"
  assert_grep_e "$tmp/user-sshd.out" "user-mode sshd: listening on 127\.0\.0\.1:[0-9]+" "user-mode sshd started"
  user_port=$(awk '$1=="Port"{print $2}' "$user_home/probe.cfg")
  assert_grep "$user_home/probe.ssh_config" "RemoteForward 32029 127.0.0.1:$user_port" "tunnel forwards to the user-mode sshd port"
  assert_grep "$user_home/probe.cfg" "ListenAddress 127.0.0.1" "user-mode sshd listens on loopback only"
  assert_grep "$user_home/probe.cfg" "AuthorizedKeysCommand none" "user-mode sshd skips external key lookup"
  assert_grep "$user_home/probe.cfg" "AuthenticationMethods publickey" "user-mode sshd allows public keys only"
  assert_grep "$user_home/probe.cfg" "DisableForwarding yes" "user-mode sshd disables forwarding"
  assert_grep "$user_home/probe.cfg" "PermitTTY no" "user-mode sshd disables TTYs"
  case "$(cat "$user_home/probe.health")" in RH_OK*) ;; *) cat "$user_home/probe.err" >&2; fail "box key did not reach the gateway through the user-mode sshd";; esac
  [ ! -e "$user_home/.ssh/authorized_keys" ] || fail "user-mode sshd wrote ~/.ssh/authorized_keys"
  case "$(ls -ld "$user_home/.remote-harness")" in d????w*|d???????w*) fail "group-writable ~/.remote-harness was not tightened";; esac
  user_pid=$(cat "$user_home/probe.pid")
  if kill -0 "$user_pid" 2>/dev/null; then kill "$user_pid"; fail "cleanup left the user-mode sshd running"; fi
  [ -z "$(find "$user_home/.remote-harness/.sessions" -name resources.env -print -quit)" ] \
    || fail "user-mode sshd session left its resource record"
  # A port taken between the pick and the bind: sshd fails to bind and the start retries another.
  python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(60)' \
    > "$user_home/busy" &
  busy_pid=$!
  wait_until 20 test -s "$user_home/busy" || true
  eval "$(declare -f user_sshd_pick_port | sed '1s/user_sshd_pick_port/real_user_sshd_pick_port/')"
  user_sshd_pick_port() {  # the first pick loses the race
    if [ -e "$user_home/raced" ]; then real_user_sshd_pick_port; else : > "$user_home/raced"; cat "$user_home/busy"; fi
  }
  user_sshd_start "$user_home/retry" "$(id -un)" || fail "user-mode sshd did not retry after a lost bind race"
  eval "$(declare -f real_user_sshd_pick_port | sed '1s/real_user_sshd_pick_port/user_sshd_pick_port/')"
  kill "$busy_pid" 2>/dev/null || true
  [ -e "$user_home/raced" ] && [ "$USER_SSHD_PORT" != "$(cat "$user_home/busy")" ] || fail "user-mode sshd kept a taken port"
  kill "$USER_SSHD_PID" 2>/dev/null || true
  # Make the unsafe ancestor explicit: macOS TMPDIR can be private rather than world-writable /tmp.
  mkdir -p "$tmp/unsafe-sshd-parent"; chmod 777 "$tmp/unsafe-sshd-parent"
  user_sshd_rc=0; user_sshd_start "$tmp/unsafe-sshd-parent/session" "$(id -un)" || user_sshd_rc=$?
  assert_eq "user-mode sshd refuses a StrictModes-unsafe directory" "$user_sshd_rc" "3"
  [ -n "$USER_SSHD_UNSAFE_DIR" ] || fail "user-mode sshd did not name the unsafe directory"
  rm -rf "$user_home"
  trap 'rm -rf "$tmp"' EXIT
else
  printf 'skip: user-mode sshd end-to-end test (no sshd binary or no writable home)\n'
fi

preauth_home="$tmp/preauth-home"
preauth_project="$tmp/preauth-project"
mkdir -p "$preauth_home/.ssh" "$preauth_project"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest existing-user-key\n' > "$preauth_home/.ssh/authorized_keys"
if SSH_LOG="$ssh_log" reverse_session "$preauth_home" 32028 "$preauth_project" \
    > "$tmp/project-preauth.out" 2> "$tmp/project-preauth.err"; then
  fail "laptop-setup reused an unrestricted existing session key"
fi
assert_grep "$tmp/project-preauth.out" "refusing unsafe reuse" "existing unrestricted key is rejected"
assert_eq "existing authorized key not duplicated" "$(grep -F "AAAAC3NzaC1lZDI1NTE5AAAAITest" "$preauth_home/.ssh/authorized_keys" | wc -l | tr -d ' ')" "1"
refute_grep "$preauth_home/.ssh/authorized_keys" "remote-harness:reverse-auth:" "managed authorized_keys block added despite existing user key"

SSH_LOG="$ssh_log" reverse_session "$proj_home" 32024 "$created_project" \
  >"$tmp/project-create.out" 2>"$tmp/project-create.err"
[ -d "$created_project" ] || fail "laptop-setup did not create missing project dir under --yes"
assert_grep "$tmp/project-create.err" "Created $created_project" "project-dir create path"
if SSH_LOG="$ssh_log" reverse_session "$proj_home" 32025 "$file_project" \
  >"$tmp/project-file.out" 2>"$tmp/project-file.err"; then
  fail "laptop-setup accepted non-directory project path"
fi
assert_grep "$tmp/project-file.err" "No valid project directory selected" "project-dir non-directory abort"

if bash "$ROOT/scripts/mount-project.sh" --alias >/dev/null 2>"$tmp/mount-missing.err"; then
  fail "mount-project accepted missing --alias value"
fi
assert_grep "$tmp/mount-missing.err" "missing value for --alias" "mount missing arg"
assert_grep "$ROOT/scripts/mount-project.sh" 'SSH_BIN="$(command -v ssh' "mount-project uses absolute ssh binary for sshfs"
assert_grep "$ROOT/scripts/mount-project.sh" "sshfs exited 0 but the mount did not become live" "mount-project verifies live mount after sshfs"

canon_root="$tmp/canon-root"
mkdir -p "$canon_root/physical/mount" "$tmp/canon-bin"
ln -s "$canon_root/physical" "$canon_root/link"
canon_mp="$canon_root/physical/mount"
link_mp="$canon_root/link/mount"
canon_state="$tmp/canon-mounted"
canon_log="$tmp/canon-umount.log"
: > "$canon_state"
cat > "$tmp/canon-bin/mount" <<'EOS'
#!/usr/bin/env bash
[ -f "${CANON_STATE:?}" ] && printf 'fuse-t:/x on %s (nfs, nodev, nosuid)\n' "${CANON_MP:?}"
EOS
cat > "$tmp/canon-bin/umount" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${CANON_LOG:?}"
[ "$1" = "${CANON_MP:?}" ] || exit 1
rm -f "${CANON_STATE:?}"
exit 0
EOS
cat > "$tmp/canon-bin/fusermount" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
cp "$tmp/canon-bin/fusermount" "$tmp/canon-bin/fusermount3"
chmod +x "$tmp/canon-bin/mount" "$tmp/canon-bin/umount" "$tmp/canon-bin/fusermount" "$tmp/canon-bin/fusermount3"
CANON_STATE="$canon_state" CANON_MP="$canon_mp" CANON_LOG="$canon_log" PATH="$tmp/canon-bin:$PATH" \
  bash "$ROOT/scripts/mount-project.sh" --alias rlocal --unmount --mountpoint "$link_mp" > "$tmp/canon-unmount.out"
assert_grep "$tmp/canon-unmount.out" "STATUS=unmounted" "mount-project unmount detects canonical path"
assert_grep "$canon_log" "$canon_mp" "mount-project retries unmount with canonical path"

if bash "$ROOT/scripts/check-tunnel.sh" --alias >/dev/null 2>"$tmp/check-missing.err"; then
  fail "check-tunnel accepted missing --alias value"
fi
assert_grep "$tmp/check-missing.err" "missing value for --alias" "check missing arg"
assert_grep "$ROOT/scripts/laptop-setup.sh" "ssh -o ClearAllForwardings=yes <CONNECT>" "laptop template disables forwarding during fetch"
assert_grep "$ROOT/reference/reverse.md" "ssh -n -o ClearAllForwardings=yes" "reverse docs disable forwarding during fetch"

# --- setup-tunnel.sh: --namespace derives a stable reverse port ----------------
st_home="$tmp/st-home"; mkdir -p "$st_home/.ssh" "$tmp/st-session-ns"
st_cfg_ns="$tmp/st-session-ns/ssh_config"
st_probe_bin="$tmp/st-probe-bin"
mkdir -p "$st_probe_bin"
printf '#!/bin/sh\nexit 0\n' > "$st_probe_bin/ss"
chmod +x "$st_probe_bin/ss"
st_out="$(PATH="$st_probe_bin:$PATH" HOME="$st_home" bash "$ROOT/scripts/setup-tunnel.sh" --config "$st_cfg_ns" --alias alice-mac --user alice --namespace alice --gen-key 2>/dev/null)"
st_port="$(printf '%s\n' "$st_out" | awk -F= '/^PORT=/{print $2}')"
case "$st_port" in *2) ;; *) fail "setup-tunnel hashed port should end in 2 (got '$st_port')";; esac
{ [ "$st_port" -ge 20002 ] && [ "$st_port" -le 29992 ]; } || fail "setup-tunnel hashed port out of [20002,29992] (got '$st_port')"
assert_grep "$st_cfg_ns" "Host alice-mac" "namespaced managed alias"
[ ! -e "$st_home/.remote-harness/.tunnel-pubkey" ] || fail "setup-tunnel copied the session key outside .sessions"
assert_grep "$st_cfg_ns" "    ControlMaster no" "setup-tunnel disables multiplexing"
assert_grep "$st_cfg_ns" "/runtime/known_hosts_alice-mac" "setup-tunnel separates mutable SSH runtime"
[ ! -e "$st_home/.ssh/config" ] || fail "setup-tunnel namespace wrote ~/.ssh/config"
[ ! -e "$st_home/.ssh/id_ed25519" ] || fail "setup-tunnel namespace generated key under ~/.ssh"
[ -f "$(dirname "$st_cfg_ns")/id_ed25519" ] || fail "setup-tunnel did not generate a per-session key"
[ ! -e "$st_home/.remote-harness/keys/id_ed25519" ] || fail "setup-tunnel generated a reusable global reverse key"
[ -z "$(find "$st_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "setup-tunnel namespace created config.rh-bak"
# explicit --port still wins (the runtime port-switch path)
st_home2="$tmp/st-home2"; mkdir -p "$st_home2/.ssh" "$tmp/st-session-port"
st_cfg_port="$tmp/st-session-port/ssh_config"
st_out2="$(HOME="$st_home2" bash "$ROOT/scripts/setup-tunnel.sh" --config "$st_cfg_port" --alias bob-mac --user bob --port 20122 --gen-key 2>/dev/null)"
assert_eq "setup-tunnel explicit --port" "$(printf '%s\n' "$st_out2" | awk -F= '/^PORT=/{print $2}')" "20122"
st_home_cfg="$tmp/st-home-cfg"; mkdir -p "$st_home_cfg"
st_session="$tmp/st-session"
mkdir -p "$st_session"
st_cfg="$st_session/ssh_config"
st_out_cfg="$(HOME="$st_home_cfg" bash "$ROOT/scripts/setup-tunnel.sh" --config "$st_cfg" --alias temp-mac --user temp --port 20222 --gen-key 2>/dev/null)"
assert_eq "setup-tunnel temp config path" "$(printf '%s\n' "$st_out_cfg" | awk -F= '/^CONFIG=/{print $2}')" "$st_cfg"
assert_grep "$st_cfg" "Host temp-mac" "setup-tunnel temp config host"
if [ -e "$st_home_cfg/.ssh/config" ] && grep -q 'temp-mac' "$st_home_cfg/.ssh/config"; then
  fail "setup-tunnel --config wrote managed alias to ~/.ssh/config"
fi
# no --config -> hard error
st_home_missing_cfg="$tmp/st-home-missing-cfg"; mkdir -p "$st_home_missing_cfg/.ssh"
if HOME="$st_home_missing_cfg" bash "$ROOT/scripts/setup-tunnel.sh" --alias y-mac --user y --namespace y >/dev/null 2>"$tmp/st-noconfig.err"; then
  fail "setup-tunnel accepted missing --config"
fi
assert_grep "$tmp/st-noconfig.err" "--config ABS_PATH" "setup-tunnel requires session config"
# neither --port nor --namespace -> hard error
st_home3="$tmp/st-home3"; mkdir -p "$st_home3/.ssh"
if HOME="$st_home3" bash "$ROOT/scripts/setup-tunnel.sh" --config "$tmp/st-noport-ssh_config" --alias x-mac --user x >/dev/null 2>"$tmp/st-noport.err"; then
  fail "setup-tunnel accepted neither --port nor --namespace"
fi
assert_grep "$tmp/st-noport.err" "need --port PORT or --namespace RU" "setup-tunnel requires port or namespace"

# --- inject-rule.sh: a pathological mountpoint ('..') must NOT escape $RH_HOME/.sessions/ ----
ir_rh="$tmp/ir-home/.remote-harness"; ir_home="$tmp/ir-home2"
mkdir -p "$ir_rh" "$ir_home" "$tmp/ir-code"
RH_HOME="$ir_rh" HOME="$ir_home" "$ROOT/scripts/inject-rule.sh" on claude "$tmp/ir-code" laptop ".." 0 "$basic_ssh_cfg" >/dev/null
[ -f "$ir_rh/.sessions/default/rule.md" ] || fail "inject-rule: '..' mountpoint not neutralized to .sessions/default"
[ ! -e "$ir_rh/rule.md" ] || fail "inject-rule: '..' mountpoint escaped to RH_HOME"
RH_HOME="$ir_rh" HOME="$ir_home" "$ROOT/scripts/inject-rule.sh" off claude ".." >/dev/null
[ ! -d "$ir_rh/.sessions/default" ] || fail "inject-rule: '..' session dir not cleaned"

# --- inject-rule.sh: two launches for one mountpoint keep separate runners ----------------------
ir_mp="$tmp/ir-shared-mount"
ir_sd="$ir_rh/.sessions/$(printf '%s' "$ir_mp" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
ir() { RH_HOME="$ir_rh" HOME="$ir_home" "$ROOT/scripts/inject-rule.sh" "$@"; }
ir on claude "$tmp/ir-code" laptop "$ir_mp" 0 "$basic_ssh_cfg" rev.a >/dev/null
ir on claude "$tmp/ir-code" laptop "$ir_mp" 0 "$basic_ssh_cfg" rev.b > "$tmp/ir-b.out"
assert_grep "$tmp/ir-b.out" "$ir_sd.rev.b/claude-settings.json" "inject-rule keys the session dir by session id"
[ -x "$ir_sd.rev.a/bin/rh-run" ] || fail "inject-rule: a second launch deleted the first session runner"
ir off claude "$ir_mp" rev.a >/dev/null
[ ! -d "$ir_sd.rev.a" ] && [ -x "$ir_sd.rev.b/bin/rh-run" ] || fail "inject-rule: off did not remove exactly its own session"
ir off claude "$ir_mp" rev.b >/dev/null
for ir_bad in .. 'a/b' 'a b'; do
  { ir on claude "$tmp/ir-code" laptop "$ir_mp" 0 "$basic_ssh_cfg" "$ir_bad" || true; } | grep -qx RH_STATUS=ERROR \
    || fail "inject-rule accepted unsafe session id '$ir_bad'"
done
[ -z "$(find "$ir_rh/.sessions" -maxdepth 1 -name "${ir_sd##*/}*" -print -quit)" ] || fail "inject-rule left or created a session dir"

# --- tool shims, session launcher, and server-side reaping ---------------------------------------
rp_rh="$tmp/rp-rh"
rp_home="$tmp/rp-home"
mkdir -p "$rp_rh/.sessions/simple.rp1" "$rp_home" "$tmp/rp-mount" "$tmp/rp-code"
rp_cfg="$rp_rh/.sessions/simple.rp1/ssh_config"
printf 'Host laptop\n    HostName 127.0.0.1\n' > "$rp_cfg"
printf 'key\n' > "$rp_rh/.sessions/simple.rp1/id_ed25519"
RH_HOME="$rp_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" on claude "$tmp/rp-code" laptop "$tmp/rp-mount" 0 "$rp_cfg" rev.rp1 > "$tmp/rp-inject.out"
rp_key="$(printf '%s' "$tmp/rp-mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
rp_sd="$rp_rh/.sessions/$rp_key.rev.rp1"
assert_grep "$tmp/rp-inject.out" "RH_LAUNCH_PREFIX='$rp_sd/bin/rh-session'" "inject exposes the session launcher"
[ -x "$rp_sd/bin/git" ] || fail "inject did not install the git shim"
assert_grep "$rp_sd/bin/git" "project-host-tool.py" "git shim delegates to project-host-tool"
assert_grep "$rp_sd/session.env" "MOUNTPOINT=$(b64 "$tmp/rp-mount")" "session metadata records the mountpoint"
assert_grep "$rp_sd/session.env" "SSH_CONFIG=$(b64 "$rp_cfg")" "session metadata records the ssh config"
if [ "${#rp_rh}" -lt 60 ]; then
  assert_grep "$rp_sd/bin/rh-run" "--control-path" "short session runtime enables multiplexing"
fi
if [ -x "$rp_sd/bin/rg" ]; then
  assert_grep "$tmp/rp-inject.out" "USE_BUILTIN_RIPGREP=0" "claude uses the rg shim when one is installed"
fi
assert_grep "$rp_sd/rule.md" "Internal git and ripgrep calls also run on" "rule describes internal git routing"
refute_grep "$rp_sd/rule.md" "Simplified Chinese" "an English session rule asks for Chinese replies"
refute_grep "$rp_sd/rule.md" "All Git commands are routed too" "rule still claims every Git command is routed"

# Agent exits without any local cleanup: the watcher removes leftovers server-side.
python3 -c 'import sys, time; time.sleep(300)' "$rp_sd/bin/rh-run" &
rp_leftover=$!
RH_REAP_POLL=1 RH_REAP_GRACE=1 RH_HOME="$rp_rh" "$rp_sd/bin/rh-session" sleep 1
assert_grep "$rp_sd/owner.env" "OWNER_PID=" "launcher records the agent pid"
rp_reaped() { [ ! -d "$rp_sd" ] && [ ! -e "$rp_cfg" ]; }  # reap removes the dir, then the config
wait_until 300 rp_reaped || [ ! -d "$rp_sd" ] || fail "watcher did not reap the dead session dir"
[ ! -e "$rp_cfg" ] || fail "watcher did not remove the session ssh config"
[ ! -e "$rp_rh/.sessions/simple.rp1/id_ed25519" ] || fail "watcher did not remove the session private key"
if kill -0 "$rp_leftover" 2>/dev/null; then
  kill "$rp_leftover" 2>/dev/null || true
  fail "watcher left a routed session process running"
fi
wait "$rp_leftover" 2>/dev/null || true

# gc: dead, unlaunched-and-stale, live, and orphan-config cases.
mkdir -p "$rp_rh/.sessions/dead.s" "$rp_rh/.sessions/stale.s" "$rp_rh/.sessions/live.s" \
  "$rp_rh/.sessions/fresh.s" "$rp_rh/.sessions/simple.old" "$rp_rh/.sessions/simple.new"
for rp_s in dead stale live fresh; do
  printf 'MOUNTPOINT=%s\n' "$(b64 "$tmp/rp-none-$rp_s")" > "$rp_rh/.sessions/$rp_s.s/session.env"
done
printf 'OWNER_PID=999999999\n' > "$rp_rh/.sessions/dead.s/owner.env"
printf 'OWNER_PID=%s\nOWNER_START=%s\n' "$$" \
  "$(b64 "$(ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')")" > "$rp_rh/.sessions/live.s/owner.env"
touch -t 202001010000 "$rp_rh/.sessions/stale.s/session.env"
printf 'Host x\n' > "$rp_rh/.sessions/simple.old/ssh_config"
touch -t 202001010000 "$rp_rh/.sessions/simple.old/ssh_config"
printf 'Host y\n' > "$rp_rh/.sessions/simple.new/ssh_config"
RH_HOME="$rp_rh" sh "$ROOT/scripts/session-reaper.sh" gc
[ ! -d "$rp_rh/.sessions/dead.s" ] || fail "gc kept a session whose agent is gone"
[ ! -d "$rp_rh/.sessions/stale.s" ] || fail "gc kept a never-launched stale session"
[ -d "$rp_rh/.sessions/live.s" ] || fail "gc removed a live session"
[ -d "$rp_rh/.sessions/fresh.s" ] || fail "gc removed a session that is still launching"
[ ! -e "$rp_rh/.sessions/simple.old/ssh_config" ] || fail "gc kept an orphan session ssh config"
[ -e "$rp_rh/.sessions/simple.new/ssh_config" ] || fail "gc removed a fresh session ssh config"
mkdir -p "$tmp/rp-outside"
RH_HOME="$rp_rh" sh "$ROOT/scripts/session-reaper.sh" reap "$tmp/rp-outside"
[ -d "$tmp/rp-outside" ] || fail "reaper deleted a directory outside \$RH_HOME/.sessions"

# --- runner guard selection: with python3 the Bash runner is watched, without it unchanged -------
wr_rh="$tmp/wr-rh"
mkdir -p "$wr_rh" "$tmp/wr-mount" "$tmp/wr-mount-nopy"
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" on codex "$tmp/rp-code" laptop "$tmp/wr-mount" 0 "$basic_ssh_cfg" > /dev/null
wr_sd="$wr_rh/.sessions/$(printf '%s' "$tmp/wr-mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
assert_grep "$wr_sd/bin/rh-run" "channel-guard.py" "runner holds the channel open with python3"
assert_grep "$wr_sd/bin/rh-run" "--watch" "runner asks for watched execution"
nopy_bin="$tmp/nopy-bin"
mkdir -p "$nopy_bin"
for nopy_src in /usr/local/bin/* /usr/bin/* /bin/*; do
  nopy_name=${nopy_src##*/}
  case "$nopy_name" in python*) continue ;; esac
  [ -e "$nopy_bin/$nopy_name" ] || ln -s "$nopy_src" "$nopy_bin/$nopy_name" 2>/dev/null || true
done
PATH="$nopy_bin" RH_HOME="$wr_rh" HOME="$rp_home" \
  "$ROOT/scripts/inject-rule.sh" on opencode "$tmp/rp-code" laptop "$tmp/wr-mount-nopy" 0 "$basic_ssh_cfg" > "$tmp/wr-nopy.out"
assert_grep "$tmp/wr-nopy.out" "RH_STATUS=INJECTED" "opencode inject works without python3"
wr_nopy_sd="$wr_rh/.sessions/$(printf '%s' "$tmp/wr-mount-nopy" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
refute_grep_e "$wr_nopy_sd/bin/rh-run" 'channel-guard|--watch' "runner requires python3 that is not installed"
[ ! -e "$wr_nopy_sd/bin/git" ] || fail "git shim installed without python3"
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" off codex "$tmp/wr-mount" >/dev/null
# With a session id and python3 the runner, launcher and shims use the session's warm pool.
mkdir -p "$tmp/wr-mount-warm"
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" on codex "$tmp/rp-code" laptop "$tmp/wr-mount-warm" 0 "$basic_ssh_cfg" rev.warm > /dev/null
wr_warm_sd="$wr_rh/.sessions/$(printf '%s' "$tmp/wr-mount-warm" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_').rev.warm"
assert_grep "$wr_warm_sd/bin/rh-run" "--warm '$tmp/runtime/warm.rev.warm'" "runner tries the session's warm pool"
assert_grep "$wr_warm_sd/bin/rh-run" "remote-harness-exec " "runner hands the guard the request line"
assert_grep "$wr_warm_sd/bin/rh-session" "warm_pool.py" "launcher starts the warm pool"
assert_grep "$wr_warm_sd/bin/git" "--warm-socket '$tmp/runtime/warm.rev.warm'" "git shim uses the warm pool"
[ -f "$wr_warm_sd/impl/warm_pool.py" ] || fail "session implementation lacks warm_pool.py"
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" off codex "$tmp/wr-mount-warm" rev.warm >/dev/null
RH_WARM_MAX=0 RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" on codex "$tmp/rp-code" laptop "$tmp/wr-mount-warm" 0 "$basic_ssh_cfg" rev.cold > /dev/null
wr_cold_sd="$wr_rh/.sessions/$(printf '%s' "$tmp/wr-mount-warm" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_').rev.cold"
refute_grep "$wr_cold_sd/bin/rh-run" "--warm" "RH_WARM_MAX=0 leaves the warm pool out of the runner"
assert_grep "$wr_cold_sd/bin/git" "--warm-socket ''" "RH_WARM_MAX=0 leaves the warm pool out of the shims"
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" off codex "$tmp/wr-mount-warm" rev.cold >/dev/null
RH_HOME="$wr_rh" HOME="$rp_home" "$ROOT/scripts/inject-rule.sh" off opencode "$tmp/wr-mount-nopy" >/dev/null

python3 "$ROOT/tests/test_dispatch_lifecycle.py" -v
python3 "$ROOT/tests/test_project_host_tool.py" -v
python3 "$ROOT/tests/test_shell_snapshot.py" -v
python3 "$ROOT/tests/test_shell_policy.py" -v
python3 "$ROOT/tests/test_transport_capacity.py" -v
bash "$ROOT/tests/resources.sh"

# --- mount-project.sh: opt-in parallel SFTP connections, kernel lookup caching ----------------
mc_bin="$tmp/mc-bin"; mc_log="$tmp/mc-sshfs.log"; mkdir -p "$mc_bin" "$tmp/mc-mount"; : > "$tmp/mc-ssh_config"
printf '#!/bin/sh\nif [ "$1" = --help ]; then [ -n "$MC_NO_MAX" ] || echo "-o max_conns=N"; exit 0; fi\necho "$*" > %s\nexit 1\n' \
  "'$mc_log'" > "$mc_bin/sshfs"; chmod +x "$mc_bin/sshfs"
mc_opts() {  # prints the arguments mount-project passed to (fake) sshfs
  : > "$mc_log"
  PATH="$mc_bin:$PATH" "$ROOT/scripts/mount-project.sh" --alias box --remote-path /p \
    --ssh-config "$tmp/mc-ssh_config" --mountpoint "$tmp/mc-mount" >/dev/null 2>&1 || true
  cat "$mc_log"
}
mc_default="$(mc_opts)"
case "$mc_default" in *max_conns*) fail "sshfs used parallel SFTP connections by default";; esac
case "$(RH_SSHFS_MAX_CONNS=4 mc_opts)" in *max_conns=4*) ;; *) fail "RH_SSHFS_MAX_CONNS=4 did not enable max_conns";; esac
if [ "$(uname -s)" != Darwin ]; then
  case "$mc_default" in *entry_timeout=20,attr_timeout=20,negative_timeout=20,auto_cache*) ;; *) fail "sshfs lookups and contents are not cached by default";; esac
  case "$(RH_SSHFS_CACHE_SECONDS=0 mc_opts)" in *negative_timeout*|*auto_cache*) fail "RH_SSHFS_CACHE_SECONDS=0 still cached";; esac
fi
mc_unsupported="$(MC_NO_MAX=1 RH_SSHFS_MAX_CONNS=4 mc_opts)"
[ -n "$mc_unsupported" ] || fail "fake sshfs was not invoked"
case "$mc_unsupported" in *max_conns*) fail "max_conns passed to an sshfs that does not support it";; esac

# --- mount-project.sh: a detached sshfs is stopped only when its FUSE superblock is gone and idle --
if [ -d /proc/self ] && command -v perl >/dev/null 2>&1; then
  ds_mp="$tmp/detached-mount"; ds_cfg="$tmp/detached-ssh_config"; mkdir -p "$ds_mp"; : > "$ds_cfg"
  ds_title="sshfs box:/p $ds_mp -o reconnect,ssh_command=/usr/bin/ssh -F $ds_cfg"
  ds_fusectl="$tmp/ds-fusectl"; mkdir -p "$ds_fusectl"
  ds_fake() {  # $1 = pid variable, $2 = process title, $3 = 1 to keep doing I/O
    perl -e '$0 = $ARGV[0]; open(my $n, ">", "/dev/null");
             while (1) { syswrite($n, "x" x 65536) if $ARGV[1]; select(undef, undef, undef, 0.2) }' \
      "$2" "$3" >/dev/null 2>&1 &
    # Keep this a child of the test shell, which can reap it even under a runner subreaper.
    printf -v "$1" '%s' "$!"
  }
  # The mountpoint here was never mounted (an earlier run "already detached" it), so the decision
  # rests on the fusectl listing: any live FUSE superblock of ours that no mount shows may be it.
  ds_unmount() {
    RH_FUSECTL_DIR="${ds_fusectl_dir-$ds_fusectl}" \
      "$ROOT/scripts/mount-project.sh" --alias box --unmount --mountpoint "$ds_mp" 2>/dev/null
  }
  ds_fake ds_idle "$ds_title" 0; ds_fake ds_sftp "/usr/bin/ssh -F $ds_cfg -x box -s sftp" 0; sleep 0.5
  # Neither the unmounted daemon nor its sftp ssh keeps the session SSH config in use.
  RH_HOME="$tmp/ds-rh" sh "$ROOT/scripts/session-reaper.sh" config-used "$ds_cfg" | grep -qx USED=0 \
    || fail "an sshfs whose mount is gone kept its SSH config in use"
  kill "$ds_sftp" 2>/dev/null || true; wait "$ds_sftp" 2>/dev/null || true
  RH_PROGRESS_FD=3 RH_SSHFS_IDLE_SECONDS=2 ds_unmount 3>"$tmp/ds-progress" | grep -qx STATUS=unmounted || fail "detached sshfs unmount status"
  assert_grep "$tmp/ds-progress" "RH_PROGRESS=unmounted" "unmount reports detach progress"
  assert_grep "$tmp/ds-progress" "RH_PROGRESS=sshfs-wait" "unmount reports waiting for a lingering sshfs"
  wait_gone "$ds_idle" 20 || fail "idle detached sshfs kept running although no FUSE superblock of ours was left"
  wait "$ds_idle" 2>/dev/null || true
  # A live superblock that no mount here shows is still referenced (cwd, open file, other namespace).
  mkdir "$ds_fusectl/999999"
  ds_fake ds_used "$ds_title" 0; sleep 0.5
  RH_SSHFS_IDLE_SECONDS=2 ds_unmount >/dev/null
  kill -0 "$ds_used" 2>/dev/null || fail "detached sshfs was stopped while a detached FUSE superblock was still live"
  kill "$ds_used" 2>/dev/null || true; wait "$ds_used" 2>/dev/null || true
  rmdir "$ds_fusectl/999999"
  # Without an authoritative fusectl answer nothing is stopped.
  ds_fake ds_unknown "$ds_title" 0; sleep 0.5
  ds_fusectl_dir="$tmp/ds-no-fusectl" RH_SSHFS_IDLE_SECONDS=2 ds_unmount >/dev/null
  kill -0 "$ds_unknown" 2>/dev/null || fail "detached sshfs was stopped without a fusectl listing"
  kill "$ds_unknown" 2>/dev/null || true; wait "$ds_unknown" 2>/dev/null || true
  ds_fake ds_busy "$ds_title" 1; sleep 0.5
  RH_SSHFS_IDLE_SECONDS=2 RH_SSHFS_SYNC_MAX_SECONDS=4 ds_unmount >/dev/null
  kill -0 "$ds_busy" 2>/dev/null || fail "detached sshfs was stopped while it was still syncing"
  kill "$ds_busy" 2>/dev/null || true; wait "$ds_busy" 2>/dev/null || true
fi

# --- mount-project.sh: a real lazily detached sshfs mount (local sftp-server, no network) ---------
fm_sftp=""
for fm_candidate in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/sftp-server; do
  [ -x "$fm_candidate" ] && { fm_sftp=$fm_candidate; break; }
done
fm_umount() { fusermount -uz "$1" 2>/dev/null || fusermount3 -uz "$1" 2>/dev/null || true; }
if [ -n "$fm_sftp" ] && [ -c /dev/fuse ] && command -v sshfs >/dev/null 2>&1 \
   && { command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1; } \
   && grep -q ' /sys/fs/fuse/connections .* - fusectl ' /proc/self/mountinfo 2>/dev/null; then
  fm_src="$tmp/fm-src"; fm_mp="$tmp/fm-mount"; mkdir -p "$fm_src" "$fm_mp"
  printf '#!/bin/sh\nexec %s\n' "$fm_sftp" > "$tmp/fm-ssh"; chmod +x "$tmp/fm-ssh"
  fm_holder=""
  trap 'kill $fm_holder 2>/dev/null; fm_umount "$fm_mp"; rm -rf "$tmp"' EXIT
  fm_mount() { sshfs "x:$fm_src" "$fm_mp" -o "ssh_command=$tmp/fm-ssh" 2>/dev/null; }
  fm_pid() { ps -ww -u "$(id -u)" -o pid= -o args= | awk -v m="$fm_mp" '$2 == "sshfs" && $4 == m { print $1 }'; }
  fm_run() { RH_SSHFS_IDLE_SECONDS=1 "$ROOT/scripts/mount-project.sh" --alias x --unmount --mountpoint "$fm_mp" 2>/dev/null; }
  if fm_mount; then
    fm_daemon=$(fm_pid)
    (cd "$fm_mp" && exec 9>>held && exec sleep 60) & fm_holder=$!; sleep 0.5
    # The holder's cwd/fd now read "/" and "/held": invisible to any path scan of the old mountpoint.
    fm_run | grep -qx STATUS=unmounted || fail "busy real sshfs mount was not lazily detached"
    kill -0 "$fm_daemon" 2>/dev/null || fail "real sshfs was stopped while a process still used its detached mount"
    ls "/proc/$fm_holder/cwd/" >/dev/null 2>&1 || fail "the detached mount stopped serving its holder"
    # A second unmount no longer knows the device number: our unlisted live superblock keeps it.
    fm_run >/dev/null
    kill -0 "$fm_daemon" 2>/dev/null || fail "real sshfs was stopped by a repeated unmount while still in use"
    kill "$fm_holder" 2>/dev/null; wait "$fm_holder" 2>/dev/null || true; fm_holder=""
    wait_gone "$fm_daemon" 50 || fail "real sshfs kept running after the last user of its detached mount left"
    # A clean unmount still ends the daemon.
    if fm_mount; then
      fm_daemon=$(fm_pid)
      fm_run | grep -qx STATUS=unmounted || fail "idle real sshfs mount was not unmounted"
      wait_gone "$fm_daemon" 50 || fail "real sshfs kept running after a clean unmount"
    fi
  else
    printf 'skip: real sshfs mount (sshfs could not mount through a local sftp-server)\n'
  fi
  fm_umount "$fm_mp"
  trap 'rm -rf "$tmp"' EXIT
else
  printf 'skip: real sshfs detach (needs sshfs, fusermount, /dev/fuse, fusectl and sftp-server)\n'
fi

# macOS bash 3.2 reads non-ASCII bytes right after "$name" as part of the variable name (e.g. a
# full-width bracket in a Chinese prompt), which fails under set -u. Such variables must be braced.
python3 - "$ROOT"/scripts/*.sh <<'PY'
import re, sys
bad = [f"{path}:{n}" for path in sys.argv[1:]
       for n, line in enumerate(open(path, encoding="utf-8"), 1)
       if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]", line)]
assert not bad, "unbraced $var before a non-ASCII character: " + ", ".join(bad)
PY

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  doc_list() { git -C "$ROOT" ls-files --cached --others --exclude-standard '*.md'; }
else
  doc_list() { (cd "$ROOT" && find . -name '*.md' -type f | sed 's#^\./##'); }
fi
while IFS= read -r f; do
  [ -f "$ROOT/${f%.md}.cn.md" ] || fail "missing Chinese doc counterpart for $f"
done < <(doc_list | grep -v '^README.md$' | grep -v '^CLAUDE.md$' | grep -v '\.cn\.md$')

printf 'ok\n'
