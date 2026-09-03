# Simple forward reference

Simple forward means: Codex or another coding agent runs locally, while the project files and
development environment live on an SSH server. The user says things like "本地开发远程项目" or
"local Codex with server project". The skill still emits the same `simple-bootstrap.sh` entry point,
with `--mode forward`.

## Boundary

- File reads, writes, edits, and searches happen in the local sshfs mount.
- Claude/Codex Bash calls are automatically rewritten to the server with mount-relative cwd mapping.
  opencode continues to receive an explicit `ssh <alias> 'cd <project> && <cmd>'` instruction.
- The simple path does not scan the server for project directories. The user types the server path;
  cached values are prompt defaults only.

## SSH State

Every server target is used through a session-local ssh config under local
`~/.remote-harness/.sessions/...`. If the user provides a Host alias, that alias is resolved through
the session config. If the user provides raw SSH args such as `-p 2222 dev@example.com`,
`local-setup.sh` creates a session-local `<host>-dev` alias there. It does not create or modify
anything under local `~/.ssh`; temporary `known_hosts` stays under
`~/.remote-harness/.sessions/...`, and session configs disable OpenSSH multiplexing. The temp config
is hidden from the launched agent with a session `ssh` wrapper.

## Bootstrap Shape

Local install:

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode forward --launch <launch>
```

Remote script source:

```bash
(
set -f
p='remote-harness source SSH target/args'
d='<default_via>'
printf '%s' "$p${d:+ [$d]}: " >/dev/tty
IFS= read -r h </dev/tty || exit 2
h=${h:-$d}; h=${h#ssh }; [ -n "$h" ] || exit 2
mkdir -p "$HOME/.remote-harness/.sessions"
s=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit 1
trap 'rm -rf "$s"' EXIT
ssh -n -o ClearAllForwardings=yes \
  -o UserKnownHostsFile="$s/known_hosts" \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  -o ControlMaster=no -o ControlPath=none \
  $h \
  'cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"' |
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode forward --launch <launch>
)
```

The source SSH target only loads remote-harness scripts. Forward mode still asks locally for the
project server SSH target.

## Runtime Flow

1. `simple-bootstrap.sh` runs locally and delegates to `simple-dispatch.sh --mode forward`.
2. `simple-local-setup.sh` prompts locally for the server SSH target, server project directory,
   optional local mountpoint, and YOLO preference when not already explicit.
3. It saves confirmed defaults in `~/.remote-harness/simple-forward-cache.env`.
4. `local-setup.sh` prepares the session ssh config/server alias, mounts `<server-alias>:<project>`
   locally with `mount-project.sh`, and passes the session ssh config to `inject-rule.sh`.
5. `inject-rule.sh` creates a session-local rule and optional ssh wrapper.
6. The chosen local agent launches in the mount.
7. On exit, cleanup unmounts sshfs, removes the session rule, removes the temp ssh config, and
   removes the default mountpoint directory when it is empty.

## Troubleshooting

- Password prompts: configure SSH key auth to the server for smooth sshfs and command execution.
- `not-empty`: choose a different empty local mountpoint.
- macOS sshfs: use FUSE-T, not macFUSE. The install hint is surfaced by `mount-project.sh`.
- Remote command fails immediately after an edit: re-run once in case the mount had not flushed yet;
  do not run build/install tools locally.
- Frequent disconnects under load: tune the server's sshd capacity, keepalive, `nofile`, and TCP
  queues; see `docs/ssh-sshfs-long-lived-connections.md`.
