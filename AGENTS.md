# AGENTS.md — guide for coding agents working ON this repo

This repo is the **remote-harness** skill: it connects a coding agent and a codebase that live on
two different machines, in either direction, and hands the user one copy-paste command to mount the
code + launch the agent. (User-facing docs: `README.md`. Runtime skill spec: `SKILL.md`.) This file
is for agents *developing* remote-harness itself.

> A `CLAUDE.md` symlink points here so Claude Code loads it; Codex/opencode read `AGENTS.md` natively.

## Repo layout

- `SKILL.md` — lean simple-mode skill entry point. By default it emits one local bootstrap command;
  it must not ask the agent to collect SSH targets, paths, ports, or namespaces.
- `reference/{reverse,forward,scripts}.md` — current simple reverse/forward behavior and
  helper-script contracts.
- `docs/{design,complete-flow,simple-flow,simple-forward-flow,ssh-sshfs-long-lived-connections}.md`
  — design, complete flow, per-mode plans, and shared-server SSH/SSHFS long-lived connection tuning.
  Keep each one synchronized with its `.cn.md` counterpart.
- `scripts/*.sh` — the deterministic helpers (KEY=VALUE on stdout, notes on stderr). `_common.sh` is
  a sourced library (not an entry point). `simple-bootstrap.sh` is the public unified simple entry
  point; it can run from a local install or be fetched from a remote skill install. It delegates to
  `simple-dispatch.sh`, which selects/dispatches reverse or forward; `simple-laptop-setup.sh` and
  `simple-local-setup.sh` are the mode-specific local wizards. `suggest-via.sh` is a remote-only
  helper for a best-effort bootstrap SSH default; `laptop-setup.sh` (reverse) /
  `local-setup.sh` (forward) are the lower-level orchestrators; `mount-project.sh` and
  `inject-rule.sh` are shared.
- `adapters/{codex,opencode}.md` — per-agent notes. `opencode.md` is installed as opencode's custom
  command; `codex.md` is reference-only (Codex has no custom slash commands, so manage.sh installs the
  shared `SKILL.md` as a native Codex **skill** under `$CODEX_HOME/skills/`, invoked as
  `$remote-harness`). Both just tell the agent to read `SKILL.md` and pass the right `--launch`.
- `manage.sh` — install (copy) / `--dev` (symlink) / `--uninstall`. Installs the core to
  `~/.remote-harness/{SKILL.md,SKILL.cn.md,scripts/,reference/,docs/}` plus the per-agent entry files;
  native skill directories also include `docs/` so `SKILL.md` links work after copy install.

## Current product shape

The default product is **simple reverse**: **A** = remote box where the coding agent runs, **P** =
the user's laptop behind NAT where the code lives. The agent returns one local bootstrap command; all
concrete SSH/path choices happen in the user's local terminal. The supported counterpart is
**simple forward**: **A** = local machine where Codex/agent runs, **P** = SSH server where the
project and dev environment live. Keep `reference/` aligned with the simple flows.

Generic roles still matter for internals: **A** = machine the agent runs on; **P** = machine the code
lives on (an ssh `<alias>`). The lower-level reverse flow uses a reverse SSH tunnel; the forward flow
uses direct ssh. Both mount P's project onto an empty dir on A. `inject-rule.sh` installs strict
Claude/Codex Bash routing or the opencode SSH instruction, then launches the agent in the mount.

## Simple Reverse Rules

- The agent must not ask for local laptop details, local paths, remote mount paths, reverse ports, or
  namespaces in chat. It only returns the bootstrap command and a short explanation.
- The public simple command must target `simple-bootstrap.sh`, not a mode-specific helper. Pass
  `--mode reverse` for known reverse, `--mode forward` for known forward, and omit `--mode` when
  ambiguous.
- The command always runs locally, but the script may live remotely. Do not assume
  `~/.remote-harness/scripts` exists on the user's laptop. If the skill/source directory is remote,
  emit a fetch form that reads remote `scripts/simple-bootstrap.sh` over SSH and pipes it to local
  `bash -s -- <mode args>`.
- The bootstrap command must be compact but copyable: use a small number of short lines, never a
  single long line. Keep any remote `ssh ... | bash ...` pipeline on readable continuation lines so
  chat wrapping cannot split a logical shell line.
- The local bootstrap command may read the local `LAST_VIA` cache to prefill the first prompt. If the
  cache is empty, the command may fall back to a best-effort remote SSH target suggested by
  `scripts/suggest-via.sh`.
- The remote SSH target suggestion may use server-side facts only: remote `id -un`, server address,
  and server SSH port. If using `SSH_CONNECTION`, use only fields 3 and 4 (`server-ip` /
  `server-port`); fields 1 and 2 are local/client data and must never be printed, cached, or placed
  into the command.
