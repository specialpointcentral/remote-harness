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
  While the agent session runs, a background supervisor checks the tunnel it created every 5 s and
  restarts it on the same port when its ssh exits (`ExitOnForwardFailure`; backoff 5, 10, 20, 30, 60 s
  between failed tries), keeping the resource record on the current ssh; it writes only `tunnel.log`
  (ssh errors in `tunnel.log.ssh`), stops by itself when the launcher is gone, and cleanup stops it
  first and adopts the tunnel it last started. A tunnel reused from another launch is not supervised.
  The session Host's keepalives tolerate `RH_KEEPALIVE_TIMEOUT` seconds (default 300) of silence.
- `simple-local-setup.sh`, `local-setup.sh`: compatibility stubs that reject local-agent execution.
- `setup-tunnel.sh`: creates remote session SSH config and a per-session key.
- `check-tunnel.sh`: checks the forced gateway through `remote-harness-health`.
- `mount-project.sh`: mounts the local project on the remote Agent host through SSHFS over one SFTP
  connection (`RH_SSHFS_MAX_CONNS>1` opts into parallel connections where sshfs supports them; on a
  ~360ms link they made concurrent lookups about 7x slower), and (libfuse sshfs) caches lookups,
  attributes and "no such file" answers in the kernel for `RH_SSHFS_CACHE_SECONDS` (default 20, `0`
  disables), because agents repeatedly probe the same `.git` paths; `auto_cache` keeps unchanged file
  contents across opens. An sshfs daemon that outlives its unmount is
  stopped only when its FUSE superblock is gone and either the unmount was clean (1s grace: the kernel
  already confirmed no open files) or the daemon itself has made no I/O progress for
  `RH_SSHFS_IDLE_SECONDS` (default 3; its ssh connections' keepalives do not count); its sftp ssh then
  exits on EOF. The kernel keeps a superblock listed under fusectl (`/sys/fs/fuse/connections/<dev>`)
  while any cwd, open file, mapping, other mount namespace, or blocked request still references the
  detached mount; the device number is read from `/proc/self/mountinfo` before detaching. Other
  processes' `/proc` links are not scanned: sshd and other non-dumpable processes hide them, and a lazily
  detached file no longer appears under the old mountpoint. Without a fusectl answer a lazily detached
  daemon is kept. A daemon still flushing writes is left running once `RH_SSHFS_SYNC_MAX_SECONDS`
  (default 120) passes. Without `/proc` nothing is stopped.
- `inject-rule.sh`: installs session instructions, Claude/Codex hooks or the opencode plugin, and the
  remote runner. opencode emits a readiness marker path that must be observed before launch.
  Its session directory is keyed by mountpoint plus the launch's session id, so relaunching the same
  project or cleaning up a dead launch never removes another live session's hook or runner.
  The rule tells the agent to reply in the language of the user's latest message, not that of the
  instructions, tool output, or project files, and every user turn repeats that as a one-line note: a
  `UserPromptSubmit` hook for Claude and Codex, and an `experimental.chat.messages.transform` plugin
  hook for opencode that adds it to the latest user message in memory only. The rule alone sits at
  the start of the context, so long English tool output used to pull replies into English.
- `route-command.py`: validates Agent/Bash calls, denies direct local agent launches, and maps cwd.
- `run-on-project-host.sh`: validates and executes the local project command (in `watch` mode with
  `/dev/null` stdin, its own process group, and a channel-EOF watchdog), or runs an allowlisted
  `git`/`rg` directly (no shell, fixed PATH) and stops it when the SSH channel closes. Its client
  side sets per-connection keepalives and the optional multiplexing master. `--find-tool <git|rg>`
  reports where the tool verb finds a tool; `laptop-setup.sh` uses it before launch to print ✓ or a ⚠
  with an install hint, because a missing tool makes the agent scan the project over SSHFS.
  For a bash or zsh `$SHELL`, project commands load a login shell snapshot instead of starting a login
  shell each time (200+ ms on hosts with a heavy profile). The first command captures what the profile
  leaves behind (exported variables, functions, shell options, umask, soft limits; never the AI
  credentials or per-connection values such as `SSH_CONNECTION`) into `shell-snapshot.sh` in the
  gateway session directory, and installs it only after it loads silently and completely. It is
  recaptured after 10 minutes or when a startup file (`~/.profile`, `~/.zprofile`, `/etc/profile.d`,
  ...) changes. A capture that fails or exceeds 30 s is recorded in `shell-snapshot.failed` and
  retried after 10 minutes or a startup file change; until then, and whenever the snapshot is
  unusable (another shell, unsafe permissions, another command capturing), the command runs as a
  login shell. A snapshot that fails to load at run time refuses that one command (status 125) and is
  discarded. `RH_SHELL_SNAPSHOT=off` at launch disables it. Either way the AI credentials are unset
  again after the profile. Not carried over: non-exported shell variables and zsh aliases (bash does
  not expand aliases in commands anyway).
- `project-host-gateway.sh`: forced SSH command accepting only SFTP, health, the fixed exec protocol,
  the `git`/`rg` tool verb, and `remote-harness-wait`, which prints `RH_WAIT_READY`, reads one complete
  exec or tool request line from the channel, acknowledges it with `RH_WAIT_GOT`, and handles it like
  the same SSH command. It passes its session directory to the exec dispatcher, overriding any
  client-supplied value.
- `channel-guard.py`: wraps the session Bash runner when python3 exists; it holds the SSH channel
  open while the command runs so the project host stops the command tree on cancel or disconnect.
  With `--warm SOCKET --warm-request LINE` (written by `rh-run`) it first sends the request on a warm
  channel and relays its output; a request whose complete line was not written runs on the ordinary
  path instead, and a written one without an acknowledgment fails with 255 (uncertain delivery,
  never retried). With `--slots-dir` the ordinary path holds a per-session slot:
  `RH_FOREGROUND_CONCURRENCY` (6), queued up to `RH_CHANNEL_QUEUE_SECONDS` (600) while it keeps asking
  the warm pool; `--background` (explicit background Bash, standalone connections, no pool) uses
  `RH_BACKGROUND_CONCURRENCY` (8) and `RH_BACKGROUND_QUEUE_SECONDS` (10).
- `warm_pool.py`: `serve` (started by `rh-session`, one per session) keeps channels open on the
  gateway's wait verb over its own multiplexed connection (`runtime/wm.<session id>`) and hands one
  to a client over `runtime/warm.<session id>` as file descriptors, then reports its exit status. The
  pool keeps `RH_WARM_MIN` (1) to `RH_WARM_READY_MAX` (2) ready channels, opens at most
  `RH_WARM_OPENING_MAX` (2) at once with an `RH_WARM_OPEN_TIMEOUT` (10 s) deadline, and holds at most
  `RH_WARM_MAX` channels including handed ones (9 for the system sshd; up to 16 with the user-mode
  sshd's `RH_SSHD_MAX_SESSIONS`). It shrinks after `RH_WARM_IDLE` (90 s) idle, renews a channel after
  `RH_WARM_MAX_AGE` (600 s), opens channels only over its master (`ProxyCommand=false`), backs off
  refused or failed openings, notices a dead tunnel in about 15 s (keepalive 5 s x 3), rebuilds a
  dead connection, stops for a gateway without the wait verb, drains handed commands and exits with
  its agent or session dir, and logs to `warm.log` in the session dir. `RH_WARM_MAX=0` turns it off.
  The module's client half (`claim`, `run`) uses only small standard-library modules.
- Transport settings (`scripts/_common.sh`): the warm pool, quota and queue values above, plus
  `RH_SSHD_MAX_SESSIONS` (32, the user-mode sshd's `MaxSessions`), are allowlisted numbers from the
  environment or the laptop's optional `~/.remote-harness/transport.conf` (`KEY=VALUE`, parsed, never
  sourced; the environment wins). `laptop-setup.sh` forwards all of them as an explicit `env` prefix
  and each session freezes them into `rh-run` and `rh-session`.
- `project-host-tool.py`: remote session PATH shim for `git` and `rg`. Work-tree scans inside the
  mount and read-only discovery (`rev-parse`, `config --get`, ...) run on the project host with paths
  translated both ways; git calls that write and calls outside the mount run the real remote tool. Routed calls share a concurrency cap (`RH_TOOL_CONCURRENCY`,
  default 6), try a warm channel first (`--warm-socket`), retry on the ordinary path after a transport
  failure without output, once more without the multiplexing master, and otherwise fail non-zero.
  rg translates search paths and path-valued options while preserving patterns, replacements and
  globs. Unknown/ambiguous options and agent-side program options (`--pre`, `--hostname-bin`) stay
  on the agent host during planning; transport failures never select that path. rg text always maps
  a leading project-root prefix, including `--vimgrep` output for a single absolute file. A content-only
  match beginning with that same prefix is ambiguous and receives the same mapping. JSON mapping
  decodes one whole record in memory and changes only `data.path.text` or its base64 `bytes` variant;
  content and match offsets retain their values, while JSON formatting may change. Git discovery
  paths are mapped one newline/NUL record at a time. rg text rewriting uses bounded memory. stderr
  captures at most 64 KiB for path mapping and retry decisions, then streams overflow unchanged;
  visible stdout or stderr prevents retries.
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
