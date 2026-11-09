# Native Paseo chat for Claude

For Codex, follow the [native Codex setup](codex-native.md). This page covers Claude.

The project host keeps the files, runs the reverse bootstrap, and executes routed Bash commands.
The agent host runs both Claude and Paseo. Open the native Claude conversation on a phone paired
with that Paseo daemon. File tools use the SSHFS mount, and Claude's routed Git and ripgrep scans
run on the project host.

## Agent host setup

Install the current Harness scripts and use Paseo daemon 0.15.3 with Node.js 22+, Python 3, and
Claude Code 2.1.295 or newer. Run Paseo under the same account that owns the Harness mount and make
sure its Claude provider can authenticate. The bridge checks the version of the Claude configured
in Paseo. Set up the daemon and pair the phone using the [Paseo connectivity guide](https://paseo.sh/docs/connectivity).

Install the pinned client on the agent host if the bridge cannot find it beside the Paseo CLI.

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
npm install --prefix "$rh/paseo" @getpaseo/client@0.15.3
```

Configure the Claude provider to use the Harness wrapper. First save the actual Claude executable
on the agent host (replace the example path):

```bash
(umask 077
 mkdir -p "$rh/paseo"
 printf '%s\n' '{"claude":"/absolute/path/to/claude"}' > "$rh/paseo/claude.json")
```

In Paseo's existing daemon configuration, set `agents.providers.claude.command` to the one-element
array `["/absolute/path/to/.remote-harness/scripts/paseo-claude.py"]`. Keep the other provider and
account settings. The bridge refuses to start if this wrapper is missing from the provider command.
The wrapper passes ordinary chats in other projects through to the configured Claude unchanged.

The bridge defaults to `ws://127.0.0.1:6767/ws`. For a different loopback WebSocket listener, export
`RH_PASEO_URL` in the agent host's SSH login shell environment. Export `RH_PASEO_PASSWORD` there if
the listener requires a password. Export `RH_PASEO_MODEL` there to select a model explicitly.
Without a model override, Claude uses the provider default.

The daemon's Claude provider defaults must leave `options.settings` and the older `params.settings`
unset. Paseo 0.15.3 can otherwise overwrite the Harness hook settings when starting Claude.
The bridge checks this before creating a conversation. Keep the provider command and options
compatible while using Harness conversations, including when viewing or reopening old ones.

## Start and stop

Run the bootstrap from a terminal on the project host and select the agent host and project
directory in the wizard. For a local Harness installation, use the following command. For a remote
installation, append the same `--ui paseo` flag to [the fetch command](../reference/reverse.md#bootstrap-shape).

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch claude --ui paseo
```

Open the new **Remote Harness · project-name** conversation in Paseo and send the first prompt there.
Normal approvals appear in Paseo. Auto uses the daemon's Claude mode when available and falls back
to normal approvals. YOLO follows the existing explicit opt-in.

Keep the project host awake and its launcher running. Closing the phone app or finishing a Claude
turn leaves the session active. Archive or delete the conversation in Paseo, or press Ctrl-C in the
project-host terminal, to end the session and release its mount and command transport. On launcher
exit, Harness also attempts to archive the conversation in Paseo. If an interrupted exit leaves the
conversation visible, its tool lease has expired. Run a fresh bootstrap to create a new conversation.

Paseo mode always creates a new conversation. The `RH_RESUME` prompt applies to terminal launches.
Ordinary Claude subagents inherit the session hooks. Paseo management tools are disabled within the
Harness Claude session. Paseo's own workspace terminals, scripts and source-control actions run
on the agent host. Use the Claude chat tools for Harness routing.

Only launcher-created chats may use a Harness workspace. A manually created ordinary chat in
that directory or a subdirectory is refused by the configured Claude/Codex wrappers before the
agent starts; ordinary chats in other projects are allowed. Configure the corresponding wrapper
for each Claude/Codex provider you enable. The UI may still create an unusable tab: close that
extra tab and return to the original Harness conversation. For another Harness conversation,
rerun the original bootstrap on the project host. Keep `$RH_HOME/.paseo-workspaces`: these path
reservations remain after cleanup so an old workspace cannot silently become an ordinary chat.
Existing running sessions need a new launch to acquire this reservation and wrapper binding.

## Smoke test

Use a disposable project. Ask Claude in Paseo to create a file and run a command that prints
`pwd` and `hostname`. Verify the file and command output on the project host. Reopen the phone app
and send a follow-up in the same conversation, then archive it and verify the local launcher
completes cleanup. For a separate session, press Ctrl-C and verify the old conversation's tools
are blocked if it is later unarchived.

Run the optional loopback integration tests with installed Paseo server and client packages (both
0.15.3) and a real Claude CLI. The tests start a temporary daemon, use a dummy model endpoint and
verify native approval and routing, plus refusal of conflicting daemon defaults.

```bash
RH_TEST_CLAUDE_CLI=/path/to/claude \
RH_TEST_PASEO_NODE_MODULES=/path/to/node_modules \
python3 tests/test_paseo.py -v
```
