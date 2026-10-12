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
- `run-on-project-host.sh`: validates and executes the local project command (in `watch` mode with
  `/dev/null` stdin, its own process group, and a channel-EOF watchdog), or runs an allowlisted
  `git`/`rg` directly (no shell, fixed PATH) and stops it when the SSH channel closes. Its client
  side sets per-connection keepalives and the optional multiplexing master.
- `project-host-gateway.sh`: forced SSH command accepting only SFTP, health, the fixed exec protocol,
  and the `git`/`rg` tool verb.
- `channel-guard.py`: wraps the session Bash runner when python3 exists; it holds the SSH channel
  open while the command runs so the project host stops the command tree on cancel or disconnect.
- `project-host-tool.py`: remote session PATH shim for `git` and `rg`. Work-tree scans inside the
  mount run on the project host with paths translated both ways; path discovery and calls outside the
  mount run the real remote tool. Routed calls share a concurrency cap (`RH_TOOL_CONCURRENCY`,
  default 6), retry once without the multiplexing master on a transport failure, and otherwise fail
  non-zero.
- `session-reaper.sh`: remote per-session watcher plus launch-time GC. When the agent process is
  gone (or its terminal was hung up), it stops the multiplexing master and leftover routed processes,
  unmounts the session mount unless another live session uses it, and removes the session dir and the
  session SSH config with its private key.
  Mount registration, launcher release and GC share a lock and track command versus actual SSHFS
  configs separately. Failed unmounts retain reconnect config and implementation. `release-config`
  reports `USED=0` only when the specific transport can be reclaimed; failure keeps local tunnel,
  config and authorization records for retry. Runtime entries use per-session `impl` copies; local
  gateway implementations use per-key copies.

Runtime state belongs under `~/.remote-harness/.sessions`. The only `~/.ssh` write is the tagged,
loopback-scoped, forced-command `authorized_keys` block. Session cleanup removes authorization,
gateway registration, remote private key, mount, hooks, and temporary configs. If the local side
dies first, the remote watcher or the next launch's GC performs the remote part of that cleanup;
the stale local `authorized_keys` block is then inert because its private key no longer exists.

The SFTP allowance is account-level rather than chrooted to the registered project. Use a dedicated
local OS account when project-only filesystem isolation is required.
