# Claude Multi-Agent Support

> Chinese counterpart: [claude-multi-agent.cn.md](claude-multi-agent.cn.md).

## Supported In One Harness Session

Claude Code settings hooks also run inside subagents. The remote-harness `PreToolUse` hook therefore
routes Bash calls from the main conversation, ordinary subagents, named subagents, and nested
subagents through the same project-host runner. Hook payloads may contain `agent_id` and
`agent_type`; routing is intentionally independent of those fields.

Named subagents can use Claude's `SendMessage` capability to communicate with siblings or resume a
completed agent. Messages are text, not permission grants. When a receiving agent acts on a
message, its own Bash call still passes through the routing hook.

All agents in one harness session share the same SSHFS mount. Assign disjoint file ownership and do
not run conflicting migrations, Git mutations, dev servers, or stateful tests concurrently.

## Blocked In Strict Sessions

Strict Claude sessions set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0`. Agent Teams use independent
Claude sessions, and the official documentation does not promise that a temporary lead-session
`--settings` file is inherited by every teammate, especially a split-pane process.

Claude worktree isolation is blocked through three layers:

- `PreToolUse` denies an `Agent` call containing `isolation: worktree`.
- Session permissions deny `EnterWorktree` and `ExitWorktree`.
- A `WorktreeCreate` hook exits non-zero.

Claude-created worktrees are agent-host paths. A worktree created by a command routed to the project
host returns a project-host absolute path that Claude on the agent host cannot enter, so silently
allowing this mode would break cwd mapping and may bypass the intended mount.

## Recommended Isolated Parallel Topology

Create separate Git worktrees on the project host, then start one remote-harness session per
worktree with a unique agent-host mountpoint:

```text
project host                         agent host
project/.worktrees/api       <----> mount/api       Claude session @api
project/.worktrees/frontend  <----> mount/frontend  Claude session @frontend
project/.worktrees/review    <----> mount/review    Claude session @review
```

Each session owns its own hook, runner, SSH config, cwd mapping, and branch. Claude Code
cross-session messaging can coordinate the independently launched sessions when they run under the
same remote user. Merge or cherry-pick on the project host after each worktree is verified.

## Current Verification

The repository regression suite verifies subagent-shaped hook payloads, ordinary Agent calls,
worktree-isolation denial, Claude settings parsing, and the worktree blocker. A real multi-agent
Claude run still needs a two-host integration test after the laptop SSH/SSHFS prerequisites are
enabled.
