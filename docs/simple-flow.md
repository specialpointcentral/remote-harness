# Simple Remote-Only Flow

> Chinese counterpart: [simple-flow.cn.md](simple-flow.cn.md).

## Contract

The maintained fork supports one topology:

- Claude, Codex, opencode, subagents, nested agents, and independent agent sessions run on the
  remote server.
- The local project is mounted on that server through SSHFS.
- Bash commands are returned through a forced SSH gateway and run inside the registered local
  project root.

Local-agent/forward requests are rejected before mounting or launching anything. An omitted mode
also selects reverse; there is no mode picker.

## Bootstrap

The public entry is `scripts/simple-bootstrap.sh`. It runs on the local machine. When the local
machine does not already have the helper bundle, the bootstrap fetches these scripts from the remote
remote-harness installation into a temporary directory under `~/.remote-harness/.sessions/...`.

The coding agent returns the bootstrap command immediately. Concrete SSH targets, local paths,
remote mountpoints, ports, and namespaces are collected by the local terminal rather than in the
agent conversation. A remote `scripts/suggest-via.sh` result may be used only as an editable default.

## Sequence

1. `simple-bootstrap.sh` invokes `simple-dispatch.sh`, which accepts reverse mode only.
2. `simple-laptop-setup.sh` collects the remote SSH target, local project directory, optional remote
   mountpoint, agent CLI, and approval mode.
3. The remote `setup-tunnel.sh` creates a session directory, session-local SSH config, known-hosts
   file, and a new per-session Ed25519 key.
4. `laptop-setup.sh` installs stable copies of `project-host-gateway.sh` and
   `run-on-project-host.sh` under local `~/.remote-harness/bin`.
5. The local project root is registered under
   `~/.remote-harness/.sessions/gateways/<session-tag>/project-root.b64`.
6. The per-session public key is added to local `~/.ssh/authorized_keys` inside a tagged managed
   block. Its line is limited to loopback tunnel sources, binds a forced gateway command, and
   disables PTY, port, X11, and SSH-agent forwarding.
7. The local SSH connection opens `RemoteForward <port> 127.0.0.1:22` to the remote server.
8. The remote server uses the session key and config to mount the selected local project with
   SSHFS.
9. For opencode, the remote CLI preloads the session plugin and must create its readiness marker.
   Failure aborts before the interactive Agent starts.
10. The selected agent is launched only on the remote server, inside the SSHFS mount.
11. Claude/Codex `PreToolUse` hooks or the opencode `tool.execute.before` plugin rewrite Bash to the
    session runner. The runner sends only `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`
    through the forced gateway.
12. The local dispatcher verifies the project root and physical cwd, removes common AI credential
    variables, shadows `claude`, `codex`, and `opencode` in `PATH`, then executes the project command
    with the local login shell.
13. Exit cleanup removes the mount, injected rules, remote session key/config/runtime directory,
    local gateway registration, temporary authorization, and local session config.

## Gateway Protocol

The forced local gateway accepts only:

- standard SFTP requests needed by SSHFS;
- `remote-harness-health`;
- the fixed `remote-harness-exec` request.

Arbitrary SSH commands are rejected. A matching key already authorized outside the managed forced
gateway block is also rejected, because that authorization would bypass the gateway.

## Multi-Agent Behavior

Claude ordinary, named, and nested subagents are created by the remote Claude process. Their Bash
calls inherit the same hook and return to the local project host. Named agents may use Claude's own
messaging features while staying remote.

Agent Teams are disabled because temporary settings inheritance is not guaranteed across independent
teammate sessions. Claude worktree creation is blocked because a remote Agent-host worktree has no
valid mapping to the registered local project root. For isolated parallel work, create local Git
worktrees and start one remote-harness session per worktree.

## Security Boundary

The forced gateway prevents the reverse key from opening an arbitrary local SSH shell. The hook and
dispatcher also reject direct Agent CLI launches, scrub common AI credentials, and shadow common
Agent binary names.

These controls are policy enforcement around an intentionally general project shell, not a complete
OS sandbox. An arbitrary shell is Turing-complete and SFTP is not chrooted to the selected project.
For an absolute no-local-Agent and project-only filesystem boundary, run the local SSH gateway under
a dedicated OS account that has access only to the intended project, has no Agent CLI installed, and
has no AI credentials.

## Preconditions

- The local machine can SSH to the remote server, and the remote server has remote-harness plus the
  selected Agent CLI installed.
- The local machine runs an SSH server.
- The remote server has SSHFS and FUSE.
- Strict Claude/Codex routing requires Python 3 on the remote Agent host. opencode requires its
  current `tool.execute.before` plugin interface.
- The local project host needs POSIX `sh`, a base64 decoder, and its project toolchain.
- The remote server's sshd permits reverse TCP forwarding.

For shared or long-lived servers, see
[ssh-sshfs-long-lived-connections.md](ssh-sshfs-long-lived-connections.md).
