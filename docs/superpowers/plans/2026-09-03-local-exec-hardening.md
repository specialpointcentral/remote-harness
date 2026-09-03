# Local Execution Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce project-host execution for every shell command issued by a remote-harness agent session.

**Architecture:** A session-local `PreToolUse` hook rewrites Bash commands to a generated runner. The runner maps the mount-relative cwd and forwards an encoded command through SSH to a POSIX dispatcher on the project host.

**Tech Stack:** Bash, Python 3 standard library, OpenSSH, SSHFS, Claude Code hooks, Codex hooks.

## Global Constraints

- Preserve reverse and forward behavior and session-local SSH configuration.
- Never execute the original command on the agent host after a routing error.
- Do not write hook files into the mounted repository.
- Keep English and Chinese user-facing documentation synchronized.

---

### Task 1: Command router

**Files:**
- Create: `scripts/route-command.py`
- Create: `scripts/run-on-project-host.sh`
- Modify: `tests/regression.sh`

**Interfaces:**
- Consumes: hook JSON on stdin, runner path, mount root.
- Produces: rewritten `tool_input.command` invoking the session runner.

- [x] Add failing tests for cwd mapping, input preservation, and outside-mount denial.
- [x] Run the focused regression section and confirm failure due to missing router files.
- [x] Implement the minimum router and project-host dispatcher.
- [x] Run the focused tests and existing regression suite.

### Task 2: Session hook integration and fail-closed launch

**Files:**
- Modify: `scripts/inject-rule.sh`
- Modify: `scripts/laptop-setup.sh`
- Modify: `scripts/local-setup.sh`
- Modify: `tests/regression.sh`

**Interfaces:**
- Consumes: project root, SSH alias, mount root, session SSH config.
- Produces: agent-specific launch flags plus a generated `rh-run` command.

- [x] Add failing tests for Claude/Codex hook configuration and failed-injection aborts.
- [x] Run tests and confirm the old prompt-only behavior fails them.
- [x] Generate session hook configuration and make launch fail closed.
- [x] Validate generated Codex config with the installed CLI and rerun all tests.

### Task 3: Documentation and continuous verification

**Files:**
- Modify: `README.md`, `SKILL.md`, `SKILL.cn.md`, `docs/design.md`, `docs/design.cn.md`
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Produces: documented strict routing behavior and automated regression checks.

- [x] Update the bilingual behavior and security boundaries.
- [x] Add CI for Bash syntax and `tests/regression.sh`.
- [x] Run syntax checks, regression tests, skill validation, and diff checks.
- [x] Prepare the verified change for commit and push to the maintained fork.
