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
      RemoteForward <port> 127.0.0.1:22    # or the user-mode sshd's loopback port

box session ssh_config:
  Host rlocal
      HostName 127.0.0.1
      Port <port>
```

The simple reverse path keeps session config files and `known_hosts` under
`~/.remote-harness/.sessions/...`, keeps `ControlMaster no` in generated configs (routed commands
and tool shims pass a short session-scoped multiplexing master on the command line only), and
removes temporary state on cleanup where possible. It does not write `~/.ssh/config`, `known_hosts`, or SSH keys. Its only
`~/.ssh` mutation is the laptop `authorized_keys` managed block used for temporary reverse
authentication; the user-mode sshd below does not make even that change.

## User-Mode sshd

When the laptop's sshd ignores `~/.ssh/authorized_keys` (FreeIPA/sssd or LDAP key lookup through
`AuthorizedKeysCommand`, `AuthorizedKeysFile none`, a root-squashed NFS home) or no SSH server runs,
set `RH_LOCAL_SSHD=user` (or `--local-sshd user` on `simple-laptop-setup.sh` / `laptop-setup.sh`).
The wizard offers it when it detects `AuthorizedKeysCommand` or nothing on `:22`, and remembers an
explicit choice as `LAST_LOCAL_SSHD`; `RH_LOCAL_SSHD=system` switches back.

`laptop-setup.sh` then starts an sshd as the current user for this session: `ListenAddress
127.0.0.1` on a probed free port (a lost bind race retries on another port; the tunnel's `RemoteForward` is
written once it has bound), a session-private `authorized_keys` holding the usual forced-gateway line,
`AuthorizedKeysCommand none`, `AuthenticationMethods publickey`, `UsePAM no`, `DisableForwarding
yes`, and `PermitTTY no`. Its files live in `~/.remote-harness/.sessions/rev.*/sshd/`; the resource
record stops it (after checking PID, start time, and config path) together with the tunnel. A failed
mount prints the refusal reasons from its log. It needs the sshd binary but no root, and it bypasses
PAM, so directory HBAC policy does not apply to this loopback login.

## Bootstrap Shape

If the script source is remote, the skill emits a compact fetch form. Keep this form zsh-compatible:
do not use `read -p`.

```bash
(
set -f
umask 077
p='remote-harness source SSH target/args'
d='<default_via>'
printf '%s' "$p${d:+ [$d]}: " >/dev/tty
IFS= read -r h </dev/tty || exit 2
h=${h:-$d}; h=${h#ssh }; [ -n "$h" ] || exit 2
mkdir -p "$HOME/.remote-harness/.sessions"
s=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit 1
trap 'rm -rf "$s"' EXIT
ssh -n -o ClearAllForwardings=yes \
  -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o CheckHostIP=no \
  -o ControlMaster=no -o ControlPath=none \
  $h \
  'cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"' \
  > "$s/simple-bootstrap.sh" || exit 1
[ -s "$s/simple-bootstrap.sh" ] || exit 1
bash -n "$s/simple-bootstrap.sh" || exit 1
RH_VIA="$h" RH_LANG=<lang> bash "$s/simple-bootstrap.sh" --mode reverse --launch <launch>
)
```

## Runtime Flow

1. The outer command fully downloads and syntax-checks `simple-bootstrap.sh` before executing it
   locally. The source alias's verified host identity is preserved with strict checking and no
   known-hosts updates. One additional SSH connection downloads all eight helpers with a bootstrap
   copy and SHA-256 manifest; filenames, entry types, hashes, bootstrap identity and Bash syntax
   must pass before the local wizard starts. See `docs/simple-flow.md` for the bundle checks.
2. `simple-dispatch.sh --mode reverse` hands off to `simple-laptop-setup.sh`.
3. `simple-laptop-setup.sh` prompts locally for the remote SSH target, local project dir, optional
   remote mountpoint, and approval mode (auto by default, or normal/YOLO) when not already explicit.
4. It prepares a remote session config path and runs remote
   `setup-tunnel.sh --config <remote-session-config> --alias rlocal --namespace rlocal --gen-key`.
5. It calls `laptop-setup.sh` with `--box-ssh-config <remote-session-config>`.
6. `laptop-setup.sh` creates the laptop-side session config carrying `RemoteForward`, connects
   through its internal ssh wrapper, mounts the laptop project on the box, installs strict
   strict Claude/Codex hooks or the opencode routing plugin, and launches the selected agent.
7. On exit, cleanup unmounts sshfs, removes the session rule, drops the reverse tunnel when no
   remaining mount needs it, removes temp ssh configs, and removes default empty mountpoint dirs.
8. If the connection is force-closed and the laptop never runs that cleanup, the remote session
   watcher notices the agent exit (or hung-up terminal) and performs the remote cleanup itself;
   the next launch's GC repeats it for anything a reboot left behind. The watcher also checks the
   project host through the tunnel every `RH_HEARTBEAT_INTERVAL` (30) seconds and ends the agent
   once every check has failed for `RH_HEARTBEAT_TIMEOUT` (600) seconds.
9. A session ended by a lost connection leaves `$RH_HOME/.sessions/.resume/<mountpoint>.<agent>`;
   the next launch of that mountpoint and agent asks once whether to continue the conversation
   (`--continue` / `resume --last`). `RH_RESUME=1|0` forces the choice. Local cleanup retries an
   unreachable remote after `RH_RELEASE_RETRY_DELAYS` (10 20 30) seconds, then stops only a tunnel
   this launch created, with its user-mode sshd and local authorization.

## Preconditions

- The laptop can SSH into the remote box with the user's existing SSH key.
- The remote box can authenticate back to the laptop through the reverse tunnel using a new key
  stored beside the session SSH config. The laptop setup
  checks for an existing active matching key first; otherwise it appends a tagged,
  loopback-scoped `remote-harness:reverse-auth:<tag>` block to `~/.ssh/authorized_keys`. Managed
  blocks are reference-counted and removed on exit when no active session still uses them.
- remote-harness is installed on the remote box at `~/.remote-harness`, or `RH_HOME` points to it.
- The laptop can run an SSH server; the wizard detects and guides enabling it when possible. Without
  root, or when that sshd ignores `~/.ssh/authorized_keys`, use the user-mode sshd.
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
- Mount fails (`read: Connection reset by peer`, `Permission denied`) on a FreeIPA/sssd laptop whose
  sshd ignores `~/.ssh/authorized_keys`: rerun with `RH_LOCAL_SSHD=user`.
- Frequent disconnects under load: check server-side `MaxStartups`, `ClientAlive*`, `nofile`, and
  TCP queue settings; see `docs/ssh-sshfs-long-lived-connections.md`.
