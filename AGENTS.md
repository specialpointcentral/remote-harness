# AGENTS.md - remote-harness maintainer guide

This repository is the remote-only remote-harness skill. Claude, Codex, subagents, and independent
agent sessions run on a remote server. The user's local machine is only the project host:
it provides files over SSHFS and executes project commands through a forced gateway.

## Repository Layout

- `SKILL.md`: reverse-only skill entry.
- `scripts/simple-bootstrap.sh`: public local bootstrap; it may fetch helpers from the remote.
- `scripts/simple-dispatch.sh`: accepts reverse only; forward is rejected.
- `scripts/simple-laptop-setup.sh` / `laptop-setup.sh`: local reverse orchestration.
- `scripts/simple-local-setup.sh` / `local-setup.sh`: permanent local-agent rejection stubs.
- `scripts/project-host-gateway.sh`: forced SSH command accepting only SFTP, health, exec, and the
  allowlisted `git`/`rg` tool verb.
- `scripts/route-command.py`: Claude/Codex hook policy and cwd mapping.
- `scripts/inject-rule.sh`: generates each session's settings, hooks, runner and shims.
- `scripts/run-on-project-host.sh`: validated local project command and tool dispatcher.
- `scripts/project-host-tool.py`: remote session `git`/`rg` PATH shim for work-tree scans.
- `scripts/session-reaper.sh`: remote watcher/GC for sessions whose local cleanup never ran.
- `scripts/paseo-session.mjs` / `orca-session.py` create native Claude and Codex chats.
  `paseo-guard.py` / `orca-claude.py` protect Claude tool calls. `native-codex.py` binds the
  Codex app server to the chat's private lease, and `codex-project-tools.py` provides its routed tools.
- `scripts/channel-guard.py`: holds a routed Bash command's SSH channel open for its lifetime.
- `scripts/warm_pool.py`: per-session pool of channels opened ahead of time on the gateway's wait
  verb (`serve`), and the client half channel-guard and the tool shim use.
- `reference/` and `docs/`: English Markdown has matching `.cn.md` documentation.

## Simple Reverse Rules

- Every public command uses `simple-bootstrap.sh --mode reverse`.
- Never add a local-agent or forward launch path. Compatibility forward scripts fail before
  mounting, connecting, or launching anything.
- The command is local, but the script may live remotely. The fetch form stays compact but copyable
  and retrieves every local-side reverse helper.
- Concrete SSH targets, local paths, mountpoints, and approvals are collected in the local terminal.
- If deriving an SSH default from `SSH_CONNECTION`, fields 1 and 2 are local/client data and must
  never be emitted; only server fields 3 and 4 are allowed.
- An explicit approval mode (`--approval auto|normal|yolo`, or `--yolo`) is final: the wizard must
  not ask for it again. Otherwise it asks, defaulting to the last choice or auto; auto uses the
  remote CLI's automatic review (`claude --permission-mode auto`, `codex --approve-for-me`) and falls
  back to normal approvals where the CLI lacks it.
- `laptop-setup.sh` remains standalone with its sibling helpers fetched beside it.
- The terminal path starts the main agent through `ssh -tt <remote> ... <claude|codex>`.
  opencode is no longer supported: every entry refuses `--launch opencode`.
  With Claude and `--ui paseo`, the same SSH session owns the Harness bridge while the same-host
  Paseo daemon starts the main agent with the injected settings. The bridge revokes its lease
  before archive and exit. An all-tool hook blocks a stale Paseo agent after transport cleanup.
- With `--ui orca`, the bridge owns one reserved mount and creates a native chat on the
  same-host Orca Server. The configured wrapper binds the chat identity and mount to a lease.
  Keep the identity and mount reservations across cleanup: an ended chat never acquires a route by
  itself. Only a launch of the same agent that claims it in the local terminal
  (`orca-session.py claim`) continues it at its own mount; the bridge reopens the chat, or for
  Claude resumes its conversation in a new chat when Orca no longer has it. A terminal Claude
  launch may claim an ended Claude chat too (`claim ... terminal`) and resume its conversation at
  that mount itself. An Orca Claude launch may instead adopt an ended terminal conversation of the
  project (`orca-session.py adopt`): Orca resumes only a transcript whose cwd is the chat's folder,
  so adopt copies it under a new session ID with the cwds moved to the new mount, and the copy
  becomes the identity of the new chat. Terminal conversations are offered only while the
  project's default mount is unused, and an adopted one again only after it changes. An Orca Codex chat's
  thread and rollouts live in `.orca-codex-chats/<chat>.state` (the session `codex-home` links
  `sessions` there); its credential copy stays in the session.
  The bridge adopts a restarted Orca Server only after it passes the startup checks again, and both
  wrappers refuse a bound chat launched by an unsupported Orca build (`ORCA_APP_VERSION`). A build
  outside `ORCA_VERSIONS` is supported only as a newer patch of a listed major.minor, with a
  launcher warning; codex-cli follows the same rule with `CODEX_VERSIONS`.
