---
name: remote-harness
description: >-
  Use when Claude, Codex, or opencode must run on a remote server while editing and executing against
  a project on the user's local machine. Return a reverse-only bootstrap command; never launch an
  agent on the local project host.
---

# Remote Harness

This fork is **remote-only**:

- Claude, Codex, opencode, their subagents, and independent agent sessions run on the remote server.
- The project remains on the user's local machine.
- File tools operate through an SSHFS mount on the remote server.
- Bash commands are routed through Claude/Codex hooks or an opencode session plugin, then through a
  forced project-host gateway to the local project environment.
- Public and compatibility forward entries refuse to launch an agent locally.

Use reverse mode for clear or ambiguous requests. If the user asks for a local agent, explain that
this fork intentionally does not support that topology.

## Runtime

Select the remote agent CLI:

- Codex: `--launch codex`
- Claude Code: `--launch claude`
- opencode: `--launch opencode`

Append `--yolo` only when the user explicitly requests bypass/no-approval mode. Use `RH_LANG=zh`
for Chinese and `RH_LANG=en` otherwise.

For reverse requests, obtain a server-side SSH suggestion when possible:

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/suggest-via.sh"
```

Use `VIA=` only when the helper returns `STATUS=ok`. It is an editable prompt default, never a
silent connection choice. Never expose the client address/port fields from `SSH_CONNECTION`.

## Command To Return

If remote-harness is installed on the user's local machine:

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch <launch>
```

If the skill is installed only on the remote server, return this fetch form. Fill
`<source_prompt>`, `<default_via>`, `<lang>`, and `<launch>`; append `--yolo` only when requested.

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
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode reverse --launch <launch>
)
```

Tell the user to run the command in a fresh local terminal. All concrete SSH targets, project paths,
mountpoints, and approvals are collected there rather than in agent chat.

## Strict Execution Boundary

The local bootstrap:

1. Creates a reverse SSH tunnel from the local machine to the remote server.
2. Creates a per-session remote SSH key.
3. Adds that key locally only with a forced-command project-host gateway.
4. SSHFS-mounts the selected local project on the remote server.
5. Launches the selected agent on the remote server.
6. Routes Bash through `remote-harness-exec`; arbitrary local SSH shell commands are rejected.
7. Removes the mount, per-session key, authorization, gateway registration, and temporary configs.

The command router or opencode plugin rewrites Bash before execution. The local dispatcher rejects
direct `claude`, `codex`, and `opencode` launches, scrubs common AI credential variables, and shadows
those binaries in `PATH`. These are defense-in-depth controls; arbitrary project shell code is still
Turing-complete, and SFTP is not a project chroot. An absolute guarantee requires running the
project-host gateway under a dedicated OS account that has no AI credentials or agent installation
and can access only the intended project.

## Claude Multi-Agent

Ordinary, named, and nested Claude subagents are supported. Claude settings hooks continue inside
subagents, so their Bash commands use the same remote-to-local command route. Named subagents may
communicate with `SendMessage`; messages do not grant permissions.

Strict sessions disable Agent Teams and block Claude worktree creation. For isolated parallel work:

- create separate Git worktrees on the local project host;
- launch one reverse remote-harness session per worktree on the remote server;
- coordinate those remote Claude sessions with cross-session messaging.

Read `docs/claude-multi-agent.md` for the full boundary.

## Preconditions

- remote-harness and the selected agent CLI are installed on the remote server;
- the local machine can SSH to the remote server;
- the remote server has SSHFS; Claude/Codex also require Python 3, while opencode requires its
  current `tool.execute.before` plugin interface;
- the local machine runs an SSH server and has POSIX `sh` plus base64;
- the remote server is trusted with the mounted project content;
- no unrestricted authorization for the generated session key already exists locally.

## References

- `docs/claude-multi-agent.md`
- `docs/design.md`
- `docs/complete-flow.md`
- `docs/simple-flow.md`
- `reference/reverse.md`
- `reference/scripts.md`
