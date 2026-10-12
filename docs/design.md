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
remote git/rg     -> session PATH shim -> (work-tree scan) forced gateway tool verb -> local git/rg
                                      -> (path discovery / outside mount) remote git/rg
remote Agent tool -> remote subagent process (never routed locally)
```

## Forced Gateway

The local `authorized_keys` entry binds the per-session key to
`project-host-gateway.sh <session-tag>` and disables PTY, port, X11, and agent forwarding. The
gateway accepts only:

- standard SFTP for SSHFS;
- `remote-harness-health`;
- `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`;
- `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`, where each argument is
  `base64("x" + arg)` joined by commas.

The gateway rejects arbitrary SSH shell commands and verifies that the requested project root
matches the root registered by the local bootstrap. A matching unrestricted user key is a fatal
configuration error rather than a reusable credential.

## Command Policy

`route-command.py` handles Claude/Codex. A generated opencode `tool.execute.before` plugin performs
the equivalent Bash and cwd rewrite for opencode. `run-on-project-host.sh` validates the physical
local cwd, rejects direct Agent CLI launches, removes common AI credential variables, shadows the
agent binaries in `PATH`, and executes with the project host's login shell.

When python3 is available on the remote host, `rh-run` runs through `channel-guard.py`, which holds
the SSH channel's stdin open for exactly as long as the call lives, and requests
`remote-harness-exec ... watch`. The project host then gives the command stdin from `/dev/null`,
starts it in its own process group (`setsid` on Linux, `perl` `setpgrp` on macOS), and treats EOF on
the channel as cancellation: a stopped or timed-out Bash call, a killed agent, or a dropped connection
sends TERM and, five seconds later, KILL to the command's process group and process tree. Processes
that deliberately detach (`nohup ... &`, `setsid`, daemons) are not followed. Without python3, or
with an older client that omits `watch`, execution is unchanged. The `git`/`rg` tool verb always uses
the same watchdog.

This prevents the direct and common indirect local-agent paths. Arbitrary project shell is still
Turing-complete, and gateway SFTP is not chrooted to the registered project. An absolute security
boundary requires a dedicated local OS account with project-only access, no AI credentials, and no
Agent installation.

## Internal Git And Search

PreToolUse hooks only see tool calls. Git status snapshots, file suggestions, Grep/Glob (through
`USE_BUILTIN_RIPGREP=0`), opencode search, status lines, and other internal `git`/`rg` processes go
through PATH shims generated per session (`project-host-tool.py`). Over SSHFS, these scans pay a
tunnel round trip for every lstat, directory read, and file read, so the shims run them on the
project host:

- routed: `git status|diff|diff-files|diff-index|diff-tree|log|show|shortlog|whatchanged|ls-files|
  ls-tree|grep|blame|rev-list` and `rg`, when the effective cwd is inside the mount;
- kept remote: path discovery (`rev-parse`, `config`, `branch`, ...), writes, calls with
  `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`, `--stdin`/`--batch`, and arguments naming existing
  remote paths outside the mount. Remote git on the mount gets `-c core.checkStat=minimal
  -c core.trustctime=false` so an index written on the project host does not force content reads;
- git config passed through the environment (`GIT_CONFIG_PARAMETERS`, which Claude Code sets on its
  internal calls, and `GIT_CONFIG_COUNT`/`KEY`/`VALUE`) is forwarded as `-c`; only an unparsable value
  keeps the call remote, so the session-start git snapshot never scans the whole tree over SSHFS;
- mount paths in arguments are mapped to the project root, and rg output records are mapped back;
- on the project host, the tool is exec'd without a shell from a fixed PATH and terminated when the
  SSH channel closes, so a cancelled caller or dropped link does not leave a scan running;
- a per-session cap (default 6 concurrent calls) keeps routed calls under the project host's sshd
  `MaxSessions`; a transport failure retries once without the multiplexing master and then fails
  non-zero, never as clean or no-match;
- a reachable project host that answers that the tool is not installed (for example a Mac without
  ripgrep) is recorded once per session, and that tool then runs on the remote host over the mount.
  This keeps Claude's Grep/Glob working; it is not a transport fallback;
- routed calls read the project host's Git configuration (global excludes, `core.autocrlf`, ...),
  while path discovery kept remote reads the remote user's global configuration plus the shared
  repository `.git/config`. Repository-level settings therefore agree; user-level ones may differ.

## Connections

Routed commands and tool calls pass, on the command line only, `ServerAliveInterval=10`,
`ServerAliveCountMax=3`, `ConnectTimeout=10`, `Compression=yes`, and a multiplexing master
(`ControlMaster=auto`, `ControlPersist=300`) whose socket lives in the session `runtime/` directory.
The master is skipped when that path is too long for a Unix socket. A dead tunnel ends the master
in about 30 seconds, an idle master exits after five minutes, a stale socket is replaced
automatically, and SSHFS keeps its own unshared connection.

## Abnormal Disconnects

The final agent launch runs through `rh-session`, which records the agent pid, start time, and
terminal and starts a detached `session-reaper.sh watch`. When the agent exits, or its terminal is
hung up while the agent lingers (the agent is then sent HUP, TERM, and KILL), the watcher waits a
short grace period for normal local cleanup and otherwise stops the multiplexing master, terminates
leftover routed processes, unmounts the session mount unless another live session uses it, and
removes the session dir plus the session SSH config and private key. Every `inject-rule.sh on` also
starts `session-reaper.sh gc`, which applies the same cleanup to dead sessions, never-launched
sessions older than 30 minutes, and orphan session SSH configs older than an hour. Once the private
key is gone, a stale local `authorized_keys` block can no longer be used.

Mount registration, launcher release and reaper/GC release share a resource lock. A lease records
both the command SSH config and actual SSHFS config; a reused mount retains its creator's transport
even when the new session uses another port. References are checked before unmounting, closing a
shared mux, or deleting a config/key/runtime. Failed unmounts keep their transport and cleanup
implementation for GC to retry. Unregistered live mounts are refused rather than replaced. Local
`resources.env` records retain the tunnel PID/start/config, gateway, authorization and local config
until remote release is confirmed. Later launches retry deferred cleanup; network or inspection
errors preserve resources. PID reuse cannot authorize tunnel kills.

Each injected session has an `impl` snapshot containing its router, guard, dispatcher, tool shim,
reaper and dependencies. Generated entries and the watcher use those copies. The implementation
directory is outside Codex's writable SSH runtime root. Local gateway implementations are also
snapshotted per reverse key. Development edits affect new sessions; existing sessions retain their
copies. Legacy sessions without a snapshot are not rewritten while running.

## Claude Multi-Agent

Ordinary, named, and nested Claude subagents stay on the remote Agent host. Settings hooks run in
those subagents, so only their Bash commands cross the gateway. Agent Teams and Claude worktree
creation are disabled. Isolated parallel agents use separate local Git worktrees and separate
reverse sessions on the remote server, coordinated with cross-session messaging.

## Session State

- Remote: SSH config, host keys, per-session private key, mount, hook, runner, tool shims,
  multiplexing socket, tool slots, and session/owner metadata under `~/.remote-harness/.sessions/...`.
- Local: temporary SSH config, forced authorization block, per-key gateway snapshots, and a
  per-session registered project root under `~/.remote-harness/.sessions/gateways/...`.

Cleanup removes state and authorization only after the final resource reference is gone. A retained
mount also retains its implementation snapshot; uncertain local cleanup keeps its resource record.
