# remote-harness — design

> Chinese counterpart: [design.cn.md](design.cn.md). User-facing docs: [`../README.md`](../README.md).
> Runtime skill spec: [`../SKILL.md`](../SKILL.md). Dev guide: [`../AGENTS.md`](../AGENTS.md).

## 1. Problem

remote-harness connects two machines:

- **A**: where the coding agent runs.
- **P**: where the project and development environment live.

It mounts P's project onto A with sshfs and launches the selected agent in the mount. Claude and
Codex receive a session hook that rewrites every Bash call to P; opencode retains instruction-based
SSH routing.

## 2. Directions

- **Simple reverse**: A is a remote box; P is the user's laptop. The laptop opens a reverse SSH
  tunnel to the box, and the box reaches the laptop through `rlocal`.
- **Simple forward**: A is the local machine; P is an SSH server. The local machine mounts the server
  project directly.
- **Ambiguous**: the emitted command omits `--mode`; `simple-dispatch.sh` asks locally and caches the
  mode.

The public entry for all cases is `scripts/simple-bootstrap.sh`. The command always runs locally.
The script itself may be local or fetched from the remote machine where the skill is installed.

## 3. Layering

```text
SKILL.md
  -> simple-bootstrap.sh
      -> simple-dispatch.sh
          -> simple-laptop-setup.sh  -> laptop-setup.sh
          -> simple-local-setup.sh   -> local-setup.sh
              -> setup-tunnel/check-tunnel/mount-project/inject-rule
```

`_common.sh` is a sourced library for quoting, prompts, `parse_via`, and `write_managed_alias`.
Helper scripts emit machine-readable `KEY=VALUE` on stdout and human notes on stderr.

## 4. SSH Config Model

Current simple flows use **session-local SSH config only**:

| Flow | Alias | Config Location | Purpose |
|---|---|---|---|
| reverse, laptop -> box | `<host>-remote-harness` | local `~/.remote-harness/.sessions/.../ssh_config` | carries `RemoteForward <port> 127.0.0.1:22` |
| reverse, box -> laptop | `rlocal` | remote `~/.remote-harness/.sessions/.../ssh_config` | reaches laptop through box loopback port |
| forward, local -> server | existing Host alias or `<host>-dev` | local `~/.remote-harness/.sessions/.../ssh_config` | stable short alias and SSH runtime isolation for sshfs and server commands |

Simple flows must not create, edit, back up, append to, or clean up local or remote
`~/.ssh/config`, `known_hosts`, SSH keys, `config.rh-bak.*`, or `known_hosts_<alias>`. Temporary SSH
configs and `known_hosts` live under `~/.remote-harness/.sessions/...`; generated configs disable
OpenSSH multiplexing.

The one intentional `~/.ssh` mutation is simple reverse laptop `authorized_keys`: when the box
provides a remote-harness public key, `laptop-setup.sh` first checks for an existing active matching
key. If none exists, it appends a tagged `remote-harness:reverse-auth:<tag>` block restricted to
loopback with `from="127.0.0.1,::1"`. A reference token under
`~/.remote-harness/.sessions/authorized-keys/...` prevents one session from removing authorization
while another still uses it. Historical user files in `~/.ssh` are otherwise user-owned and are not
modified unless the user explicitly asks.

Claude/Codex receive a session `PreToolUse` hook and `bin/rh-run`. opencode retains the short
`ssh rlocal ...` / `ssh <server-alias> ...` instructions through the session `bin/ssh` wrapper.

## 5. Privacy Boundary

The agent returns a command and does not collect concrete SSH targets, local paths, mount paths, or
ports in chat. The local terminal wizard collects them. For simple reverse, the agent may suggest a
remote SSH target using server-side facts only. If it uses `SSH_CONNECTION`, only fields 3 and 4
(`server-ip`, `server-port`) are allowed; fields 1 and 2 are local/client data.

## 6. Shared-Server Capacity

The simple flows already use client-side mitigations: session-local SSH config, temporary
`known_hosts`, `sshfs reconnect`, keepalive options, and exit cleanup. Those choices do not replace
server-side capacity tuning. On shared remote development boxes, many long-running agent sessions or
many SSHFS mounts should be backed by the `sshd` `MaxStartups` / `MaxSessions` / `ClientAlive*`,
systemd/PAM `nofile`, and TCP queue guidance in
[`ssh-sshfs-long-lived-connections.md`](ssh-sshfs-long-lived-connections.md).

This is not a hard prerequisite for one small session; it is an operational requirement for stable
shared-server use.

## 7. Rule And Hook Injection

`inject-rule.sh` is session-scoped and direction-neutral. It writes under
`$RH_HOME/.sessions/<key>` and never writes the mounted repository. For Claude and Codex it creates
a `PreToolUse` hook plus `bin/rh-run`. The hook preserves the tool input, maps cwd relative to the
mount, and replaces the Bash command with the runner. The runner transmits the encoded command
through SSH and executes it in P's login shell with `GIT_OPTIONAL_LOCKS=0`.

The launch aborts when the rule, hook, runner, Python runtime, or session SSH config is unavailable.
Once the hook is loaded, handler errors return denial and SSH failures do not fall back to the
original command on A. Client hook frameworks remain guardrails rather than complete isolation.

Agent-specific channels:

- Claude: `--append-system-prompt-file <rule> --settings <session settings>`.
- Codex: session `developer_instructions`, inline `hooks.PreToolUse`, and explicit trust for the
  generated hook; non-yolo also enables workspace-write network access and session writable roots.
- opencode: `OPENCODE_CONFIG=<session config>` and instruction-based SSH routing.

The hook is a command-routing guardrail, not a filesystem isolation boundary. SSHFS and the reverse
SSH key still require A to be trusted with access to the selected project-host account.

## 8. Invariants

1. `simple-bootstrap.sh` is the only public simple entry.
2. Keep emitted commands compact but copyable: a few short lines, no long single-line shell blobs.
3. If YOLO is explicit in the invocation, pass `--yolo` and do not ask again.
4. Do not scan remote servers to discover projects in simple flows; ask for paths locally and cache
   confirmed answers as defaults.
5. `laptop-setup.sh` remains standalone when fetched to a laptop without a local install.
6. Every value interpolated into a remote command is shell-quoted with `sq()`.
7. Session cleanup removes mounts, injected rules, temp configs, and tunnels when no remaining mount
   needs them.
