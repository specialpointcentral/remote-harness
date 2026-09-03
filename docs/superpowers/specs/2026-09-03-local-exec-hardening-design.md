# Local Execution Hardening Design

## Goal

Keep Claude Code or Codex on the agent host for file-oriented work over SSHFS while routing every
shell command to the project host. A routing failure must stop the command instead of falling back
to execution on the agent host.

## Architecture

`inject-rule.sh` creates a session runner and a `PreToolUse` hook. The hook reads the tool event,
maps the invocation working directory from the SSHFS mount to the corresponding project-host
directory, preserves the original tool input, and replaces only the command. The session runner
forwards the encoded command to `run-on-project-host.sh`, which streams a small POSIX dispatcher
through SSH and executes the command in the project host's login shell.

The SSHFS mount remains the file transport. Read, edit, write, and patch tools continue to operate
on the mount. All Bash calls, including Git and read-only inspection commands, use the project host.

## Enforcement

- Rule or hook creation failure aborts the session launch.
- A hook invocation outside the configured mount is denied.
- Invalid relative paths are rejected on both hosts.
- SSH or project-host failures are returned as command failures; the original command is never run
  on the agent host.
- Codex receives a session-local inline hook configuration and explicit trust for that generated
  hook. Claude receives a session-local settings file.

## Compatibility

The strict route requires `python3` on the agent host for JSON hook handling. The project host needs
only POSIX `sh`, a base64 decoder, and its normal login shell. Existing reverse and forward flows,
session-local SSH configuration, SSHFS cleanup, and user-owned SSH settings remain unchanged.

Interactive PTY and arbitrary port forwarding are not part of strict routing. Long-running
processes should use non-interactive commands; services running on the local project host are
already reachable by the local user.

## Tests

Regression coverage must prove command rewriting, cwd mapping, tool-input preservation, outside-
mount denial, invalid-path rejection, fail-closed launch behavior, and valid Claude/Codex hook
configuration. Existing regression tests and shell syntax checks remain required.
