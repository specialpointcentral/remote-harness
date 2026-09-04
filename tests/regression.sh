#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rh-regression.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"
}
assert_grep() {
  grep -F -- "$2" "$1" >/dev/null || fail "$3: missing '$2' in $1"
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
exec sh -c "$remote_command"
EOS
chmod +x "$router_tmp/bin/ssh"
printf 'Host project-host\n    HostName 127.0.0.1\n' > "$router_tmp/ssh_config"
client_out=$(PATH="$router_tmp/bin:$PATH" SHELL=/bin/sh \
  sh "$ROOT/scripts/run-on-project-host.sh" \
    --ssh-config "$router_tmp/ssh_config" --alias project-host \
    --project-root "$router_tmp/project" --cwd-relative-b64 "$(b64 packages/api)" \
    --command-b64 "$(b64 'printf "%s" "$PWD"')")
assert_eq "project-host client transport" "$client_out" "$router_tmp/project/packages/api"

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
if grep -F 'writable_roots=["~/.ssh"]' "$tmp/inject.out" >/dev/null; then
  fail "inject codex made ~/.ssh writable"
fi
[ -f "$session_dir/rule.md" ] || fail "inject rule file missing"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off codex "$tmp/mount" > "$tmp/inject-off.out"
assert_grep "$tmp/inject-off.out" "RH_STATUS=RESTORED" "inject off"
[ ! -d "$session_dir" ] || fail "inject session dir was not removed"

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
assert_grep "$wrapped_dir/rule.md" 'routes every Bash command to `rlocal`' "inject rule documents automatic routing"
if grep -F "ssh rlocal 'cd" "$wrapped_dir/rule.md" >/dev/null; then
  fail "strict inject rule still tells Codex to wrap commands in ssh"
fi
assert_grep "$tmp/inject-wrapped.out" "sandbox_workspace_write.writable_roots=[" "inject wrapper writable roots present"
assert_grep "$tmp/inject-wrapped.out" "$(dirname "$ssh_cfg")" "inject wrapper writable roots include session config dir"
if grep -q -- "-F " "$wrapped_dir/rule.md"; then
  fail "inject rule exposed temp ssh config path"
fi
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off codex "$tmp/mount-wrapped" >/dev/null

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
assert_grep "$claude_rule" "ordinary and nested subagents" "claude rule documents supported subagents"
assert_grep "$claude_rule" "Agent Teams are disabled" "claude rule documents team boundary"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off claude "$tmp/mount-claude" >/dev/null
missing_cfg_out=$(RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on codex "$tmp/code" laptop "$tmp/mount-no-config" 0 || true)
assert_grep <(printf '%s\n' "$missing_cfg_out") "RH_STATUS=ERROR" "strict codex inject requires ssh config"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on opencode "$tmp/code" laptop "$tmp/mount-opencode" 1 > "$tmp/inject-opencode.out"
assert_grep "$tmp/inject-opencode.out" "RH_LAUNCH_ENV=OPENCODE_CONFIG='" "inject opencode env quoted"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off opencode "$tmp/mount-opencode" >/dev/null

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
setup_home="$tmp/setup-home"
mkdir -p "$setup_home"
HOME="$setup_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32022 \
    --via "ssh -J jumpbox -i /tmp/key user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --setup-only --yes > "$tmp/setup-only.out"
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
[ ! -e "$setup_home/.ssh/config" ] || fail "laptop-setup wrote ~/.ssh/config"
[ ! -e "$setup_home/.ssh/authorized_keys" ] || fail "laptop-setup wrote ~/.ssh/authorized_keys"
[ -z "$(find "$setup_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "laptop-setup created config.rh-bak"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ] && [ "${2:-}" = "mybox" ]; then
  printf 'user mybox\nhostname 203.0.113.7\nport 22\nidentityfile ~/.ssh/id_ed25519\n'
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
HOME="$alias_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host mybox --port 22022 --via "mybox" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --setup-only --yes > "$tmp/setup-alias.out"
alias_cfg="$(find "$alias_home/.remote-harness/.sessions" -name ssh_config -print -quit 2>/dev/null)"
[ -n "$alias_cfg" ] || fail "alias setup-only session ssh config missing"
assert_grep "$alias_cfg" "Host mybox-remote-harness" "dedicated harness alias"
assert_grep "$alias_cfg" "    HostName 203.0.113.7" "dedicated alias resolved hostname"
assert_grep "$alias_cfg" "    RemoteForward 22022 127.0.0.1:22" "dedicated alias remote forward"
assert_grep "$alias_cfg" "Include $alias_home/.ssh/config" "dedicated alias reads user config without editing it"
assert_grep "$alias_cfg" "/runtime/known_hosts" "dedicated alias separates mutable SSH runtime from config"
if grep -q "mybox-remote-harness" "$alias_home/.ssh/config"; then
  fail "laptop-setup wrote dedicated alias to user ~/.ssh/config"
fi
[ -z "$(find "$alias_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "alias setup created config.rh-bak"

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

if HOME="$tmp/launch-home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32022 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --launch "codex --flag" --setup-only --yes \
    >"$tmp/laptop-bad-launch.out" 2>"$tmp/laptop-bad-launch.err"; then
  fail "laptop-setup accepted extra --launch words"
fi
assert_grep "$tmp/laptop-bad-launch.err" "unsupported --launch" "laptop launch validation"
if HOME="$tmp/local-launch-home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/local-setup.sh" --via "ssh user@example.com" --remote-path /srv/app \
    --launch "codex --flag" --yes >"$tmp/local-bad-launch.out" 2>"$tmp/local-bad-launch.err"; then
  fail "local-setup accepted extra --launch words"
fi
assert_grep "$tmp/local-bad-launch.err" "unsupported --launch" "local launch validation"

local_session_scripts="$tmp/local-session-scripts"
mkdir -p "$local_session_scripts"
cp "$ROOT/scripts/_common.sh" "$ROOT/scripts/local-setup.sh" "$local_session_scripts/"
cat > "$local_session_scripts/mount-project.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOCAL_MOUNT_ARGS:?}"
printf 'STATUS=mounted\nMOUNTPOINT=%s\n' "${LOCAL_MOUNTPOINT:-/tmp/local-mount}"
EOS
cat > "$local_session_scripts/inject-rule.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOCAL_INJECT_ARGS:?}"
case "${1:-}" in
  on)
    if [ "${LOCAL_INJECT_FAIL:-0}" = 1 ]; then printf 'RH_STATUS=ERROR\n';
    else printf 'RH_STATUS=INJECTED\nRH_LAUNCH_ENV=PATH=%q\nRH_LAUNCH_FLAGS=\n' "/tmp/rh-bin:$PATH"; fi
    ;;
  off) printf 'RH_STATUS=RESTORED\n';;
