# Simple Forward Flow

## Verdict

Feasible. The forward flow mounts an SSH server project onto the local machine, installs strict
Claude/Codex Bash routing to the server (or an opencode SSH instruction), and launches the agent in
the mount. The simple layer adds a local terminal wizard so the skill can return one short command
instead of asking the agent to collect server, path, and mountpoint details in chat.

This mode targets: Codex/agent runs locally; project files and the development environment live on a
directly SSH-reachable server.

Short phrases such as "本地开发远程项目" or "本地开发服务器项目" should select this mode. Short phrases
such as "远程开发本地" should select simple reverse. If the request is ambiguous, use
`simple-bootstrap.sh` without `--mode`; it delegates to `simple-dispatch.sh`, which defaults to
reverse and caches the mode choice.

## Boundary

- Local file tools may read, write, edit, and search the mounted project directory.
- Claude/Codex Bash commands are automatically routed to the server with mount-relative cwd mapping.
  opencode follows the injected SSH instruction.
- The local wizard collects server SSH target, server project directory, optional local mountpoint,
  and launch preference.
- The simple path does not scan the server for project directories. Cached values are prompt
  defaults only.
- A YOLO request in the invocation is final; the wizard does not ask for YOLO again.
- Setup always uses a session-local ssh config under local `~/.remote-harness/.sessions/...`. Host
  aliases are used through that config; raw SSH args get a session-local `<host>-dev` alias. It does
  not create or modify anything under local `~/.ssh`; temporary `known_hosts` also stays under
  `~/.remote-harness/.sessions/...`, and generated configs disable OpenSSH multiplexing.
- The default local mountpoint is `~/.remote-harness/mounts/<project>`; explicit user-entered
  mountpoints are allowed.

## User Command Shape

For Codex in Chinese, the skill emits:

```bash
RH_LANG=zh bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode forward --launch codex
```

Append `--yolo` only when the user explicitly requested YOLO/bypass/no-approval mode. If the script
source is remote rather than locally installed, use the fetch form from `SKILL.md`; the source SSH
target only loads remote-harness scripts, and the forward wizard separately asks for the project
server target.

## Flow

1. Agent emits the simple command with `--mode forward`.
2. `simple-bootstrap.sh` delegates to `simple-dispatch.sh --mode forward`.
3. `simple-local-setup.sh` prompts locally for the server SSH target, server project path, optional
   local mountpoint, and YOLO preference when not already explicit.
4. It saves confirmed defaults in `~/.remote-harness/simple-forward-cache.env`.
5. It invokes `local-setup.sh`.
6. `local-setup.sh` creates a session-local SSH config for the server target and a short alias when
   raw SSH args were supplied.
7. `mount-project.sh` sshfs-mounts `<server-alias>:<server-project>` onto the local mountpoint.
8. `inject-rule.sh` installs strict Claude/Codex Bash routing or the opencode SSH instruction.
9. The chosen local agent launches in the mount.
10. On exit, cleanup unmounts sshfs, removes the session rule, removes the temp ssh config, and
    removes the default mountpoint directory when it is empty.

## Preconditions

- remote-harness is installed locally at `~/.remote-harness`, or `RH_HOME` points to the install.
- The local machine can SSH into the server.
- The local machine has `sshfs`; `mount-project.sh` surfaces an OS-aware install command when it is
  missing.
- The selected agent CLI is installed locally.
- For shared project servers or many long-lived SSHFS mounts, tune server-side sshd capacity,
  keepalive, `nofile`, and TCP queues as described in `docs/ssh-sshfs-long-lived-connections.md`.

## Failure And Recovery

- SSH target is wrong: rerun the command and enter a different target.
- Server project path is wrong: mount fails; rerun and enter the correct path.
- Local mountpoint is non-empty: `local-setup.sh` prompts for a different empty directory.
- SSH key is missing: the session may prompt for passwords. Add a key to make sshfs and server
  commands smooth.

## Implemented

- `scripts/simple-local-setup.sh`
- `scripts/simple-bootstrap.sh`
- `scripts/simple-dispatch.sh`
- `scripts/local-setup.sh`
- `scripts/mount-project.sh`
- `scripts/inject-rule.sh`
- `SKILL.md` / `SKILL.cn.md`
