# Claude 多 Agent 支持

> 英文版见 [claude-multi-agent.md](claude-multi-agent.md)。

## 单个 Harness 会话内支持范围

Claude Code 的 settings hooks 会继续在 subagent 内运行。因此 remote-harness 的 `PreToolUse`
hook 会把主会话、普通 subagent、具名 subagent 和嵌套 subagent 的 Bash 调用统一路由到项目主机。
hook payload 可能包含 `agent_id` 和 `agent_type`，路由逻辑不会依赖这些字段。

具名 subagents 可以使用 Claude 的 `SendMessage` 与兄弟 agent 通信，或恢复已经结束的 agent。消息只是
文本，不代表用户授权。接收方根据消息执行动作时，它自己的 Bash 调用仍然经过路由 hook。

同一 harness 会话内的所有 agents 共用一个 SSHFS 挂载目录。应分配互不重叠的文件范围，不要并发执行
相互冲突的迁移、Git 修改、开发服务器或有共享状态的测试。

## 严格会话中阻止的功能

严格 Claude 会话设置 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0`。Agent Teams 使用独立 Claude
会话，官方文档没有保证 lead 的临时 `--settings` 文件会被每个 teammate 继承，特别是 split-pane
独立进程。

Claude worktree isolation 通过三层阻止：

- `PreToolUse` 拒绝带 `isolation: worktree` 的 `Agent` 调用；
- 会话 permissions 拒绝 `EnterWorktree` 和 `ExitWorktree`；
- `WorktreeCreate` hook 以非零状态退出。

Claude 创建的 worktree 属于 Agent 主机路径。若 worktree 命令被路由到项目主机，它返回的项目主机
绝对路径又无法被 Agent 主机上的 Claude 进入，因此直接允许会破坏 cwd 映射，并可能离开预期挂载点。

## 推荐的隔离并行拓扑

先在项目主机创建多个 Git worktree，再为每个 worktree 启动一个 remote-harness 会话，并使用不同的
Agent 主机挂载点：

```text
项目主机                              Agent 主机
project/.worktrees/api       <----> mount/api       Claude session @api
project/.worktrees/frontend  <----> mount/frontend  Claude session @frontend
project/.worktrees/review    <----> mount/review    Claude session @review
```

每个会话拥有独立 hook、runner、SSH config、cwd 映射和分支。多个会话以同一个远端用户运行时，可用
Claude Code cross-session messaging 协调。每个 worktree 验证后，在项目主机完成 merge 或 cherry-pick。

## 当前验证状态

仓库回归测试已经覆盖 subagent 形态的 hook payload、普通 Agent 调用、worktree isolation 拒绝、Claude
settings 解析和 worktree blocker。启用笔记本 SSH/SSHFS 前置条件后，仍需要完成一次真实双机多 Agent
Claude 集成测试。