esac
EOS
chmod +x "$local_session_scripts/mount-project.sh" "$local_session_scripts/inject-rule.sh"
cat > "$tmp/bin/fake-shell" <<'EOS'
#!/usr/bin/env bash
[ -n "${FAKE_SHELL_MARKER:-}" ] && printf 'launched\n' > "$FAKE_SHELL_MARKER"
exit 0
EOS
cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOCAL_SSH_LOG:?}"
exit 0
EOS
chmod +x "$tmp/bin/fake-shell" "$tmp/bin/ssh"
local_session_home="$tmp/local-session-home"
mkdir -p "$local_session_home" "$tmp/local-session-mount"
HOME="$local_session_home" PATH="$tmp/bin:$PATH" RH_COMMON="$local_session_scripts/_common.sh" \
  SHELL="$tmp/bin/fake-shell" LOCAL_MOUNT_ARGS="$tmp/local-mount.args" \
  LOCAL_INJECT_ARGS="$tmp/local-inject.args" LOCAL_SSH_LOG="$tmp/local-ssh.log" \
  LOCAL_MOUNTPOINT="$tmp/local-session-mount" \
  bash "$local_session_scripts/local-setup.sh" \
    --via "ssh -p 2222 dev@example.com" --remote-path /srv/app \
    --mountpoint "$tmp/local-session-mount" --launch codex --yes > "$tmp/local-session.out"
