> 中文版。英文原版见 [forward.md](forward.md)（以英文版为准）。

# Forward 模式已禁用

本 fork 是 remote-only。Claude、Codex、opencode、subagent 和独立 Agent 会话必须运行在远端服务器。
`--mode forward`、`simple-local-setup.sh` 和 `local-setup.sh` 会在本机项目主机执行挂载或启动前返回错误。

请使用 `simple-bootstrap.sh --mode reverse`。需要隔离并行 Agent 时，在本机项目主机创建多个 Git
worktree，并在远端服务器为每个 worktree 启动一个 reverse remote-harness 会话。
