# remote-harness Remote-Only 设计

> 英文版见 [design.md](design.md)。

## 角色

- **Agent 主机**：远端服务器。所有 Claude、Codex、opencode、subagent 和独立 Agent 进程都在这里运行。
- **项目主机**：用户本机。保存项目并执行项目命令。

forward/本机 Agent 模式已禁用；兼容入口在执行任何工作前失败。

## 数据流

```text
本地 bootstrap
  -> 到远端服务器的反向 SSH 隧道
  -> 远端每会话 SSH key
  -> 本机 forced-command 授权
  -> 在远端服务器 SSHFS 挂载本机项目
  -> 在远端启动 Claude/Codex/opencode

远端文件工具 -> SSHFS -> 本机项目文件
远端 Bash     -> Claude/Codex hook 或 opencode plugin -> rh-run -> forced gateway -> 本机项目命令
远端 Agent 工具 -> 远端 subagent 进程，绝不导向本机
```

## Forced Gateway

本机 `authorized_keys` 行把每会话 key 绑定到 `project-host-gateway.sh <session-tag>`，并禁用 PTY、
port、X11 和 agent forwarding。gateway 只接受：

- SSHFS 使用的标准 SFTP；
- `remote-harness-health`；
- `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`。

gateway 拒绝任意 SSH shell，并验证请求项目根与本地 bootstrap 登记的根一致。同一 key 若存在无限制
用户授权，会作为致命配置错误拒绝，而不是复用。

## 命令策略

`route-command.py` 处理 Claude/Codex。生成的 opencode `tool.execute.before` plugin 为 opencode 执行
等价的 Bash 和 cwd 改写。`run-on-project-host.sh` 校验本机物理 cwd，拒绝直接启动 Agent CLI，清除
常见 AI 凭据环境变量，在 `PATH` 中屏蔽 Agent 二进制，然后使用项目主机登录 shell 执行。

这会阻止直接和常见间接本机 Agent 路径。任意项目 shell 仍是图灵完备的，而且 gateway SFTP 没有
chroot 到登记项目。绝对安全边界需要独立本机 OS 账号；该账号只能访问目标项目，不保存 AI 凭据，
也不安装 Agent。

## Claude 多 Agent

普通、具名和嵌套 Claude subagent 都留在远端 Agent 主机。settings hook 会在这些 subagent 内运行，
只有 Bash 跨 gateway。Agent Teams 和 Claude worktree 创建被禁用。隔离并行 Agent 使用多个本机 Git
worktree 和远端服务器上的多个 reverse 会话，并通过 cross-session messaging 协调。

## 会话状态

- 远端：SSH config、host key、每会话 private key、mount、hook、runner 位于
  `~/.remote-harness/.sessions/...`。
- 本机：临时 SSH config、forced authorization 块、稳定 gateway 二进制，以及
  `~/.remote-harness/.sessions/gateways/...` 下的每会话项目根登记。

清理会删除会话状态和授权；稳定 gateway 二进制保留供后续会话使用。