assert_grep "$tmp/local-session.out" "session ssh config removed" "local setup removes temp ssh config"
assert_grep "$tmp/local-mount.args" "--ssh-config" "local setup passes temp config to mount"
assert_grep "$tmp/local-inject.args" "$local_session_home/.remote-harness/.sessions/" "local setup passes temp config to rule wrapper"
assert_grep "$tmp/local-ssh.log" "-F $local_session_home/.remote-harness/.sessions/" "local setup probes through temp config"
[ ! -e "$local_session_home/.ssh/config" ] || fail "local-setup wrote ~/.ssh/config"
[ -z "$(find "$local_session_home/.ssh" -name 'config.rh-bak.*' -print -quit 2>/dev/null)" ] || fail "local-setup created config.rh-bak"

local_fail_home="$tmp/local-fail-home"
mkdir -p "$local_fail_home" "$tmp/local-fail-mount"
if HOME="$local_fail_home" PATH="$tmp/bin:$PATH" RH_COMMON="$local_session_scripts/_common.sh" \
  SHELL="$tmp/bin/fake-shell" LOCAL_MOUNT_ARGS="$tmp/local-fail-mount.args" \
  LOCAL_INJECT_ARGS="$tmp/local-fail-inject.args" LOCAL_SSH_LOG="$tmp/local-fail-ssh.log" \
  LOCAL_MOUNTPOINT="$tmp/local-fail-mount" LOCAL_INJECT_FAIL=1 \
  FAKE_SHELL_MARKER="$tmp/local-fail-launched" \
  bash "$local_session_scripts/local-setup.sh" \
    --via "ssh -p 2222 dev@example.com" --remote-path /srv/app \
    --mountpoint "$tmp/local-fail-mount" --launch codex --yes \
    >"$tmp/local-fail.out" 2>"$tmp/local-fail.err"; then
  fail "local-setup continued after strict rule injection failed"
fi
[ ! -e "$tmp/local-fail-launched" ] || fail "local-setup launched the agent after injection failure"
assert_grep "$tmp/local-fail.err" "refusing to launch" "local setup fails closed"

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
assert_grep "$tmp/simple-laptop.args" "ARG_18=--yolo" "simple handoff yolo default accepted under --yes"
assert_grep "$tmp/simple-cache.env" "LAST_VIA=-p 2222 bytepilot@42.121.2.119" "simple cache via"
if grep -q '^LAST_NAMESPACE=' "$tmp/simple-cache.env"; then
  fail "simple cache should not persist the hidden namespace override"
fi
assert_grep "$tmp/simple-cache.env" "LAST_PROJECT_DIR=$simple_project_real" "simple cache project"
assert_grep "$tmp/simple-cache.env" "LAST_REMOTE_MOUNTPOINT=/tmp/rh-simple-remote" "simple cache mountpoint"
assert_grep "$tmp/simple-cache.env" "LAST_LAUNCH=codex" "simple cache launch"
assert_grep "$tmp/simple-cache.env" "LAST_YOLO=1" "simple cache yolo"
assert_grep "$ROOT/scripts/simple-laptop-setup.sh" 'PROJECT_DIR="$(choose_project_dir "$cached_project" 1)"' "simple cached project prompts for confirmation"
assert_grep "$ROOT/scripts/simple-laptop-setup.sh" 'if [ "$YOLO_REQUESTED" = 1 ]; then' "explicit yolo has a no-reprompt branch"
assert_grep "$ROOT/scripts/simple-laptop-setup.sh" 'YOLO=1' "explicit yolo locks yolo on"

cp "$ROOT/scripts/simple-local-setup.sh" "$simple_dir/"
cat > "$simple_dir/local-setup.sh" <<'EOS'
#!/usr/bin/env bash
i=0
for arg in "$@"; do
  printf 'ARG_%s=%s\n' "$i" "$arg"
  i=$((i + 1))
done > "${SIMPLE_LOCAL_ARGS:?}"
EOS
chmod +x "$simple_dir/local-setup.sh"
HOME="$tmp/simple-forward-home" RH_COMMON="$simple_dir/_common.sh" \
  RH_SIMPLE_FORWARD_CACHE="$tmp/simple-forward-cache.env" \
  SIMPLE_LOCAL_ARGS="$tmp/simple-local.args" \
  bash "$simple_dir/simple-local-setup.sh" \
    --via "ssh -p 2200 dev@example.com" \
    --remote-path /srv/app \
    --mountpoint "$tmp/local-mount" \
    --launch codex \
    --yolo \
    --yes > "$tmp/simple-local.out"
