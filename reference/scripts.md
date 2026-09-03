# Helper Scripts

All scripts live in `$RH/scripts/`, where `RH="${RH_HOME:-$HOME/.remote-harness}"`. Runtime scripts
print machine-readable `KEY=VALUE` on stdout and human notes on stderr.

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing - run: manage.sh"
```

## Public Simple Entry

- `"$RH/scripts/simple-bootstrap.sh"` - public unified simple entry point, run on the local machine.
  From a local install it delegates directly to `simple-dispatch.sh`. When piped from a remote skill
  install, it uses `--via`/`RH_VIA` only to fetch the current simple scripts into a local temp dir,
  then delegates there. It records the script-source `LAST_VIA` in local
  `~/.remote-harness/simple-cache.env`.
- `"$RH/scripts/simple-dispatch.sh"` - local mode dispatcher. It accepts `--mode reverse|forward`;
  when mode is omitted it prompts locally, defaults to reverse on first run, caches `LAST_MODE` in
  `~/.remote-harness/simple-mode-cache.env`, then hands off to the matching wizard.
- `"$RH/scripts/suggest-via.sh"` - remote-side default helper for the bootstrap prompt. It may use
  only the remote username, server address, and server SSH port. If it reads `SSH_CONNECTION`, it
  uses fields 3 and 4 (`server-ip` / `server-port`) and never emits local/client fields.

## Mode Wizards

- `"$RH/scripts/simple-laptop-setup.sh"` - simple reverse local wizard. It prompts locally for the
  laptop project dir, optional remote mountpoint, and launch preference. It uses fixed session alias
  `rlocal`, asks the remote box to run
  `setup-tunnel.sh --config <temp-config> --namespace rlocal --alias rlocal --gen-key`, then invokes
  `laptop-setup.sh` with the confirmed values. It caches local defaults for later runs.
- `"$RH/scripts/simple-local-setup.sh"` - simple forward local wizard. It prompts locally for server
  SSH target, server project directory, optional local mountpoint, and launch preference, saves
  confirmed defaults in `~/.remote-harness/simple-forward-cache.env`, then invokes `local-setup.sh`.

## Orchestrators

- `"$RH/scripts/laptop-setup.sh"` - reverse orchestrator, run on the laptop. It checks local sshd,
  manages a tagged temporary `authorized_keys` block when a remote-harness pubkey is provided,
  opens the reverse tunnel through a session-local ssh config, mounts the laptop project on the
  remote box, installs strict Claude/Codex routing or the opencode SSH rule, launches the agent
  remotely, then cleans up the mount, rule, tunnel state, local session config, and managed auth
  reference on exit.
- `"$RH/scripts/local-setup.sh"` - forward orchestrator, run where the local agent runs. It resolves
  the server target through a session-local ssh config, sshfs-mounts the server project locally,
  installs strict Claude/Codex routing or the opencode SSH rule, launches the agent in the local
  mount, then unmounts and removes the session config on exit.

## Shared Runtime Helpers

- `"$RH/scripts/setup-tunnel.sh"` - reverse helper, run on the remote box. It writes the `rlocal`
  alias only into a session-local config supplied with `--config <absolute-path>`, emits the selected
  port and optional generated pubkey, and stores generated remote-harness keys under
  `$RH_HOME/keys`. It never writes `~/.ssh`.
- `"$RH/scripts/check-tunnel.sh"` - reverse helper, run on the remote box. It verifies the reverse
  listener and real ssh login through `rlocal`.
- `"$RH/scripts/mount-project.sh"` - direction-neutral sshfs helper. It mounts
  `<alias>:<remote-path>` onto a local mountpoint, refuses non-empty targets unless `--force` is
  supplied, revalidates stale mounts, and supports `--unmount`.
- `"$RH/scripts/inject-rule.sh"` - direction-neutral session rule/hook helper, run where the agent
  launches. It writes per-session artifacts under `$RH_HOME/.sessions/<key>` and returns launch env
  / flags for Claude, Codex, or opencode. It never writes global agent config or the mounted repo.
- `"$RH/scripts/route-command.py"` - Claude/Codex `PreToolUse` handler. It preserves tool input,
  maps cwd relative to the mount, and replaces Bash with the session runner.
- `"$RH/scripts/run-on-project-host.sh"` - transports encoded commands over SSH and executes them
  inside the validated project-host cwd and login shell.
- `"$RH/scripts/_common.sh"` - sourced library shared by setup scripts. It provides output helpers,
  safe shell quoting, `parse_via`, session-local ssh config defaults, and managed Host block writing.

## SSH Runtime Boundary

All automatic SSH runtime state stays in `~/.remote-harness`, never `~/.ssh/config`,
`~/.ssh/known_hosts`, or generated user SSH keys. Session configs set `UserKnownHostsFile` to a temp
path under `~/.remote-harness/.sessions` and disable OpenSSH multiplexing (`ControlMaster no`) to
avoid ControlPath socket failures on macOS/FUSE-T. The only allowed automatic write under `~/.ssh` is
the reverse-mode, tagged, loopback-scoped `authorized_keys` block used for the remote-harness pubkey;
it is reference-counted and removed when the session ends.
