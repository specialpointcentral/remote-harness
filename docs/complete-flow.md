# Remote Harness Complete Flow

> Chinese counterpart: [complete-flow.cn.md](complete-flow.cn.md). Visual HTML: [complete-flow.html](complete-flow.html).

This document summarizes the current simple reverse and simple forward flows from skill invocation
to the final Codex TUI launch.

## Roles

| Role | Reverse | Forward |
|---|---|---|
| User terminal running the bootstrap command | laptop | local machine |
| Codex runtime | remote box | local machine |
| Project and real toolchain | laptop | SSH server |
| Script source | local install or remote skill/source | local install or remote skill/source |

Short trigger phrases:

- Reverse: "remote dev local project" / "远程开发本地".
- Forward: "local dev remote project" / "本地开发远程项目".
- Ambiguous: omit `--mode`; `simple-dispatch.sh` asks locally and defaults to reverse.

## Common Entry

```mermaid
flowchart LR
  U["User invokes $remote-harness"] --> S["SKILL.md selects mode/language/launch/yolo"]
  S --> C["Copyable local bootstrap command"]
  C --> B["simple-bootstrap.sh"]
  B --> D["simple-dispatch.sh"]
  D -->|reverse| R["simple-laptop-setup.sh"]
  D -->|forward| F["simple-local-setup.sh"]
```

The skill only returns the command. SSH targets, paths, mountpoints, and launch choices are collected
in the user's local terminal. If YOLO was explicit in the invocation, the command includes `--yolo`
and the local wizard does not ask again.

`simple-bootstrap.sh` either delegates to a local install or fetches the helper bundle from a remote
source into local `~/.remote-harness/.sessions/bootstrap.*`, then calls `simple-dispatch.sh`.

## Reverse

Reverse means Codex runs on the remote box while the project and toolchain remain on the laptop.

```mermaid
sequenceDiagram
  participant User as Local terminal
  participant Wizard as simple-laptop-setup.sh
  participant Remote as Remote box
  participant Laptop as Laptop sshd
  participant Codex as Remote Codex

  User->>Wizard: mode=reverse, launch=codex
  Wizard->>User: ask remote target, local project, remote mountpoint
  Wizard->>Remote: setup-tunnel.sh --config ... --alias rlocal --gen-key
  Remote-->>Wizard: PORT / CONFIG / PUBKEY
  Wizard->>User: laptop-setup.sh
  User->>Remote: ssh -N with RemoteForward
  Remote->>Laptop: sshfs rlocal:project to remote mountpoint
  Remote->>Remote: inject-rule.sh on codex
  User->>Codex: ssh -tt remote box, cd mountpoint, launch codex
```

Key details:

- Remote `rlocal` lives only in remote `~/.remote-harness/.sessions/.../ssh_config`.
- The laptop-to-box RemoteForward alias lives only in local
  `~/.remote-harness/.sessions/rev.*/ssh_config`.
- The remote box reuses or creates a dedicated key under remote `~/.remote-harness/keys/id_ed25519`.
- The laptop may temporarily add a tagged, loopback-scoped
  `remote-harness:reverse-auth:<tag>` block to `~/.ssh/authorized_keys`; it is reference-counted
  and removed when the last session exits.
- Codex is launched on the remote box inside the remote mountpoint.
- The injected hook rewrites every Codex Bash command to a session runner. The runner maps the
  SSHFS-relative cwd and executes the encoded command on the laptop through `rlocal`.

## Forward

Forward means Codex runs locally while the project and toolchain live on an SSH server.

```mermaid
sequenceDiagram
  participant User as Local terminal
  participant Wizard as simple-local-setup.sh
  participant Server as SSH server
  participant Codex as Local Codex

  User->>Wizard: mode=forward, launch=codex
  Wizard->>User: ask server target, server project, local mountpoint
  Wizard->>User: local-setup.sh
  User->>User: create session ssh_config
  User->>Server: sshfs alias:project to local mountpoint
  User->>User: inject-rule.sh on codex
  User->>Codex: cd local mountpoint, launch codex
```

Key details:

- `local-setup.sh` always uses a session-local SSH config under
  `~/.remote-harness/.sessions/fwd.*`.
- Raw SSH args become a session-local `<host>-dev` alias; an existing Host alias is used through a
  read-only include of the user's SSH config.
- Files are read, written, edited, and searched in the local sshfs mount.
- Every Codex Bash command is rewritten to the server with mount-relative cwd mapping.
- Codex is launched locally inside the local mountpoint.

## Codex Injection

`inject-rule.sh` does not modify global Codex config. It writes session artifacts under
`~/.remote-harness/.sessions/<session-key>`.

| Mode | Codex cwd | File work | Bash commands |
|---|---|---|---|
| Reverse | remote mountpoint | remote mount, writes back to laptop | Hook routes to laptop |
| Forward | local mountpoint | local mount, writes back to server | Hook routes to server |

For Codex, the rule and inline `PreToolUse` hook are passed as session config. The hook calls a
generated runner under `~/.remote-harness/.sessions/<session-key>/bin`; routing setup failure aborts
launch. Non-YOLO sessions also get workspace-write, network access, and session writable roots.

## Cleanup

Reverse cleanup unmounts remote sshfs, removes the remote rule and temp SSH config, closes the
reverse tunnel when no other mount needs it, removes the temporary authorized_keys block when its
reference count reaches zero, and removes the local temp SSH config.

Forward cleanup unmounts local sshfs, removes the local rule, removes the session SSH config, and
removes the default empty mountpoint when possible.

## Long-Running Stability

Session-local SSH config, temporary `known_hosts`, `sshfs reconnect`, and keepalive options improve
one-session reliability, but shared remote boxes and many long-lived SSHFS mounts still need
server-side capacity. Use [`ssh-sshfs-long-lived-connections.md`](ssh-sshfs-long-lived-connections.md)
to review `sshd` `MaxStartups` / `MaxSessions` / `ClientAlive*`, systemd/PAM `nofile`, and TCP
queues.