assert_grep "$tmp/simple-local.out" "Server project:   /srv/app" "simple forward plan"
assert_grep "$tmp/simple-local.args" "ARG_0=--via" "simple forward handoff via flag"
assert_grep "$tmp/simple-local.args" "ARG_1=-p 2200 dev@example.com" "simple forward handoff strips leading ssh"
assert_grep "$tmp/simple-local.args" "ARG_2=--remote-path" "simple forward handoff remote path flag"
assert_grep "$tmp/simple-local.args" "ARG_3=/srv/app" "simple forward handoff remote path"
assert_grep "$tmp/simple-local.args" "ARG_5=codex" "simple forward handoff launch"
assert_grep "$tmp/simple-local.args" "ARG_6=--mountpoint" "simple forward handoff mountpoint flag"
assert_grep "$tmp/simple-local.args" "ARG_7=$tmp/local-mount" "simple forward handoff mountpoint"
assert_grep "$tmp/simple-local.args" "ARG_8=--yolo" "simple forward explicit yolo"
assert_grep "$tmp/simple-forward-cache.env" "LAST_VIA=-p 2200 dev@example.com" "simple forward cache via"
assert_grep "$tmp/simple-forward-cache.env" "LAST_REMOTE_PROJECT_DIR=/srv/app" "simple forward cache remote project"
assert_grep "$tmp/simple-forward-cache.env" "LAST_MOUNTPOINT=$tmp/local-mount" "simple forward cache mountpoint"
assert_grep "$tmp/simple-forward-cache.env" "LAST_LAUNCH=codex" "simple forward cache launch"
assert_grep "$tmp/simple-forward-cache.env" "LAST_YOLO=1" "simple forward cache yolo"
assert_grep "$ROOT/scripts/simple-local-setup.sh" 'if [ "$YOLO_REQUESTED" = 1 ]; then' "simple forward explicit yolo has no-reprompt branch"

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
HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  RH_SIMPLE_MODE_CACHE="$tmp/simple-mode-cache.env" \
  DISPATCH_MARKER="$tmp/dispatch-forward.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --mode "本地开发远程项目" --launch codex --yolo
assert_grep "$tmp/dispatch-forward.out" "FORWARD_ARGS=--launch codex --yolo" "dispatch forwards explicit mode"
assert_grep "$tmp/simple-mode-cache.env" "LAST_MODE=forward" "dispatch caches forward mode"
HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  RH_SIMPLE_MODE_CACHE="$tmp/simple-mode-cache.env" \
  DISPATCH_MARKER="$tmp/dispatch-cached.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --launch codex --yolo
assert_grep "$tmp/dispatch-cached.out" "FORWARD_ARGS=--launch codex --yolo" "dispatch uses cached mode without prompting"
HOME="$tmp/dispatch-home" RH_COMMON="$dispatch_dir/_common.sh" \
  RH_SIMPLE_MODE_CACHE="$tmp/simple-mode-cache.env" \
  DISPATCH_MARKER="$tmp/dispatch-reverse.out" \
  bash "$dispatch_dir/simple-dispatch.sh" --mode "远程开发本地" --launch codex --source-via sourcebox
assert_grep "$tmp/dispatch-reverse.out" "REVERSE_ARGS=--launch codex --via sourcebox" "dispatch passes source via only to reverse"
assert_grep "$tmp/simple-mode-cache.env" "LAST_MODE=reverse" "dispatch caches reverse mode"
assert_grep "$ROOT/scripts/simple-dispatch.sh" '_default="${1:-reverse}"' "dispatch defaults to reverse in prompt"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
has_n=0
for arg in "$@"; do [ "$arg" = "-n" ] && has_n=1; done
[ "$has_n" = 1 ] || cat >/dev/null
remote_cmd="${!#}"
case "$remote_cmd" in
  *'_common.sh'*) printf '#!/usr/bin/env bash\n'; exit 0;;
  *'simple-dispatch.sh'*)
    printf '#!/usr/bin/env bash\nprintf "STUB_ARGS=%%s\\n" "$*" > "${BOOTSTRAP_MARKER:?}"\n'
    exit 0
    ;;
  *) printf '#!/usr/bin/env bash\nexit 0\n'; exit 0;;
