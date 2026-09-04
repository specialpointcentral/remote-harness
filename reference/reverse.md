# Simple reverse reference

Simple reverse means: the coding agent runs on a remote box, while the project lives on the user's
laptop. The public skill does not ask the agent to collect laptop paths, mount paths, reverse ports,
or namespaces in chat. It returns one local command that runs `simple-bootstrap.sh`; the local wizard
collects the concrete values in the user's terminal.

Short wording such as "远程开发本地" or "remote dev local project" selects this mode. Ambiguous
wording should omit `--mode` and let `simple-dispatch.sh` ask locally.

## Tunnel Model

The laptop opens a reverse SSH tunnel to the remote box. Both SSH aliases are session-local:

```text
laptop session ssh_config:
  Host <box-session-alias>
      RemoteForward <port> 127.0.0.1:22

box session ssh_config:
  Host rlocal
      HostName 127.0.0.1
      Port <port>
```

The simple reverse path keeps session config files and `known_hosts` under
`~/.remote-harness/.sessions/...`, disables OpenSSH multiplexing, and removes temporary state on
cleanup where possible. It does not write `~/.ssh/config`, `known_hosts`, or SSH keys. Its only
`~/.ssh` mutation is the laptop `authorized_keys` managed block used for temporary reverse
authentication.

## Bootstrap Shape

If the script source is remote, the skill emits a compact fetch form. Keep this form zsh-compatible:
do not use `read -p`.

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
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode reverse --launch <launch>
)
```

## Runtime Flow

1. `simple-bootstrap.sh` runs locally. If fetched from remote, it fetches `_common.sh`,
   `simple-dispatch.sh`, `simple-laptop-setup.sh`, `laptop-setup.sh`, and required helpers into a
   local temp dir.
2. `simple-dispatch.sh --mode reverse` hands off to `simple-laptop-setup.sh`.
3. `simple-laptop-setup.sh` prompts locally for the remote SSH target, local project dir, optional
   remote mountpoint, and YOLO preference when not already explicit.
4. It prepares a remote session config path and runs remote
   `setup-tunnel.sh --config <remote-session-config> --alias rlocal --namespace rlocal --gen-key`.
5. It calls `laptop-setup.sh` with `--box-ssh-config <remote-session-config>`.
6. `laptop-setup.sh` creates the laptop-side session config carrying `RemoteForward`, connects
   through its internal ssh wrapper, mounts the laptop project on the box, installs strict
   strict Claude/Codex hooks or the opencode routing plugin, and launches the selected agent.
7. On exit, cleanup unmounts sshfs, removes the session rule, drops the reverse tunnel when no
   remaining mount needs it, removes temp ssh configs, and removes default empty mountpoint dirs.

## Preconditions

- The laptop can SSH into the remote box with the user's existing SSH key.
- The remote box can authenticate back to the laptop through the reverse tunnel using a new key
  stored beside the session SSH config. The laptop setup
  checks for an existing active matching key first; otherwise it appends a tagged,
  loopback-scoped `remote-harness:reverse-auth:<tag>` block to `~/.ssh/authorized_keys`. Managed
  blocks are reference-counted and removed on exit when no active session still uses them.
- remote-harness is installed on the remote box at `~/.remote-harness`, or `RH_HOME` points to it.
- The laptop can run an SSH server; the wizard detects and guides enabling it when possible.
- The remote box has `sshfs` and the selected agent CLI (`codex`, `claude`, or `opencode`).
- For shared remote boxes with many users or long-lived SSHFS mounts, tune server-side sshd capacity
  and keepalive as described in `docs/ssh-sshfs-long-lived-connections.md`.

## Troubleshooting

- Fetch fails before setup starts: check the remote-harness source SSH target and that the remote
  install contains `scripts/simple-bootstrap.sh`.
- TUI fails with `stdin is not a terminal`: the launch phase must use `ssh -tt` and attach stdin to
  the controlling tty; use the current `laptop-setup.sh`.
- Port is already listening: `laptop-setup.sh` validates ownership and switches to a nearby free
  port when the listener does not reach this laptop.
- Stale mount: exit the agent and rerun remote-harness; stale sshfs mounts are revalidated and
  replaced.
- Frequent disconnects under load: check server-side `MaxStartups`, `ClientAlive*`, `nofile`, and
  TCP queue settings; see `docs/ssh-sshfs-long-lived-connections.md`.
