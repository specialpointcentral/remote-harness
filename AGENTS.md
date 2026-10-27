# AGENTS.md - remote-harness maintainer guide

This repository is the remote-only remote-harness skill. Claude, Codex, opencode, subagents, and
independent agent sessions run on a remote server. The user's local machine is only the project host:
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
- `scripts/inject-rule.sh`: also generates the session opencode `tool.execute.before` plugin.
- `scripts/run-on-project-host.sh`: validated local project command and tool dispatcher.
- `scripts/project-host-tool.py`: remote session `git`/`rg` PATH shim for work-tree scans.
- `scripts/session-reaper.sh`: remote watcher/GC for sessions whose local cleanup never ran.
- `scripts/channel-guard.py`: holds a routed Bash command's SSH channel open for its lifetime.
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
- The main agent starts only through `ssh -tt <remote> ... <claude|codex|opencode>`.
- Claude/Codex/opencode Bash calls route locally. Agent/Spawn tools stay on the remote host.

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
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`, and
  `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`; the tool verb execs the binary
  directly (no shell, fixed PATH). Watched exec and the tool verb give the command `/dev/null`
  stdin and stop its process group and tree when the SSH channel closes.
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
bash -n manage.sh tests/regression.sh scripts/*.sh
python3 -m py_compile scripts/route-command.py scripts/project-host-tool.py scripts/channel-guard.py tests/codex_tui_e2e.py
bash tests/regression.sh
git diff --check
```

The full remote-server-to-local-project SSHFS flow remains a manual integration test. Never commit
or push unless the user asks; push only the authorized fork.