esac
EOS
chmod +x "$tmp/bin/ssh"
bootstrap_home="$tmp/bootstrap-home"
mkdir -p "$bootstrap_home"
HOME="$bootstrap_home" BOOTSTRAP_MARKER="$tmp/simple-bootstrap.marker" RH_VIA=testbox RH_SIMPLE_CACHE="$tmp/bootstrap-cache.env" PATH="$tmp/bin:$PATH" \
  bash -s -- --mode reverse --launch codex --yolo < "$ROOT/scripts/simple-bootstrap.sh" > "$tmp/simple-bootstrap.out"
assert_grep "$tmp/simple-bootstrap.out" "Fetching remote-harness simple setup" "simple bootstrap ran"
assert_grep "$tmp/simple-bootstrap.marker" "STUB_ARGS=--mode reverse --launch codex --yolo --source-via testbox" "simple bootstrap hands off through dispatcher after stdin-backed fetches"
assert_grep "$tmp/bootstrap-cache.env" "LAST_VIA=testbox" "simple bootstrap caches via"
[ -z "$(find "$bootstrap_home/.remote-harness/.sessions" -maxdepth 1 -type d -name 'bootstrap.*' -print -quit 2>/dev/null)" ] || fail "simple bootstrap temp dir was not cleaned"
assert_grep "$ROOT/scripts/simple-bootstrap.sh" "ssh -n -o ClearAllForwardings=yes" "simple bootstrap fetch ssh must not consume stdin"
assert_grep "$ROOT/scripts/simple-bootstrap.sh" "simple-dispatch.sh" "simple bootstrap fetches dispatcher"
assert_grep "$ROOT/scripts/simple-dispatch.sh" "--source-via" "simple dispatcher accepts bootstrap source"
assert_grep "$ROOT/SKILL.md" "simple-bootstrap.sh" "skill uses unified simple bootstrap"
assert_grep "$ROOT/SKILL.md" "docs/claude-multi-agent.md" "skill routes Claude multi-agent questions"
assert_grep "$ROOT/README.md" "git clone https://github.com/specialpointcentral/remote-harness.git" "README installs maintained fork"
if grep -F "git clone https://github.com/chenjh16/remote-harness.git" "$ROOT/README.md" >/dev/null; then
  fail "README manual install still clones upstream instead of the maintained fork"
fi
assert_grep "$ROOT/SKILL.md" "script itself may be local" "skill does not assume local scripts"
assert_grep "$ROOT/SKILL.md" "printf '%s' \"\$p\${d:+ [\$d]}: \" >/dev/tty" "skill fetch prompt is zsh-compatible"
assert_grep "$ROOT/SKILL.md" "IFS= read -r h </dev/tty || exit 2" "skill aborts when tty prompt cannot read"
if grep -F "read -r -p" "$ROOT/SKILL.md" "$ROOT/SKILL.cn.md" "$ROOT/docs/simple-flow.cn.md" >/dev/null; then
  fail "fetch command templates must not use read -p; zsh treats -p as coprocess"
