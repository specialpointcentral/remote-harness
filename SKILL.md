---
name: remote-harness
description: >-
  Connect a coding-agent session to a project on another machine without collecting concrete paths
  or credentials in chat. Supports simple reverse (agent on a remote box, project on the user's
  laptop) and simple forward (agent/Codex local, project and dev environment on an SSH server).
  Return one local bootstrap command that prompts in the user's terminal, mounts the project with
  sshfs, injects a run-on-the-project-host rule, and launches claude/codex/opencode in the mount.
---

# Remote Harness

Default mode is **simple reverse**. Use **simple forward** when the user explicitly asks for local
Codex/agent with a project or development environment on a remote server.

Infer the mode from short user wording:

- Simple forward: phrases such as "本地开发远程项目", "本地开发服务器项目", "local dev remote
  project", "local Codex with server project", or "project/dev environment on server".
- Simple reverse: phrases such as "远程开发本地", "远程开发本地项目", "远端开发本地", "remote dev
  local project", or "remote agent with laptop project".
- Ambiguous: when the wording does not clearly determine forward or reverse, return the
  unified command without `--mode`. The mode prompt defaults to reverse and is
  cached locally like the other simple choices.

## Modes

Simple reverse:

- The coding agent runs on a remote box.
- The codebase is on the user's laptop.
- The agent must not ask for local laptop details, local paths, remote mount paths, reverse ports, or
  namespaces.
- The agent may suggest a default remote SSH target using server-side facts only.
- The agent's whole job is to return one command plus a short explanation.
- The command prompts for all concrete values in the user's local terminal, not in chat.
- Protect local/client information. When deriving a default from `SSH_CONNECTION`, use only fields 3
  and 4 (`server-ip` / `server-port`). Never expose fields 1 and 2 (`client-ip` / `client-port`).
- The SSH prompt default is local cache first, then the server-side suggestion. It remains editable.

Simple forward:

- The coding agent runs locally.
- The project and dev environment live on a directly SSH-reachable server.
- The command prompts locally for the server SSH target, server project directory, optional local
  mountpoint, and launch preference.
- Files are read, written, edited, and searched in the local sshfs mount.
- For Claude/Codex, every Bash call is automatically routed to the server with mount-relative cwd
  mapping. Routing setup is fail-closed. opencode still follows an injected SSH instruction.

Use the unified simple bootstrap flow for reverse, forward, and ambiguous requests.

## Runtime

Set the launch CLI to the current agent runtime:

- Codex: `--launch codex`
- Claude Code: `--launch claude`
- opencode: `--launch opencode`

If the invocation asks for "yolo", "bypass approvals", "skip permissions", "危险模式", "免审批", or
"开启yolo模式", append `--yolo` to the final local command arguments. Otherwise do not add it.
When `--yolo` is added because the user asked for it, the local wizard treats that as the final
choice and must not ask the user to confirm YOLO/bypass mode again.
If the user asks in Chinese or requests Chinese, set `<lang>` to `zh`; otherwise set it to `en`.

For simple reverse only, before answering, if possible run:

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/suggest-via.sh"
```

Use its `VIA=` value as `<default_via>` only when `STATUS=ok`; otherwise omit the
`RH_DEFAULT_VIA=...` prefix. This value is only a prompt default. Do not include the helper output in
the response.

## What To Tell The User

### Unified Command

Return the same script entry point for reverse, forward, and ambiguous requests:
`scripts/simple-bootstrap.sh`. The command always runs locally, but the script itself may be local or
may need to be fetched from the remote machine where this skill is installed. Use a fenced `bash`
code block and do not put it in a bullet/numbered list. Optimize for copyability: keep the command
to a small number of short lines, and never make one long shell line that chat wrapping can split.
`simple-bootstrap.sh` delegates to `simple-dispatch.sh`; users do not call the dispatcher directly.

Use `--mode reverse` when the request clearly means remote agent + local laptop project. Use
`--mode forward` when the request clearly means local agent + server project. Omit `--mode` when the
request is ambiguous; the dispatcher prompts locally, defaults to reverse on first run, and caches
the mode choice.

If the user is already running the command on a machine that has remote-harness installed locally,
use the local form:

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  <mode-arg> --launch <launch>
```

If the skill/source directory is on a remote machine, or if local installation is uncertain, use the
fetch form. Replace `<source_prompt>` with `remote-harness source SSH target/args` or
`remote-harness 来源 SSH 目标/参数`, replace `<default_via>` with the server-side suggestion or an
empty string, and use the same `<mode-arg>` rules:

```bash
(
set -f
p='<source_prompt>'
d='<default_via>'
printf '%s' "$p${d:+ [$d]}: " >/dev/tty
IFS= read -r h </dev/tty || exit 2
h=${h:-$d}; h=${h#ssh }; [ -n "$h" ] || exit 2
mkdir -p "$HOME/.remote-harness/.sessions"
s=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit 1
trap 'rm -rf "$s"' EXIT
ssh -n -o ClearAllForwardings=yes \
  -o UserKnownHostsFile="$s/known_hosts" \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  -o ControlMaster=no -o ControlPath=none \
  $h \
  'cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"' |
  RH_VIA="$h" RH_LANG=<lang> bash -s -- <mode-arg> --launch <launch>
)
```

`<mode-arg>` is:

- `--mode reverse` for clear simple reverse;
- `--mode forward` for clear simple forward;
- omitted for ambiguous mode.

Append `--yolo` only when the invocation explicitly requested YOLO/bypass/no-approval mode. In the
fetch form, the source SSH target is only the remote-harness script source. Reverse mode reuses it as
the remote box target; forward mode still asks locally for the project server target.

