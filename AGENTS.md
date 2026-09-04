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
- `scripts/project-host-gateway.sh`: forced SSH command accepting only SFTP, health, and exec.
- `scripts/route-command.py`: Claude/Codex hook policy and cwd mapping.
- `scripts/inject-rule.sh`: also generates the session opencode `tool.execute.before` plugin.
- `scripts/run-on-project-host.sh`: validated local project command dispatcher.
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
- Explicit YOLO is final: the wizard must not ask for YOLO confirmation again.
- `laptop-setup.sh` remains standalone with its sibling helpers fetched beside it.
- The main agent starts only through `ssh -tt <remote> ... <claude|codex|opencode>`.
- Claude/Codex/opencode Bash calls route locally. Agent/Spawn tools stay on the remote host.

## Gateway Security

- Generate a separate reverse key under each remote session directory.
- Local authorization includes `command="...project-host-gateway..."`, loopback source limits,
  no PTY, no port forwarding, no X11, and no agent forwarding.
- Refuse a session key already present in an unrestricted user authorization line.
- The gateway accepts only standard SFTP, `remote-harness-health`, and
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`.
- The registered physical project root must match every exec request.
- Reject direct local launches of `claude`, `codex`, and `opencode` in both hook and dispatcher;
  scrub common AI credentials and shadow those binaries in the local command PATH.
- Arbitrary project shell is Turing-complete. Absolute isolation requires a dedicated local OS
  account without AI credentials or agent installations.

## Claude Multi-Agent

- Ordinary, named, and nested subagents inherit settings hooks.
- Agent Teams and Claude worktree creation stay disabled.
- Isolated parallel agents use separate local Git worktrees plus separate reverse harness sessions;
  all Claude processes remain on the remote server and may use cross-session messaging.

## Invariants

1. Shell-quote every value interpolated into a remote command; never `eval` user SSH input.
2. Session SSH config and mutable host-key state stay under `~/.remote-harness/.sessions`.
3. Only the tagged forced-gateway `authorized_keys` block may change under `~/.ssh`.
4. Cleanup removes mounts, per-session remote keys, gateway registration, authorization, hooks,
   and temporary SSH state.
5. Programmatically consumed scripts retain `KEY=VALUE` stdout.
6. Keep bilingual Markdown pairs synchronized.

## Verification

```bash
bash -n manage.sh tests/regression.sh scripts/*.sh
python3 -m py_compile scripts/route-command.py tests/codex_tui_e2e.py
bash tests/regression.sh
git diff --check
```

The full remote-server-to-local-project SSHFS flow remains a manual integration test. Never commit
or push unless the user asks; push only the authorized fork with a GitHub noreply identity.