fi
assert_grep "$ROOT/SKILL.md" "RH_VIA=\"\$h\" RH_LANG=<lang> bash -s -- <mode-arg> --launch <launch>" "skill uses compact fetched bootstrap handoff"
assert_grep "$ROOT/SKILL.md" "--mode reverse" "skill documents reverse mode arg"
assert_grep "$ROOT/SKILL.md" "--mode forward" "skill documents forward mode arg"
assert_grep "$ROOT/SKILL.md" "must not ask the user to confirm YOLO" "skill says explicit yolo is final"
assert_grep "$ROOT/SKILL.md" "source SSH target is only the remote-harness script source" "skill separates source host from forward project server"
assert_grep "$ROOT/SKILL.md" "本地开发远程项目" "skill documents short forward trigger"
assert_grep "$ROOT/SKILL.md" "远程开发本地" "skill documents short reverse trigger"
assert_grep "$ROOT/SKILL.md" "simple-dispatch.sh" "skill documents ambiguous dispatcher"
assert_grep "$ROOT/SKILL.md" "Files are read, written, edited, and searched" "skill documents local file work in simple forward"
assert_grep "$ROOT/SKILL.md" "remote-harness:reverse-auth:<tag>" "skill documents scoped reverse authorized_keys"
assert_grep "$ROOT/SKILL.md" "UserKnownHostsFile=\"\$s/known_hosts\"" "skill fetch command isolates known_hosts"
assert_grep "$ROOT/SKILL.md" "Protect local/client information" "skill documents local/client privacy boundary"
assert_grep "$ROOT/AGENTS.md" "Simple Reverse Rules" "agents docs carry simple reverse rules"
assert_grep "$ROOT/AGENTS.md" "Simple Forward Rules" "agents docs carry simple forward rules"
assert_grep "$ROOT/AGENTS.md" "Ambiguous Simple Mode" "agents docs carry ambiguous mode rules"
assert_grep "$ROOT/AGENTS.md" "compact but copyable" "agents docs carry bootstrap command shape"
assert_grep "$ROOT/AGENTS.md" "fields 1 and 2 are local/client data" "agents docs protect local/client ssh metadata"
assert_grep "$ROOT/AGENTS.md" "must not ask for YOLO confirmation again" "agents docs forbid yolo reprompt"
assert_grep "$ROOT/AGENTS.md" "script may live remotely" "agents docs forbid assuming local script install"
assert_grep "$ROOT/AGENTS.cn.md" "Simple Reverse 规则" "Chinese agents docs carry simple reverse rules"
assert_grep "$ROOT/AGENTS.cn.md" "紧凑但可复制" "Chinese agents docs carry bootstrap command shape"
assert_grep "$ROOT/AGENTS.cn.md" "第 1/2 字段是本地客户端数据" "Chinese agents docs protect local/client ssh metadata"
assert_grep "$ROOT/AGENTS.cn.md" "不得再二次询问" "Chinese agents docs forbid yolo reprompt"
assert_grep "$ROOT/AGENTS.cn.md" "Simple Forward 规则" "Chinese agents docs carry simple forward rules"
assert_grep "$ROOT/scripts/inject-rule.sh" "Safe local work is file-oriented" "inject rule allows local file work"

install_home="$tmp/install-home"
mkdir -p "$install_home"
HOME="$install_home" CODEX_HOME="$install_home/.codex" RH_HOME="$install_home/.remote-harness" \
  bash "$ROOT/manage.sh" codex > "$tmp/manage-install.out"
[ -f "$install_home/.remote-harness/docs/complete-flow.md" ] || fail "manage install did not copy shared docs"
[ -f "$install_home/.remote-harness/docs/claude-multi-agent.md" ] || fail "manage install did not copy Claude multi-agent docs"
[ -f "$install_home/.remote-harness/docs/claude-multi-agent.cn.md" ] || fail "manage install did not copy Chinese Claude multi-agent docs"
[ -f "$install_home/.remote-harness/docs/complete-flow.html" ] || fail "manage install did not copy HTML flow doc"
[ ! -e "$install_home/.remote-harness/docs/superpowers" ] || fail "manage install copied internal implementation plans"
[ -f "$install_home/.codex/skills/remote-harness/docs/complete-flow.md" ] || fail "codex copy install did not include docs"
[ -f "$install_home/.codex/skills/remote-harness/docs/claude-multi-agent.md" ] || fail "codex copy install did not include Claude multi-agent docs"
[ ! -e "$install_home/.codex/skills/remote-harness/docs/superpowers" ] || fail "codex copy install copied internal implementation plans"
[ -f "$install_home/.codex/skills/remote-harness/SKILL.cn.md" ] || fail "codex copy install did not include SKILL.cn.md"
[ -x "$install_home/.remote-harness/scripts/simple-bootstrap.sh" ] || fail "manage install did not install executable simple-bootstrap.sh"
[ -x "$install_home/.remote-harness/scripts/route-command.py" ] || fail "manage install did not install executable route-command.py"
[ -x "$install_home/.remote-harness/scripts/run-on-project-host.sh" ] || fail "manage install did not install project-host runner"

