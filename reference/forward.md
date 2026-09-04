# Forward Mode Disabled

This fork is remote-only. Claude, Codex, opencode, subagents, and independent agent sessions must
run on the remote server. `--mode forward`, `simple-local-setup.sh`, and `local-setup.sh` return an
error before mounting or launching anything on the local project host.

Use `simple-bootstrap.sh --mode reverse`. To run isolated agents in parallel, create separate Git
worktrees on the local project host and start one reverse remote-harness session per worktree on the
remote server.
