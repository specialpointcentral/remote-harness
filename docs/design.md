# remote-harness Remote-Only Design

> Chinese counterpart: [design.cn.md](design.cn.md).

## Roles

- **Agent host**: remote server. Every Claude, Codex, opencode, subagent, and independent agent
  process runs here.
- **Project host**: user's local machine. It stores the project and executes project commands.

Forward/local-agent mode is disabled. Compatibility entrypoints fail before doing work.

## Data Flow

```text
local bootstrap
  -> reverse SSH tunnel to remote server
  -> per-session remote SSH key
  -> local forced-command authorization
  -> SSHFS mount of local project on remote server
  -> remote Claude/Codex/opencode launch

remote file tools -> SSHFS -> local project files
remote Bash       -> Claude/Codex hook or opencode plugin -> rh-run -> forced gateway -> local command
remote Agent tool -> remote subagent process (never routed locally)
```

## Forced Gateway

The local `authorized_keys` entry binds the per-session key to
`project-host-gateway.sh <session-tag>` and disables PTY, port, X11, and agent forwarding. The
gateway accepts only:

- standard SFTP for SSHFS;
- `remote-harness-health`;
- `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`.

The gateway rejects arbitrary SSH shell commands and verifies that the requested project root
matches the root registered by the local bootstrap. A matching unrestricted user key is a fatal
configuration error rather than a reusable credential.

## Command Policy

`route-command.py` handles Claude/Codex. A generated opencode `tool.execute.before` plugin performs
the equivalent Bash and cwd rewrite for opencode. `run-on-project-host.sh` validates the physical
local cwd, rejects direct Agent CLI launches, removes common AI credential variables, shadows the
agent binaries in `PATH`, and executes with the project host's login shell.

This prevents the direct and common indirect local-agent paths. Arbitrary project shell is still
Turing-complete, and gateway SFTP is not chrooted to the registered project. An absolute security
boundary requires a dedicated local OS account with project-only access, no AI credentials, and no
Agent installation.

## Claude Multi-Agent

Ordinary, named, and nested Claude subagents stay on the remote Agent host. Settings hooks run in
those subagents, so only their Bash commands cross the gateway. Agent Teams and Claude worktree
creation are disabled. Isolated parallel agents use separate local Git worktrees and separate
reverse sessions on the remote server, coordinated with cross-session messaging.

## Session State

- Remote: SSH config, host keys, per-session private key, mount, hook, and runner under
  `~/.remote-harness/.sessions/...`.
- Local: temporary SSH config, forced authorization block, stable gateway binaries, and a
  per-session registered project root under `~/.remote-harness/.sessions/gateways/...`.

Cleanup removes session state and authorization. Stable gateway binaries remain installed for later
sessions.