suggest_user="$(id -un)"
SSH_CONNECTION='198.51.100.10 55555 203.0.113.7 2222' \
  bash "$ROOT/scripts/suggest-via.sh" > "$tmp/suggest-via.out"
assert_grep "$tmp/suggest-via.out" "STATUS=ok" "suggest-via ok from SSH_CONNECTION"
assert_grep "$tmp/suggest-via.out" "VIA=-p 2222 $suggest_user@203.0.113.7" "suggest-via uses server address and port"
assert_grep "$tmp/suggest-via.out" "SOURCE=ssh_connection" "suggest-via records source"
if grep -F "198.51.100.10" "$tmp/suggest-via.out" >/dev/null; then
  fail "suggest-via leaked client/local SSH_CONNECTION field"
fi
SSH_CONNECTION='198.51.100.10 55555 203.0.113.7 22' \
  bash "$ROOT/scripts/suggest-via.sh" > "$tmp/suggest-via-22.out"
assert_grep "$tmp/suggest-via-22.out" "VIA=$suggest_user@203.0.113.7" "suggest-via omits default port 22"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
[ -n "${SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$SSH_LOG"
remote_cmd="${!#}"
for arg in "$@"; do
  case "$arg" in
    -N)
      printf 'open\n' > "${TUNNEL_STATE:?}"
      sleep 30
      exit 0
      ;;
  esac
done
case "$remote_cmd" in
  *'check-tunnel.sh'*) printf 'SSH=up\nLAPTOP_HOSTNAME=other-laptop\nLAPTOP_USER=other-user\n'; exit 0;;
  *'ssh -G'*) printf 'USER=chenjh\nIDENTITY=\n'; exit 0;;
  *'setup-tunnel.sh'*) printf '%s\n' "$remote_cmd" > "${SETUP_TUNNEL_LOG:?}"; exit 0;;
  *"grep -qx '32026'"*) exit 0;;
  *"grep -qx '32027'"*)
    [ "$(cat "${TUNNEL_STATE:?}" 2>/dev/null || true)" = open ] && exit 0 || exit 1
    ;;
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
if HOME="$conflict_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  TUNNEL_STATE="$conflict_state" SETUP_TUNNEL_LOG="$conflict_setup_log" SSH_LOG="$conflict_ssh_log" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32026 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote \
    --project-dir "$conflict_project" --launch codex --yes >"$tmp/tunnel-conflict.out" 2>"$tmp/tunnel-conflict.err"; then
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
for arg in "$@"; do
  case "$arg" in
    -N) printf 'unexpected ssh -N while reusable tunnel is up\n' >&2; exit 99;;
    *'check-tunnel.sh'*) printf 'SSH=up\n'; exit 0;;
    *'grep -qx'*) exit 0;;
    *'mount-project.sh'*) printf 'STATUS=mounted\nMOUNTPOINT=/tmp/rh-remote\n'; exit 0;;
    *'inject-rule.sh'*) printf 'RH_STATUS=INJECTED\nRH_LAUNCH_ENV=\nRH_LAUNCH_FLAGS=\n'; exit 0;;
  esac
done
exit 0
EOS
chmod +x "$tmp/bin/ssh"
proj_home="$tmp/project-dir-home"
valid_project="$tmp/valid project"
created_project="$tmp/created project"
file_project="$tmp/not-a-dir"
mkdir -p "$proj_home" "$valid_project"
printf 'x\n' > "$file_project"
HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" SSH_LOG="$ssh_log" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32023 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote \
    --project-dir "$valid_project" --launch codex --yes > "$tmp/project-valid.out"
assert_grep "$tmp/project-valid.out" "authorized_keys: temporarily authorized" "reverse authkey added"
assert_grep "$tmp/project-valid.out" "Project dir (from skill)" "project-dir valid accepted"
assert_grep "$tmp/project-valid.out" "Reusing existing reverse tunnel" "reuses live tunnel"
assert_grep "$ssh_log" "-tt -o ClearAllForwardings=yes" "phase5 forces remote tty"
assert_grep "$ROOT/scripts/laptop-setup.sh" "exec 3</dev/tty" "phase5 attaches stdin to controlling tty"
if grep -Eq -- '(^| )-N( |$)' "$ssh_log" 2>/dev/null; then
  fail "laptop-setup opened a new ssh -N despite reusable tunnel"
