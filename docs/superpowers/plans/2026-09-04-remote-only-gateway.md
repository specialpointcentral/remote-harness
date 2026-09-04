# Remote-Only Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every supported coding Agent runs remotely while local files and project commands remain on the project host.

**Architecture:** Reverse-only bootstrap creates a per-session key whose local authorization is bound to a forced SSH gateway. Claude/Codex hooks and an opencode plugin rewrite Bash to a fixed encoded protocol; the local dispatcher validates cwd and blocks Agent CLI launches.

**Tech Stack:** Bash, POSIX sh, Python 3, JavaScript plugin hooks, OpenSSH, SSHFS, Claude Code, Codex, opencode.

## Global Constraints

- No supported entrypoint may launch an Agent on the local project host.
- Public setup is reverse-only; compatibility forward entries fail before work.
- Every reverse session uses a new key and a forced local authorization.
- Project commands fail closed when routing is unavailable.
- English and Chinese documentation remain paired.
- Absolute isolation is documented as requiring a dedicated restricted local OS account.

---

### Task 1: Forced Gateway And Per-Session Key

**Files:**
- Create: `scripts/project-host-gateway.sh`
- Modify: `scripts/setup-tunnel.sh`
- Modify: `scripts/laptop-setup.sh`
- Modify: `scripts/check-tunnel.sh`
- Test: `tests/regression.sh`

**Interfaces:**
- Consumes: session tag, registered project root, `SSH_ORIGINAL_COMMAND`.
- Produces: SFTP, `remote-harness-health`, and `remote-harness-exec` only.

- [x] Add regression assertions for arbitrary-shell denial, SFTP dispatch, key location, and the generated authorization line.
- [x] Confirm the assertions fail against unrestricted authorization and reusable key behavior.
- [x] Install the gateway, register the project root, bind the key with `command=`, and disable PTY/forwarding.
- [x] Change tunnel health checks and command transport to the fixed protocol.
- [x] Run `bash tests/regression.sh` and confirm these assertions pass.

### Task 2: Remote-Only Entrypoints

**Files:**
- Modify: `scripts/simple-dispatch.sh`
- Modify: `scripts/simple-bootstrap.sh`
- Replace: `scripts/simple-local-setup.sh`
- Replace: `scripts/local-setup.sh`
- Test: `tests/regression.sh`

**Interfaces:**
- Consumes: optional historical `--mode` input.
- Produces: reverse wizard dispatch or a remote-only error.

- [x] Add tests proving explicit and cached forward requests cannot launch a helper.
- [x] Replace local-agent setup scripts with rejection stubs.
- [x] Remove the mode picker and forward dispatch branch.
- [x] Keep historical forward spellings only so they can return a clear error.
- [x] Run the regression suite.

### Task 3: Agent Command Routing

**Files:**
- Modify: `scripts/route-command.py`
- Modify: `scripts/run-on-project-host.sh`
- Modify: `scripts/inject-rule.sh`
- Test: `tests/regression.sh`

**Interfaces:**
- Consumes: Bash command, remote mount cwd, session runner, local project root.
- Produces: `rh-run <cwd-b64> <command-b64>` and local project-shell execution.

- [x] Add tests for root/subdirectory cwd mapping and direct/indirect Agent CLI denial.
- [x] Reject direct Claude/Codex/opencode launches in the hook and local dispatcher.
- [x] Scrub common AI credentials and shadow Agent binaries in local `PATH`.
- [x] Add an opencode `tool.execute.before` plugin that rewrites every Bash call and denies outside-mount workdirs.
- [x] Require an opencode plugin readiness marker before launching the interactive Agent.
- [x] Require route configuration for Claude, Codex, and opencode before launch.
- [x] Run the regression suite and import the generated opencode plugin in Node.

### Task 4: Documentation And Delivery

**Files:**
- Modify: `README.md`, `SKILL.md`, `SKILL.cn.md`, `AGENTS.md`, `AGENTS.cn.md`
- Modify: `adapters/`, `reference/`, `docs/`
- Test: `tests/regression.sh`

**Interfaces:**
- Produces: one consistent reverse-only user and maintainer contract.

- [x] Remove recommendations for local-agent/forward operation.
- [x] Document Claude multi-agent inheritance and the opencode plugin.
- [x] Document account-level SFTP and the dedicated-account absolute boundary.
- [x] Run regression, shell syntax, Python compile, skill validation, YAML parse, and `git diff --check`.
- [x] Inspect the staged diff and scan it for credentials.
- [x] Commit with the configured GitHub noreply identity and push the feature branch.
- [x] Wait for Ubuntu and macOS CI, fast-forward fork `main`, and verify `main` CI.