- The launcher appends each agent launch's start and end reason to the laptop's
  `~/.remote-harness/launches.log`, and the next launch of the project reports an abnormal end.
  Native bridges exit 0 when their chat was closed in the app, 128 + the signal that stopped them,
  and the Orca bridge 3 after losing Orca Server; the launcher maps these statuses to reasons.
- With Codex and either native UI, the configured wrapper starts a private stdio app server with
  built-in shell and code execution disabled. The app server enforces native approval on the
  private MCP command tool. The command tool checks the lease, gateway policy and Codex rules
  before running the project-host runner. Native file edits use the mount. The app server stops
  when the bridge lease ends, and old sessions cannot resume with a different mount or account.
- Claude/Codex shell commands route locally. Agent/Spawn tools stay on the remote host.
- Claude requires 2.1.295+ and its routing hook must set `onFailure: "block"`; a cancelled or broken
  hook must never let the original Bash command run on the agent host. Generated session settings
  keep hooks enabled even when project settings set `disableAllHooks`. Routing hook budgets exceed
  the inner command-policy timeout. New settings require a new harness session.
- The Claude hook never returns a permission decision for a routed call: `allow` skips Claude's
  prompt and auto-mode classifier. It rewrites to the readable `rh-run --cwd <dir> -- <command>` so
  the user's approval mode judges the original command. The terminal Codex hook writes the same
  form; Codex accepts `updatedInput` only with `allow`, which keeps its own approval.
  The session settings add an `autoMode.environment` entry that names the runner and asks the
  classifier to judge the quoted command, not the wrapper. It never adds an allow rule. It brings
  `"$defaults"` only when no user or managed environment exists at session start. Away from the
  project's default mount, the settings also point `autoMemoryDirectory` at that mount's memory
  directory, unless the user or managed settings set one.
- Since Claude sees only rh-run, its hook applies the user's own rules to the original command:
  `Bash(...)` deny/ask on any simple command the shared lexer finds, allow only for a plain single
  command in default/acceptEdits/dontAsk mode (never auto). Rule files are re-read only when their
  identity changes. Terminal Codex checks the original itself: its rewrite repeats it on a new line
  after `exit`, which the shell never parses, and Codex's exec policy (`.rules`, forced `rm`) reads it.
- Claude sessions deny Read/Edit on `$RH_HOME/.sessions` and Read on `/proc`. `rh-session` blanks the
  laptop's address and port in `SSH_CONNECTION`/`SSH_CLIENT`. Linux sshfs mounts use
  `fsname=remote-harness` and keep their source in the mount record; `mounts` is owner-only. Shim
  stderr maps the project root back to the mount.

## Gateway Security

- Generate a separate reverse key under each remote session directory.
- Local authorization includes `command="...project-host-gateway..."`, loopback source limits,
  no PTY, no port forwarding, no X11, and no agent forwarding.
- Refuse a session key already present in an unrestricted user authorization line.
- `RH_LOCAL_SSHD=user` (`--local-sshd user`) replaces the system sshd with a per-session sshd run as
  the user: loopback only, a probed free port with bind retry, the same forced-gateway line in a
  session-private `authorized_keys`, `AuthorizedKeysCommand none`, public keys only, no PAM,
  forwarding, or TTY. It is for FreeIPA/sssd-style hosts whose sshd ignores `~/.ssh/authorized_keys`,
  and it stops with the tunnel's resource record.
