# Helper Scripts

- `simple-bootstrap.sh`: public local entry; fetches reverse helpers when the skill exists only remotely.
- `simple-dispatch.sh`: reverse-only dispatcher; rejects forward.
- `simple-laptop-setup.sh`: local reverse wizard.
- `laptop-setup.sh`: creates the reverse tunnel, forced authorization, mount, remote agent, and cleanup.
- `simple-local-setup.sh`, `local-setup.sh`: compatibility stubs that reject local-agent execution.
- `setup-tunnel.sh`: creates remote session SSH config and a per-session key.
- `check-tunnel.sh`: checks the forced gateway through `remote-harness-health`.
- `mount-project.sh`: mounts the local project on the remote Agent host through SSHFS.
- `inject-rule.sh`: installs session instructions, Claude/Codex hooks or the opencode plugin, and the
  remote runner. opencode emits a readiness marker path that must be observed before launch.
  Its session directory is keyed by mountpoint plus the launch's session id, so relaunching the same
  project or cleaning up a dead launch never removes another live session's hook or runner.
- `route-command.py`: validates Agent/Bash calls, denies direct local agent launches, and maps cwd.
- `run-on-project-host.sh`: validates and executes the local project command.
- `project-host-gateway.sh`: forced SSH command accepting only SFTP, health, and fixed exec protocol.

Runtime state belongs under `~/.remote-harness/.sessions`. The only `~/.ssh` write is the tagged,
loopback-scoped, forced-command `authorized_keys` block. Session cleanup removes authorization,
gateway registration, remote private key, mount, hooks, and temporary configs.

The SFTP allowance is account-level rather than chrooted to the registered project. Use a dedicated
local OS account when project-only filesystem isolation is required.
