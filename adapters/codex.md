# Codex — installed as a native skill

Codex does not expose custom `/slash` commands for this workflow. `manage.sh codex` installs
remote-harness as a native Codex skill under `$CODEX_HOME/skills/remote-harness` (`CODEX_HOME`
defaults to `~/.codex`).

Invoke it with:

```text
$remote-harness
```

Codex should read `SKILL.md` and return the reverse bootstrap command immediately. Do not ask for
SSH targets, paths, ports, or namespaces in chat; the command prompts for them in the user's local
terminal. Remote-only mode is mandatory: Codex and every subagent stay on the remote server. If the
user asks to run Codex locally, explain that the maintained fork rejects that topology.
The setup scripts use session-local SSH config files and wrappers under `~/.remote-harness`.
Mention `~/.ssh` edits only for the reverse-mode `authorized_keys` temporary forced-command block;
do not imply that config, known_hosts, or user-managed SSH keys are edited.

Because this adapter is for Codex, the emitted command must use:

```bash
--launch codex
```

If the user asks for yolo / bypass approvals, append `--yolo`.

> Tip: `./manage.sh --dev codex` symlinks `$CODEX_HOME/skills/remote-harness` to this repo. Restart
> Codex after changing installed skills; a running TUI may keep the previous skill inventory.
