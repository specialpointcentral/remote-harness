# Remote-Only Gateway 实施计划

本计划对应英文主计划 [2026-09-04-remote-only-gateway.md](2026-09-04-remote-only-gateway.md)。

目标是让所有受支持的编码 Agent 只在远端服务器运行，同时让本机保存项目并执行项目命令。实施范围包括：
每会话 reverse key 与 forced gateway、彻底禁用本机 Agent/forward 入口、Claude/Codex hook、opencode
`tool.execute.before` plugin、cwd 映射、本机 Agent CLI 拒绝、AI 凭据清除、完整回归与双语文档。

最终交付前必须完成英文计划 Task 4 中的全部验证、暂存 diff 检查、凭据扫描、feature branch 推送、
Ubuntu/macOS CI、fork `main` 快进和 `main` CI 验证。