The user should paste and run the command in a fresh local terminal.

### Simple Reverse

After the command starts, the terminal will ask for:

- the remote SSH target/args or Host alias, with the last local value as the default, otherwise the
  server-side suggestion;
- the local project directory;
- an optional remote mountpoint, blank for remote `~/.remote-harness/mounts/<project>`;
- whether to launch with YOLO/bypass mode, defaulting to yes unless the local cache says no. This
  question is skipped when the invocation already requested YOLO and the command includes `--yolo`.

The script uses a fixed per-session laptop alias (`rlocal`) by default. In the simple flow that
alias is written to a temporary ssh config on the remote box, under
`~/.remote-harness/.sessions/.../ssh_config`, and cleanup removes it at the end. It does not create
or modify any file under the remote box's `~/.ssh`. The laptop-side RemoteForward alias is also
session-local under local
`~/.remote-harness/.sessions/.../ssh_config`; it is hidden behind the setup script's ssh wrapper and
removed on exit. Temporary SSH configs and `known_hosts` live under
`~/.remote-harness/.sessions/...`; they are not written under the laptop's `~/.ssh`, and session
configs disable OpenSSH multiplexing.

For reverse authentication, the remote box generates or reuses a remote-harness key under its own
`~/.remote-harness/keys`. The local setup may add that public key to the laptop's
`~/.ssh/authorized_keys` in a tagged `remote-harness:reverse-auth:<tag>` block restricted to
loopback (`from="127.0.0.1,::1"`). It first checks for an existing active matching key and does not
append a duplicate. Managed entries are reference-counted under
`~/.remote-harness/.sessions/authorized-keys/...` and removed on exit when no active session still
uses them.

Claude/Codex receive a session-local `PreToolUse` hook and runner. The agent runs ordinary relative
commands; the hook maps the mount cwd to the laptop project and rewrites the Bash call. opencode
continues to receive the session-local `ssh` wrapper and explicit SSH instruction.

The script remembers the last confirmed values in local `~/.remote-harness/simple-cache.env` and
uses them as defaults next time. The cache is local-only; deleting that file resets the defaults.

No directory recommendation is part of the simple flow.

### Simple Forward

In forward mode, the terminal will ask for:

- the server SSH target/args or Host alias, with the last local value as the default;
- the server project directory, with the last local value as the default;
- an optional local mountpoint, blank for local `~/.remote-harness/mounts/<project>`;
- whether to launch with YOLO/bypass mode, defaulting to yes unless the local cache says no. This
  question is skipped when the invocation already requested YOLO and the command includes `--yolo`.

The launched agent works in the local mount. Claude/Codex file tools use the mount and every Bash
call is rewritten to the server; failure to create that route aborts launch. opencode keeps the
instruction-based SSH route. Exiting the launched agent unmounts the project and removes session
artifacts.

For Claude, ordinary, named, and nested subagents are supported because settings hooks continue to
run inside subagents. Strict sessions disable experimental Agent Teams and block Claude worktree
creation. For isolated parallel writers, create separate project-host Git worktrees and launch one
remote-harness session per worktree; those Claude sessions can coordinate through cross-session
messaging. Read `docs/claude-multi-agent.md` when the user asks for multiple Claude agents.

The forward setup always uses a session-local ssh config under local
`~/.remote-harness/.sessions/.../ssh_config`. When the user enters raw SSH args instead of a Host
alias, it creates a session-local `<host>-dev` alias there. It does not create or modify any file
under local `~/.ssh`; temporary `known_hosts` also stays under
`~/.remote-harness/.sessions/...`, and session configs disable OpenSSH multiplexing. The temp config
is hidden from the launched agent with the same session `ssh` wrapper pattern.

## Preconditions

- Script source: remote-harness is installed either locally at `~/.remote-harness` or on the SSH
  source machine used by the fetch command.
- Simple reverse: remote-harness is installed on the remote box at `~/.remote-harness`, or remote
  `RH_HOME` points to the install.
- Simple reverse: the laptop can SSH into the remote box using the user's already-configured key.
- Simple reverse: the remote box can authenticate back to the laptop through the reverse tunnel.
  The local setup can temporarily authorize the remote-harness public key in
  `~/.ssh/authorized_keys` as a tagged, loopback-scoped block, then remove it on exit. Existing
  active matching user keys are reused untouched.
- Simple reverse: the remote box has `sshfs` and the chosen agent CLI installed.
- Claude/Codex: the agent host has `python3`; the project host has POSIX `sh` and base64.
- Simple reverse: the laptop can run an SSH server; `laptop-setup.sh` will detect and guide enabling
  it when needed.
- Simple forward: the local machine can SSH into the server and has `sshfs`; the script guides
  installing sshfs when needed.
- Shared remote servers with many users or long-lived SSHFS mounts should tune sshd capacity,
  keepalive, file descriptor limits, and TCP queues. This is operationally recommended, not required
  for a single small session; see `docs/ssh-sshfs-long-lived-connections.md`.

## More Detail

The feasibility analysis and implementation plan live in:

- `docs/complete-flow.md`
- `docs/complete-flow.cn.md`
- `docs/complete-flow.html`
- `docs/claude-multi-agent.md`
- `docs/simple-flow.md`
- `docs/simple-flow.cn.md`
- `docs/simple-forward-flow.md`
- `docs/simple-forward-flow.cn.md`
- `docs/ssh-sshfs-long-lived-connections.md`
- `docs/ssh-sshfs-long-lived-connections.cn.md`
