# Remote-Only Complete Flow

> Chinese counterpart: [complete-flow.cn.md](complete-flow.cn.md).

1. The user invokes `$remote-harness` or `/remote-harness` on the remote server.
2. The skill returns a local `simple-bootstrap.sh --mode reverse` command.
3. The local wizard asks for the remote SSH target, local project, remote mountpoint, and approval mode.
4. The remote server creates a per-session SSH key and session-local `rlocal` config.
5. The local bootstrap installs `project-host-gateway.sh` and `run-on-project-host.sh` under
   `~/.remote-harness/.sessions/gateways/<session-tag>/bin`.
6. The local `authorized_keys` entry binds the session key to the forced gateway. An unrestricted
   matching authorization is rejected.
   With `RH_LOCAL_SSHD=user` that entry lives in a per-session sshd's private `authorized_keys`.
7. The local machine opens `RemoteForward <port> 127.0.0.1:22` to the remote server (or to the
   user-mode sshd's loopback port).
8. The local bootstrap registers the physical project root for this gateway session.
9. The remote server verifies `remote-harness-health`, then SSHFS-mounts the local project.
10. `inject-rule.sh` installs Claude/Codex hooks or the opencode session plugin plus `rh-run`.
11. opencode sessions preload the plugin and require its readiness marker; failure aborts launch.
12. The selected agent starts through `ssh -tt` on the remote server.
13. File tools use SSHFS. Bash uses `remote-harness-exec` and runs in the mapped local project cwd
    with the login shell's environment (a per-session snapshot for bash/zsh). Agent-internal `git`/`rg`
    scans use `remote-harness-tool`.
14. Agent/Spawn tools create remote subagents; they are not routed locally.
15. Cleanup releases this session's lease under the resource lock. The final user releases the
    mount and its transport; shared keys/configs/runtime/mux remain. Local records retain the
    tunnel and authorization until remote release can be verified and retry on later launches.

Runtime hooks, runners, shims and the watcher use the session's `impl` snapshot. Local gateway
implementations are also per-key snapshots. Development edits affect subsequent sessions.

The forward/local-agent flow is disabled and its compatibility entrypoints return an error before
performing work.

SFTP is account-level rather than chrooted to the registered project. A dedicated restricted local
OS account is required for an absolute project-only filesystem and no-local-Agent boundary.