- The gateway accepts only standard SFTP, `remote-harness-health`,
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`,
  `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`, and `remote-harness-wait`; the tool
  verb execs the binary directly (no shell, fixed PATH). Watched exec and the tool verb give the
  command `/dev/null` stdin and stop its process group and tree when the SSH channel closes.
- `remote-harness-wait` (the agent host's warm channel pool, `warm_pool.py`) prints
  `RH_WAIT_READY`, reads exactly one complete line that must itself be an exec or tool request,
  acknowledges it with `RH_WAIT_GOT` before anything runs, and handles it through the same checks
  and dispatcher. It never accepts health, SFTP, or another wait. Clients send a request on the
  ordinary path only when it was provably not delivered (the complete line could not be written).
  A completely written line without an acknowledgment has uncertain delivery: Bash fails with 255
  and is never retried; only read-only git/rg calls may run again.
- Transport capacity settings (`RH_WARM_*`, `RH_SSHD_MAX_SESSIONS`, Bash/tool quotas and queue
  waits) are allowlisted numbers from the environment or `~/.remote-harness/transport.conf`, which is
  parsed, never sourced. The launcher forwards them explicitly as an `env` prefix and each session
  freezes them in its runner and launcher.
- The registered physical project root must match every exec request.
- Reject direct local launches of `claude`, `codex`, and `opencode` in both hook and dispatcher;
  scrub common AI credentials and shadow those binaries in the local command PATH.
- Routed bash/zsh commands load the session's login shell snapshot (gateway session dir, private,
  validated before use, never holding AI credentials) instead of starting a login shell; every
  failure path falls back to `$SHELL -lc`. Credentials are unset again after the profile either way.
- Arbitrary project shell is Turing-complete. Absolute isolation requires a dedicated local OS
  account without AI credentials or agent installations.

## Internal Git And Search

- Agent-internal `git`/`rg` calls never pass through PreToolUse hooks. Session PATH shims route
  work-tree scans (`status`, `diff`, `log`, `ls-files`, `grep`, `rg`, ...) and read-only repository
  discovery (`rev-parse`, `config --get`, `branch --show-current`, `symbolic-ref`, ...) to the project
  host, mapping absolute project-host paths in discovery output back to the mount; git calls that
  write stay on the remote host.
- Calls outside the mount, or naming another repository/index, run the real tool unchanged.
- Claude sessions default `CLAUDE_CODE_BASH_EDIT_DIFF` to `0` (a value exported by the remote login
  shell wins): its per-directory inotify watcher cannot see routed changes and stalls on SSHFS.
- A routed call that cannot reach the project host fails non-zero; it never reports clean or
  no-match and never falls back to scanning SSHFS. Only an explicit "tool not installed" answer
  from a reachable project host switches that tool to the remote host for the rest of the session.
- Routed calls share a per-session concurrency cap and a short-lived OpenSSH multiplexing master
  passed on the command line only; generated `ssh_config` files keep `ControlMaster no`.

## Claude Multi-Agent

- Ordinary, named, and nested subagents inherit settings hooks.
- Agent Teams and Claude worktree creation stay disabled.
- Isolated parallel agents use separate local Git worktrees plus separate reverse harness sessions;
  all Claude processes remain on the remote server and may use cross-session messaging.

## Invariants

1. Shell-quote every value interpolated into a remote command; never `eval` user SSH input.
2. Session SSH config and mutable host-key state stay under `~/.remote-harness/.sessions`.
3. Only the tagged forced-gateway `authorized_keys` block may change under `~/.ssh`; user-mode sshd
   changes nothing there.
4. Cleanup removes mounts, per-session remote keys, gateway registration, authorization, hooks,
   and temporary SSH state. When local cleanup cannot run, the remote session watcher and the next
   launch's GC reap dead sessions; they only touch `$RH_HOME/.sessions` children and never unmount a
   mount another live session uses. The watcher ends an agent only after the tunnel heartbeat has
   failed for the whole `RH_HEARTBEAT_TIMEOUT`, and local cleanup stops a tunnel without a remote
   answer only when this launch created it and the remote stayed unreachable through the retries.
   During the session the launcher's supervisor restarts only a tunnel this launch created, on the
   same port, records each restart, and is stopped (its tunnel adopted) before any cleanup step.
5. Programmatically consumed scripts retain `KEY=VALUE` stdout.
6. Keep bilingual Markdown pairs synchronized.

## Verification

```bash
for script in manage.sh tests/*.sh scripts/*.sh; do bash -n "$script" || exit 1; done
python3 -m py_compile scripts/*.py tests/*.py tests/fixtures/*.py
bash tests/regression.sh
git diff --check
```

With sshfs and FUSE installed (FUSE-T on macOS), run the regression with `RH_TEST_REAL_SSHFS=1`, as
CI does: the real local-SFTP mount tests then fail instead of skipping when they cannot run.

The full remote-server-to-local-project SSHFS flow remains a manual integration test. Never commit
or push unless the user asks; push only the authorized fork.

Before adding an Orca Server build to `ORCA_VERSIONS`, run
`tests/verify-orca-version.sh <orcad-bundle-or-cli> [<previous-bundle-or-cli>]` on the agent host,
with `RH_TEST_CODEX_CLI` set to include native Codex chats. It uses throwaway profiles. Review any
Claude flag its launch test reports before adding the flag to `KNOWN_FLAGS`.

On the agent host with Claude installed, also run
`RH_TEST_CLAUDE_CLI=/absolute/path/to/claude python3 tests/test_claude_hooks.py -v`.
It uses a temporary HOME, dummy API key and loopback model fixture to test real CLI hook cancellation,
invalid output and startup failure. The unprotected control must reproduce execution on the agent
host; protected failures must leave both execution markers absent. No real model is called.
