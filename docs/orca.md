# Native Orca chat for Claude

For Codex, follow the [native Codex setup](codex-native.md). This page covers Claude.

Run the reverse bootstrap on the project host. Its files stay there and its forced SSH gateway
executes routed Bash commands there. The agent host runs Orca Server and Claude Code. Read and
edit tools use the SSHFS mount. Claude's routed Git and ripgrep scans also run on the project host.

## Agent host setup

Install the current Remote Harness scripts under `$RH_HOME` (default `~/.remote-harness`). This
bridge requires Orca Server **1.4.251** or **1.4.254**, Python **3.8+**, and Claude Code
**2.1.295+**. Other Orca Server versions, including ones installed by Orca's automatic updates, are
refused before any workspace or chat is created; the message names the running version. Start Orca
Server and pair the phone or desktop with that server. Orca Server, Claude, and the Harness SSH
login must run under the same Unix account. Claude must be able to authenticate in the server's
environment. See [Orca Server setup and pairing](https://www.onorca.dev/docs/remote-servers).

Create the wrapper configuration on the agent host. Substitute the real Claude Code executable.

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
(umask 077
 mkdir -p "$rh/orca"
 cat > "$rh/orca/claude.json" <<'JSON'
{"claude": "/absolute/path/to/claude"}
JSON
 chmod 700 "$rh/orca"
 chmod 600 "$rh/orca/claude.json")
printf '%s\n' "$rh/scripts/orca-claude.py"
```

In the **server's** Orca settings, set the Claude **Command** to the absolute wrapper path
printed above. Keep the wrapper selected while using Harness chats, including when reopening
their history. The wrapper invokes the configured Claude executable with Orca's original
arguments for ordinary chats. Put any custom authentication in the same place Orca normally
gets its Claude account or environment. In Harness chats, saved Claude Arguments that override
the session ID, hooks, system prompt, or execution mode can cause startup to be refused.

If Orca Server uses a non-default profile, add its absolute directory as `"profile"` in
`claude.json`. The bridge reads the profile's authenticated Unix socket. The defaults are
`${XDG_CONFIG_HOME:-$HOME/.config}/orca` on Linux and `~/Library/Application Support/orca` on
macOS. Add `"model"` to select a Claude model explicitly. By default the bridge uses a local
**Remote Harness** Orca group rooted at `$RH_HOME/.orca-mounts`, creating it if needed. The group
must have a folder path: Orca omits its native folder workspaces from the remote workspace list
otherwise. Earlier groups without a folder path remain intact; new launches use the folder-backed
group. To select another local folder-backed group, set `"projectGroupId"` to its ID.

Running Harness chats keep working when Claude Code updates itself behind the configured path.
Pointing `"claude"` at a different executable requires a new Harness launch.

## Start and stop

On the project host, launch as follows for a local Harness installation. For a remote
installation, append the same `--ui orca` flag to [the fetch command](../reference/reverse.md#bootstrap-shape).

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch claude --ui orca
```

Select the agent host and project in the wizard. Orca mode creates a unique remote mount and
folder workspace per launch. It does not accept `--remote-mountpoint` or `--setup-only`. Open
**Remote Harness · project-name** in Orca on the paired device, open its **Claude Chat** tab,
and send the first prompt there. Normal mode uses Orca's native approval cards. Auto uses Claude's
automatic review when available and falls back to normal. YOLO requires explicit opt-in.

Keep the project host awake and the launcher running. Closing the phone app or finishing a Claude
turn leaves the transport active. Close the chat tab, archive the folder workspace, or press
Ctrl-C in the project-host terminal to end the session. Harness revokes the lease before cleanup.
When the launcher stops, Harness attempts to close the chat and archive its folder in Orca.
Old chat history may be visible, but using its tools requires a fresh launch. Keep the private
`.orca-identities` records and `.orca-mounts` reservations under `$RH_HOME` so old chat identities
and mount paths remain reserved.

If Orca Server restarts while the launcher runs, for example for an automatic update, the bridge
waits up to two minutes for the restarted server and repeats the startup checks on it. A verified
version keeps the chat and its lease; an unverified version ends the session. Until the restarted
server lists the chat tab again, which normally happens when a paired device reconnects, closing
the tab does not end the session; archive the workspace or press Ctrl-C instead.

Orca mode creates a new chat every time. Continue in that same chat while its launcher is live.
Claude subagents inherit the session hooks. The chat blocks direct Orca management commands
and Orca management MCP tools. Native actions that change the Claude session ID
(for example, clear, fork or rewind) are outside the registered chat. Orca's workspace terminal,
Git UI and workspace scripts operate on the agent host. Run project commands in the Claude chat.

The configured Claude wrapper refuses an ordinary chat opened with **+** inside a Harness
workspace, including its subdirectories, before starting Claude. Use the launcher-created chat
or start another Harness launch. Ordinary chats in other projects still work. The **+** button
itself remains available, so an extra failed tab may appear. If both Claude and Codex are enabled,
configure both providers' Harness wrappers; each wrapper protects launches of its own provider.

## Smoke test

Use a disposable project. Ask Claude in Orca to create a file and run a command that prints
`pwd` and `hostname`. Approve the Bash call in the chat and verify the file and command results
on the project host. Close the phone app, reopen the same conversation, and send a follow-up.
Then close the chat tab and check the project-host launcher's cleanup. A separate launch can
test archiving the workspace or pressing Ctrl-C while the phone is disconnected.
