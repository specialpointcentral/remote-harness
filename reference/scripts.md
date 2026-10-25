# Helper Scripts

- `simple-bootstrap.sh`: public local entry; fetches reverse helpers when the skill exists only remotely.
- `simple-dispatch.sh`: reverse-only dispatcher; rejects forward.
- `simple-laptop-setup.sh`: local reverse wizard. A remembered remote mountpoint is offered only for the
  project it was chosen for; otherwise the default is auto (`~/.remote-harness/mounts/<project dir name>`).
  `--local-sshd auto|system|user` (or `RH_LOCAL_SSHD`) picks the SSH server the tunnel reaches; auto
  offers the user-mode sshd when the system sshd uses `AuthorizedKeysCommand` or nothing listens on `:22`.
- `laptop-setup.sh`: creates the reverse tunnel, forced authorization, mount, remote agent, and cleanup.
  After the local checks it opens a command-line-only multiplexing master (short `/tmp/rh.*` socket,
  `ControlPersist=300`) so later setup calls and cleanup skip the per-connection SSH handshake; the
  reverse tunnel and the interactive agent session keep their own connections, and the agent's remote
  pty is given the local terminal size before launch. With `--local-sshd user` it starts a per-session
  loopback sshd as the current user (helpers `user_sshd_*` in `_common.sh`) and forwards the tunnel to it.
- `simple-local-setup.sh`, `local-setup.sh`: compatibility stubs that reject local-agent execution.
- `setup-tunnel.sh`: creates remote session SSH config and a per-session key.
- `check-tunnel.sh`: checks the forced gateway through `remote-harness-health`.
- `mount-project.sh`: mounts the local project on the remote Agent host through SSHFS over one SFTP
  connection (`RH_SSHFS_MAX_CONNS>1` opts into parallel connections where sshfs supports them; on a
  ~360ms link they made concurrent lookups about 7x slower), and (libfuse sshfs) caches lookups,
  attributes and "no such file" answers in the kernel for `RH_SSHFS_CACHE_SECONDS` (default 20, `0`
  disables), because agents repeatedly probe the same `.git` paths; `auto_cache` keeps unchanged file
  contents across opens. An sshfs daemon that outlives its unmount is
  stopped only when nothing uses the mountpoint and either the unmount was clean (1s grace: the kernel
  already confirmed no open files) or the daemon itself has made no I/O progress for
  `RH_SSHFS_IDLE_SECONDS` (default 3; its ssh connections' keepalives do not count); its sftp ssh then
  exits on EOF. A daemon still flushing writes is left running once `RH_SSHFS_SYNC_MAX_SECONDS`
  (default 120) passes. Without `/proc` nothing is stopped.
- `inject-rule.sh`: installs session instructions, Claude/Codex hooks or the opencode plugin, and the
  remote runner. opencode emits a readiness marker path that must be observed before launch.
  Its session directory is keyed by mountpoint plus the launch's session id, so relaunching the same
  project or cleaning up a dead launch never removes another live session's hook or runner.
  With `RH_LANG=zh` (forwarded by `laptop-setup.sh`) the rule also tells the agent to reply in
  Simplified Chinese.
- `route-command.py`: validates Agent/Bash calls, denies direct local agent launches, and maps cwd.
- `run-on-project-host.sh`: validates and executes the local project command (in `watch` mode with
  `/dev/null` stdin, its own process group, and a channel-EOF watchdog), or runs an allowlisted
  `git`/`rg` directly (no shell, fixed PATH) and stops it when the SSH channel closes. Its client
  side sets per-connection keepalives and the optional multiplexing master. `--find-tool <git|rg>`
  reports where the tool verb finds a tool; `laptop-setup.sh` uses it before launch to print ✓ or a ⚠
  with an install hint, because a missing tool makes the agent scan the project over SSHFS.
- `project-host-gateway.sh`: forced SSH command accepting only SFTP, health, the fixed exec protocol,
  and the `git`/`rg` tool verb.
- `channel-guard.py`: wraps the session Bash runner when python3 exists; it holds the SSH channel
  open while the command runs so the project host stops the command tree on cancel or disconnect.
- `project-host-tool.py`: remote session PATH shim for `git` and `rg`. Work-tree scans inside the
  mount and read-only discovery (`rev-parse`, `config --get`, ...) run on the project host with paths
  translated both ways; git calls that write and calls outside the mount run the real remote tool. Routed calls share a concurrency cap (`RH_TOOL_CONCURRENCY`,
  default 6), retry once without the multiplexing master on a transport failure, and otherwise fail
  non-zero.
- `session-reaper.sh`: remote per-session watcher plus launch-time GC. When the agent process is
  gone (or its terminal was hung up), it stops the multiplexing master and leftover routed processes,
  unmounts the session mount unless another live session uses it, and removes the session dir and the
  session SSH config with its private key. A heartbeat through the tunnel ends the agent after
  `RH_HEARTBEAT_TIMEOUT` seconds of failed checks; disconnects leave a `.resume` marker that
  `inject-rule.sh on` reports once as `RH_RESUME_AVAILABLE=<reason>,<epoch>`. An agent that exits by
  itself while the project host is unreachable (as on SIGHUP) leaves the marker too (`exited`).
  `laptop-setup.sh` keeps a local marker when the interactive ssh exits 255 and offers resume from
  either one.
  Mount registration, launcher release and GC share a lock and track command versus actual SSHFS
  configs separately. Failed unmounts retain reconnect config and implementation. `release-config`
  reports `USED=0` only when the specific transport can be reclaimed; an sshfs daemon (or its sftp ssh)
  counts as using a config only while its mountpoint is still mounted. Failure keeps local tunnel,
  config and authorization records for retry. Runtime entries use per-session `impl` copies; local
  gateway implementations use per-key copies.

Runtime state belongs under `~/.remote-harness/.sessions`. The only `~/.ssh` write is the tagged,
loopback-scoped, forced-command `authorized_keys` block (none with the user-mode sshd, whose
authorization lives in its session directory). Session cleanup removes authorization,
gateway registration, remote private key, mount, hooks, and temporary configs. If the local side
dies first, the remote watcher or the next launch's GC performs the remote part of that cleanup;
the stale local `authorized_keys` block is then inert because its private key no longer exists.

The SFTP allowance is account-level rather than chrooted to the registered project. Use a dedicated
local OS account when project-only filesystem isolation is required.