- Treat the suggested SSH target as an editable prompt default only. The user's local cache wins over
  the remote suggestion, and the user must be able to press Enter to accept or type a different Host
  alias / SSH args for ProxyJump, NAT, VPN, IPv6, or nonstandard routing.
- If the invocation explicitly requests YOLO/bypass/no-approval mode, the generated command must pass
  `--yolo` and the local wizard must not ask for YOLO confirmation again. Only ask the YOLO question
  when the invocation did not already make that choice.
- Cached project and mountpoint values are defaults, not silent choices. If a cached local project
  path exists, show it as the default and let the user press Enter or replace it.
- The simple flow uses the fixed session alias `rlocal`. Do not reintroduce `<user>-mac` /
  `rlocal-mac` naming in the default simple path.
- `rlocal` is written only to a remote session-local ssh config under
  `$RH_HOME/.sessions/.../ssh_config`. The simple path must not write the remote box's
  `~/.ssh/config`.
- The laptop-side RemoteForward alias is also session-local under local
  `~/.remote-harness/.sessions/.../ssh_config`. `laptop-setup.sh` must not write local
  `~/.ssh/config`, `~/.ssh/known_hosts`, SSH keys, backup files, or control sockets, and must not
  clean up or rewrite historical user ssh config blocks automatically.
- Simple reverse may temporarily manage exactly one local `~/.ssh/authorized_keys` entry for the
  box-generated remote-harness key. The entry must be inside a tagged
  `remote-harness:reverse-auth:<tag>` block, restricted to loopback with `from="127.0.0.1,::1"`,
  reference-counted under `~/.remote-harness/.sessions/authorized-keys/...`, and removed on exit
  when no active session still references it. If a matching active user key already exists, reuse it
  and do not append anything.
- Apart from that explicit reverse-auth exception, SSH authentication remains user-owned. The simple
  flow may read existing user SSH config/keys/agent behavior, but it must not install keys or
  silently create credentials.
- Session-local keepalive, `sshfs reconnect`, and temp SSH config do not replace server capacity
  tuning. For shared remote boxes or many long-lived SSHFS mounts, docs and user-facing reminders
  should point to `docs/ssh-sshfs-long-lived-connections*.md` so server operators tune sshd,
  `nofile`, and TCP queues.
- Claude/Codex must receive the session `PreToolUse` hook and `rh-run`; ordinary Bash commands are
  mapped by cwd and routed automatically. Keep the temp `bin/ssh` wrapper for opencode and internal
  SSH config resolution.
- The default remote mountpoint is under remote `~/.remote-harness/mounts/<project>` and should be
  removed on exit when empty. User-entered mountpoints are allowed because they are explicit choices.
- When `RH_LANG=zh`, local script prompts should be Chinese. The skill command itself selects
  `RH_LANG`; the local scripts own the rest of the interaction.

## Simple Forward Rules

- Use simple forward when the user asks for local Codex/agent with a project, toolchain, or dev
  environment on an SSH server. Short phrasing such as "本地开发远程项目" or "本地开发服务器项目" must
  trigger forward.
- The skill output should still go through `scripts/simple-bootstrap.sh` with `--mode forward`,
  `RH_LANG=<lang>`, `--launch <agent>`, and optional `--yolo`. If the script source is remote, use
  the fetch form; the source SSH target is only for loading remote-harness scripts, while the
  forward wizard separately asks for the project server target.
- The local wizard owns all concrete values: server SSH target, server project directory, local
  mountpoint, and YOLO preference when it was not already explicit in the invocation.
- Do not scan the server to discover project directories in the simple path. Cached values are only
  prompt defaults.
- The mounted directory is for local file reads, writes, edits, and searches. Project commands
  (build, run, test, install, format, lint, language server, migrations, mutating git commands, and
  other toolchain/runtime work) must run on the server through the injected `ssh <alias> 'cd ... &&
  <cmd>'` rule.
- `local-setup.sh` must use a session-local SSH config for every server target, including an existing
  Host alias. When the user supplied raw SSH args it may create `<host>-dev`; when the user supplied
  a Host alias it can use that short name through the session config. In all cases temporary
  `known_hosts` stays under local `~/.remote-harness/.sessions/...`, with multiplexing disabled.
- The default local mountpoint is under local `~/.remote-harness/mounts/<project>` and should be
  removed on exit when empty. User-entered mountpoints are allowed because they are explicit choices.

## Ambiguous Simple Mode

- If the user request does not clearly imply reverse or forward, emit the `simple-bootstrap.sh`
  command without `--mode` instead of asking in chat.
- `simple-dispatch.sh` prompts locally for reverse/forward, defaults to reverse on first run, caches
  `LAST_MODE`, and then hands off to the selected mode's local wizard.
- Because every emitted command is run locally, prefer local terminal prompts and local caches for
  mode, server, project, mountpoint, and YOLO choices. Keep the chat command short; put branching in
  `simple-bootstrap.sh` / `simple-dispatch.sh`.

