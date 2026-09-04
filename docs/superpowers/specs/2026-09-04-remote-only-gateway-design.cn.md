# Remote-Only Gateway 设计

> 英文版见 [2026-09-04-remote-only-gateway-design.md](2026-09-04-remote-only-gateway-design.md)。

## 目标

所有受支持的 Claude、Codex、opencode、subagent、嵌套 Agent 和独立 Agent 会话都运行在远端服务器。
本机保存项目并执行普通项目命令。

## 架构

本地 bootstrap 建立反向 SSH 隧道。每次会话在远端创建新 key，并且该 key 在本机只获得 forced-command
授权。SSHFS 通过 forced command 的 SFTP 把本机项目暴露给远端服务器。Claude/Codex hook 和 opencode
`tool.execute.before` plugin 把 Bash 改写到会话 runner；runner 向本机 gateway 发送固定编码执行请求。

gateway 只接受标准 SFTP、`remote-harness-health` 和
`remote-harness-exec <root-b64> <cwd-b64> <command-b64>`。它验证登记的项目根并拒绝任意 SSH 命令。
本机 dispatcher 验证物理 cwd、清除常见 AI 凭据、屏蔽 Agent CLI 名称，再用本机登录 shell 执行命令。

## 禁用路径

`--mode forward`、`simple-local-setup.sh` 和 `local-setup.sh` 在挂载、连接或启动前失败。项目命令若
直接启动 `claude`、`codex` 或 `opencode` 也会被拒绝。Claude Agent 工具留在远端；Claude worktree
创建和 Agent Teams 被禁用。

## 多 Agent

普通、具名和嵌套 Claude subagent 继承会话 hook 并留在远端。具名 Agent 可使用 Claude 消息机制。
需要隔离的并行 writer 时，在本机创建多个 Git worktree，并为每个 worktree 启动一个 reverse 会话。

## 安全边界

forced key 不能打开普通本机 SSH shell。但这不是 OS sandbox：任意项目 shell 是图灵完备的，SFTP 也是
账号级访问，并没有 chroot 到选定项目。绝对边界需要独立本机 OS 账号；该账号只能访问目标项目，
不安装 Agent，也不保存 AI 凭据。

## 验证

回归测试覆盖固定协议执行、任意 shell 拒绝、SFTP 分发、根目录和子目录 cwd 映射、每会话 key、实际生成
的 forced 授权、本机 Agent 拒绝、forward 入口禁用、Claude hook 继承和 opencode plugin 改写。
