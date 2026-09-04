---
description: Connect this agent to a project on another machine via remote-harness simple workflows
---

Run the **remote-harness** simple workflow.

Read `~/.remote-harness/SKILL.md` and return the reverse bootstrap command immediately. Do not ask
for SSH targets, paths, ports, or namespaces in chat; the command prompts for them in the user's
local terminal. Remote-only mode is mandatory: opencode and every child agent stay on the remote
server. If the user asks to run an agent locally, explain that the maintained fork rejects it.
The setup scripts use session-local SSH config files and wrappers under `~/.remote-harness`.
Mention `~/.ssh` edits only for the reverse-mode `authorized_keys` temporary forced-command block;
do not imply that config, known_hosts, or user-managed SSH keys are edited.

Because this adapter is for opencode, the emitted command must use:

```bash
--launch opencode
```

If the user asks for yolo / bypass approvals, append `--yolo`.
