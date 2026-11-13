# Native Codex chat in Paseo and Orca

The reverse launcher runs on the project host. The agent host runs the manager and a private
Codex app server for each Harness chat. Open the conversation on a client paired to that manager.
Project files remain on the project host.

## Agent host setup

Install the current Harness scripts. Native Codex requires **codex-cli 0.167.0** and **Python
3.11+** in the Harness SSH login environment. Use Paseo daemon **0.15.3** with Node.js 22+, or
Orca Server **1.4.251** or **1.4.254**. The manager and the Harness login must run as the same
Unix user.
For client installation and pairing, see the [Paseo guide](paseo.md) or [Orca guide](orca.md).

On the agent host, set the actual Codex executable in a private file. Substitute its absolute path.

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
(umask 077
 cat > "$rh/codex.json" <<'JSON'
{"codex": "/absolute/path/to/codex"}
JSON
 chmod 600 "$rh/codex.json")
printf '%s\n' "$rh/scripts/native-codex.py"
```

- **Paseo.** Set the Codex provider's command to the single absolute wrapper path printed above.
  In the daemon config this is `agents.providers.codex.command = ["<absolute wrapper path>"]`
  (JSON). Install the pinned Paseo client as described in the [Paseo guide](paseo.md). Optionally
  set `RH_PASEO_MODEL` in the Harness SSH login environment.
- **Orca.** Set the server's Codex **Command** to the same wrapper path, with empty Codex
  **Arguments**. Create a private `$RH_HOME/orca/codex.json` containing `{}` if you use the default
  server profile and project group. Set mode 700 on the `orca` directory and mode 600 on the file.
  Optional keys `profile`, `projectGroupId` and `model` select the server profile, local project
  group and initial Codex model as in the [Orca guide](orca.md). The group must have a folder path
  so the workspace appears in the desktop client's remote workspace list. Harness checks that
  list before reporting the chat ready.

Keep the wrapper selected when reopening native Harness chats. For ordinary manager chats the
wrapper passes through to the configured Codex executable. The wrapper uses the manager's selected
Codex account (`CODEX_HOME`, default `~/.codex`) and provider environment. It copies model and
provider settings and any private `auth.json` into a session-only Codex home. It uses a private copy
of the configured or bundled model catalog, with direct tool calls and native Multi-Agent V2
enabled. Model IDs, collaboration metadata and the configured provider are preserved. Use file
login or provider environment credentials. Keyring-only login requires switching to a supported credential
source. Refreshes in the session's private file do not update the source account. For concurrent
launches or long-lived credentials, use the provider's supported API-key environment configuration
where available.

## Launch and approvals

On the project host, use the usual [reverse bootstrap](../reference/reverse.md#bootstrap-shape)
with the appropriate UI.

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch codex --ui paseo --approval normal
# For Orca, use --ui orca.
```

Open the Codex conversation in the paired app and send the first prompt there. The chat uses
Harness's private `remote_harness` MCP server for shell commands. The approval card shows the
original command and project-relative working directory. `normal` asks in the app for each
routed command or MCP write. `auto` sends those approvals to Codex automatic review. `yolo`
bypasses those approvals when explicitly selected. Native file edits remain sandboxed to the
workspace in every mode. Codex's `apply_patch` is available when the selected model exposes it.
The private `read_file` and `write_file` tools also work on UTF-8 files in the mount.

Routed commands use the existing forced SSH gateway, without stdin or a PTY. Codex execution
rules in the selected account's `rules/` and `/etc/codex/rules/` are checked with Codex
`execpolicy` against the command segments recognized by the gateway. A forbidden rule blocks
the command in every mode. A prompt rule blocks it in YOLO. Allow rules do not skip native MCP
approval. Project Codex config and external MCP servers, plugins, and executable tools are left
out of this session. Built-in shell and code execution tools are disabled. Native Codex subagents
run on the agent host inside the same private app server. The V2 `collaboration` tools spawn named
children, send messages and follow-up tasks, wait for mailbox updates, and interrupt child turns.
Children share the parent’s mount, routed tools and approval mode. In normal mode the manager
shows the child's original command and working directory before it runs. A child can use the
default full-history fork or start with fresh context via `fork_turns="none"`. Codex uses the
model's collaboration metadata to decide whether a child can spawn further descendants. Separate
workspaces require separate launches.

In an Orca Harness workspace, use the chat created by the launcher. Clicking **+** to open
another Codex chat does not register a new Harness connection: the configured wrapper refuses
that chat before starting Codex and tells you to return to the existing chat or rerun your
original Harness launch command on the project host. Orca Server 1.4.251 and 1.4.254 have no
per-workspace setting to disable **+**, so an unusable chat tab may still appear. Close only that
extra tab. Keep the configured wrapper selected for this protection to apply.
Paseo also reserves each Harness workspace under `$RH_HOME/.paseo-workspaces`; its Codex wrapper
refuses ordinary chats in those directories while allowing ordinary chats elsewhere. Preserve
these reservations after cleanup. If Claude is also enabled, configure its wrapper as described
in the [Paseo guide](paseo.md) or [Orca guide](orca.md) so switching providers cannot bypass the
workspace check. Existing Paseo sessions need a new launch to acquire the reservation.

## Disconnect and stop

Keep the project host and its launcher running. An idle chat or a disconnected phone does not
end the lease. Archive or delete the agent in Paseo, close the chat or archive the folder in
Orca, or press Ctrl-C in the project-host terminal to end it. When the bridge's lease expires,
the private Codex app server stops and the routed tools refuse further calls. A later launch
creates a new chat. Existing app history may remain visible. Keep the Orca mount and identity
reservations. Manager terminals, workspace scripts, and Git UI still run on the agent host.
An Orca Server restart keeps the chat as described in the [Orca guide](orca.md#start-and-stop).

For a smoke test, use a disposable project. In the chat, read and edit a file, then approve a
routed command that prints `pwd` and `hostname`. Verify the file and command output on the
project host. Reopen the app and send a follow-up while the launcher is live. End the session
and check that the old chat cannot run a new command.

Maintainers can exercise the app server and both installed managers with an isolated loopback
model. The manager test expects the pinned Orca CLI and a `node_modules` directory containing
`@getpaseo/client@0.15.3` and `@getpaseo/server@0.15.3`. Both test commands require `zstd`.

```bash
RH_TEST_CODEX_CLI=/absolute/path/to/codex python3 tests/test_native_codex.py -v
RH_TEST_CODEX_CLI=/absolute/path/to/codex RH_TEST_ORCA_CLI=/absolute/path/to/orca \
  RH_TEST_PASEO_NODE_MODULES=/absolute/path/to/node_modules \
  python3 tests/test_native_codex_managers.py -v
```