fi
if [ -f "$proj_home/.ssh/authorized_keys" ] && grep -F "remote-harness:reverse-auth:" "$proj_home/.ssh/authorized_keys" >/dev/null; then
  fail "temporary authorized_keys block was not cleaned"
fi
if [ -f "$proj_home/.ssh/authorized_keys" ] && grep -F "AAAAC3NzaC1lZDI1NTE5AAAAITest" "$proj_home/.ssh/authorized_keys" >/dev/null; then
  fail "temporary authorized_keys key was not cleaned"
fi

preauth_home="$tmp/preauth-home"
preauth_project="$tmp/preauth-project"
mkdir -p "$preauth_home/.ssh" "$preauth_project"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest existing-user-key\n' > "$preauth_home/.ssh/authorized_keys"
HOME="$preauth_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" SSH_LOG="$ssh_log" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32028 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote \
    --project-dir "$preauth_project" --launch codex --yes > "$tmp/project-preauth.out"
assert_grep "$tmp/project-preauth.out" "matching key already exists outside remote-harness" "existing authorized key reused"
assert_eq "existing authorized key not duplicated" "$(grep -F "AAAAC3NzaC1lZDI1NTE5AAAAITest" "$preauth_home/.ssh/authorized_keys" | wc -l | tr -d ' ')" "1"
if grep -F "remote-harness:reverse-auth:" "$preauth_home/.ssh/authorized_keys" >/dev/null; then
  fail "managed authorized_keys block added despite existing user key"
fi

HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" SSH_LOG="$ssh_log" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32024 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote \
    --project-dir "$created_project" --launch codex --yes >"$tmp/project-create.out" 2>"$tmp/project-create.err"
[ -d "$created_project" ] || fail "laptop-setup did not create missing project dir under --yes"
assert_grep "$tmp/project-create.err" "Created $created_project" "project-dir create path"
if HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" SSH_LOG="$ssh_log" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32025 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --box-ssh-config /home/box/.remote-harness/.sessions/test/ssh_config \
    --remote-mountpoint /tmp/rh-remote \
    --project-dir "$file_project" --launch codex --yes >"$tmp/project-file.out" 2>"$tmp/project-file.err"; then
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
st_out="$(HOME="$st_home" bash "$ROOT/scripts/setup-tunnel.sh" --config "$st_cfg_ns" --alias alice-mac --user alice --namespace alice --gen-key 2>/dev/null)"
st_port="$(printf '%s\n' "$st_out" | awk -F= '/^PORT=/{print $2}')"
case "$st_port" in *2) ;; *) fail "setup-tunnel hashed port should end in 2 (got '$st_port')";; esac
{ [ "$st_port" -ge 20002 ] && [ "$st_port" -le 29992 ]; } || fail "setup-tunnel hashed port out of [20002,29992] (got '$st_port')"
assert_grep "$st_cfg_ns" "Host alice-mac" "namespaced managed alias"
assert_grep "$st_cfg_ns" "    ControlMaster no" "setup-tunnel disables multiplexing"
assert_grep "$st_cfg_ns" "/runtime/known_hosts_alice-mac" "setup-tunnel separates mutable SSH runtime"
[ ! -e "$st_home/.ssh/config" ] || fail "setup-tunnel namespace wrote ~/.ssh/config"
[ ! -e "$st_home/.ssh/id_ed25519" ] || fail "setup-tunnel namespace generated key under ~/.ssh"
[ -f "$st_home/.remote-harness/keys/id_ed25519" ] || fail "setup-tunnel namespace did not generate key under ~/.remote-harness/keys"
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

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  doc_list() { git -C "$ROOT" ls-files --cached --others --exclude-standard '*.md'; }
else
  doc_list() { (cd "$ROOT" && find . -name '*.md' -type f | sed 's#^\./##'); }
fi
while IFS= read -r f; do
  [ -f "$ROOT/${f%.md}.cn.md" ] || fail "missing Chinese doc counterpart for $f"
done < <(doc_list | grep -v '^README.md$' | grep -v '^CLAUDE.md$' | grep -v '\.cn\.md$')

printf 'ok\n'
