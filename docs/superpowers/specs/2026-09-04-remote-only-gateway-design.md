# Remote-Only Gateway Design

> Chinese counterpart: [2026-09-04-remote-only-gateway-design.cn.md](2026-09-04-remote-only-gateway-design.cn.md).

## Goal

Every supported Claude, Codex, opencode, subagent, nested agent, and independent Agent session runs
on the remote server. The local machine stores the project and executes ordinary project commands.

## Architecture

The local bootstrap opens a reverse SSH tunnel. A new remote key is created for each session and is
authorized locally only with a forced command. SSHFS uses SFTP through that command to expose the
local project on the remote server. Claude/Codex hooks and an opencode `tool.execute.before` plugin
rewrite Bash calls to a session runner, which sends a fixed encoded execution request to the local
gateway.

The gateway accepts only standard SFTP, `remote-harness-health`, and
`remote-harness-exec <root-b64> <cwd-b64> <command-b64>`. It verifies the registered project root and
rejects arbitrary SSH commands. The local dispatcher verifies the physical cwd, removes common AI
credentials, shadows Agent CLI names, and runs the project command with the local login shell.

## Disabled Paths

`--mode forward`, `simple-local-setup.sh`, and `local-setup.sh` fail before mounting, connecting, or
launching. Direct `claude`, `codex`, or `opencode` project commands are denied. Claude Agent tools
stay remote; Claude worktree creation and Agent Teams are disabled.

## Multi-Agent

Ordinary, named, and nested Claude subagents inherit the session hook and remain remote. Named
agents can use Claude messaging. Isolated parallel writers use separate local Git worktrees and one
reverse session per worktree.

## Security Boundary

The forced key cannot open a normal local SSH shell. This is not an OS sandbox: an arbitrary project
shell is Turing-complete, and SFTP is account-level rather than chrooted to the selected project. An
absolute boundary requires a dedicated local OS account with project-only access, no Agent install,
and no AI credentials.

## Verification

Regression tests cover fixed-protocol execution, arbitrary-shell denial, SFTP dispatch, root and
subdirectory cwd mapping, per-session keys, generated forced authorization, local-agent denial,
disabled forward entries, Claude hook inheritance, and opencode plugin rewriting.