## Invariants — do NOT break these

1. **`laptop-setup.sh` must stay runnable STANDALONE.** In reverse it is fetched to the laptop (which
   has no install) and run there. It sources `_common.sh` via `. "$(dirname "$0")/_common.sh"`, so the
   emitted one-command fetches BOTH files into one temp dir. Don't add dependencies that only exist
   in the install dir.
2. **Always confirm, never silently choose.** In the default simple path, the SSH target, project
   dir, mountpoint, and YOLO preference are explicit choices; cached or generated values only prefill
   prompts. A YOLO request in the invocation is already explicit, so do not ask it again.
   Direction and locations must always be explicit user choices. Detection only pre-fills.
3. **`inject-rule.sh` is direction-neutral and never writes the mounted repo.** Per-session artifacts
   live under `$RH_HOME/.sessions/<key>`. Rule wording uses `<alias>` / "this machine".
4. **Shell-quote every value spliced into a remote command** with `sq()` (from `_common.sh`) — paths
   may contain apostrophes; unquoted interpolation is an injection/break risk. Never `eval` `--via`.
5. **Portability**: target Linux, WSL, and macOS. Use `#!/usr/bin/env bash`; avoid GNU-only flags
   (provide BSD fallbacks); listener checks go `ss → netstat -an → lsof`; sshfs install hints are
   OS-aware; **macOS uses FUSE-T (no kernel extension), never macFUSE**. `set -uo pipefail` (not `-e`)
   on probes that must keep emitting.
6. **Scripts emit `KEY=VALUE` on stdout, human notes on stderr.** Keep that contract; consumers parse it.
7. **No simple path writes SSH runtime state under `~/.ssh`, except reverse authorized_keys.**
   Reverse and forward setup must use session-local ssh config files, temporary `known_hosts`, and
   other SSH runtime files under `~/.remote-harness/.sessions/...`. Keep generated configs with
   OpenSSH multiplexing disabled to avoid ControlPath socket failures on macOS. Do not create, edit,
   back up, append to, or clean up local or remote `~/.ssh/config`, `known_hosts`, SSH keys,
   `config.rh-bak.*`, or `known_hosts_<alias>`. The only allowed `~/.ssh` mutation is the simple
   reverse tagged `authorized_keys` block described above; it must be idempotent, scoped, and
   cleaned up with reference counting. Reading user-managed SSH config/keys for an explicit Host
   alias is allowed; other mutation is not.

## Conventions

- **Bilingual docs (REQUIRED):** every Markdown doc MUST have a Chinese counterpart named
  `<name>.cn.md` (Chinese is the primary audience). **Exceptions:** `README.md` (it is inline
  bilingual, 中文 first) and `CLAUDE.md` (a symlink). When you add or edit any `*.md`, create/update
  its `*.cn.md` in the same change so they stay in sync. Examples: `SKILL.md`→`SKILL.cn.md`,
  `reference/reverse.md`→`reference/reverse.cn.md`, `adapters/codex.md`→`adapters/codex.cn.md`.
- Keep `SKILL.md` lean; put depth in `reference/`.
- Keep maintainer-facing design principles here in `AGENTS*.md`; mirror user-facing consequences in
  `SKILL*`/`docs*`/`reference*` only when useful.
- One responsibility per script; share via `_common.sh`.

## Developing & testing

- `bash -n scripts/*.sh manage.sh` after every change (syntax gate).
- Dry-run pieces in a sandbox `HOME`/`RH_HOME` (e.g. `inject-rule.sh on … ; off …`;
  `mount-project.sh --unmount`; `setup-tunnel.sh --config …`). Verify reverse's managed-alias
  output is unchanged when touching `_common.sh`.
- Forward loopback E2E: add an ssh alias to `localhost`, run `local-setup.sh --via … --remote-path …
  --mountpoint /tmp/… --launch claude`; confirm mount + rule + unmount-on-exit.
- The full two-host E2E (reverse from a box / forward to a server, incl. macOS FUSE-T) is a manual test.
- Commit only when asked. The repo publishes to GitHub (`origin/main`).
- **Commit identity (required).** Every commit must carry a **GitHub noreply** email — GitHub rejects
  any push that would expose a real address (error `GH007`). On a clone with no configured git identity
  (e.g. a remote dev box), set it **per-commit** so nothing is written to `.git/config` or `--global`:
  `git -c user.name=chenjh16 -c user.email=chenjh16@users.noreply.github.com commit …`
- **Pushing.** Push only from the machine that holds GitHub push auth. To ship work done on a dev box
  without push access: commit there with the per-commit identity above, then from the push machine
  `git fetch` that box's clone (added as a remote) and `git push origin main`. While the box is the
  active source, don't also commit on the push machine — avoid divergence.
