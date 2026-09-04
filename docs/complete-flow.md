# Remote-Only Complete Flow

> Chinese counterpart: [complete-flow.cn.md](complete-flow.cn.md).

1. The user invokes `$remote-harness` or `/remote-harness` on the remote server.
2. The skill returns a local `simple-bootstrap.sh --mode reverse` command.
3. The local wizard asks for the remote SSH target, local project, remote mountpoint, and approval mode.
4. The remote server creates a per-session SSH key and session-local `rlocal` config.
5. The local bootstrap installs `project-host-gateway.sh` and `run-on-project-host.sh` under
   `~/.remote-harness/bin`.
6. The local `authorized_keys` entry binds the session key to the forced gateway. An unrestricted
   matching authorization is rejected.
7. The local machine opens `RemoteForward <port> 127.0.0.1:22` to the remote server.
8. The local bootstrap registers the physical project root for this gateway session.
9. The remote server verifies `remote-harness-health`, then SSHFS-mounts the local project.
10. `inject-rule.sh` installs Claude/Codex hooks or the opencode session plugin plus `rh-run`.
11. opencode sessions preload the plugin and require its readiness marker; failure aborts launch.
12. The selected agent starts through `ssh -tt` on the remote server.
13. File tools use SSHFS. Bash uses `remote-harness-exec` and runs in the mapped local project cwd.
14. Agent/Spawn tools create remote subagents; they are not routed locally.
15. Cleanup removes the mount, remote key, temporary authorization, gateway registration, hooks,
    and temporary configs.

The forward/local-agent flow is disabled and its compatibility entrypoints return an error before
performing work.

SFTP is account-level rather than chrooted to the registered project. A dedicated restricted local
OS account is required for an absolute project-only filesystem and no-local-Agent boundary.
