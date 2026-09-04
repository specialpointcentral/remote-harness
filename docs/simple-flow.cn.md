# Simple Remote-Only 流程

> 英文版见 [simple-flow.md](simple-flow.md)。

## 契约

维护 fork 只支持一种拓扑：

- Claude、Codex、opencode、subagent、嵌套 Agent 和独立 Agent 会话全部运行在远端服务器。
- 本机项目通过 SSHFS 挂载到远端服务器。
- Bash 命令通过 forced SSH gateway 回到本机，并且只能在已登记的本机项目根内执行。

本机 Agent/forward 请求会在挂载或启动之前被拒绝。省略 mode 时也直接选择 reverse，不再显示模式选择器。

## Bootstrap

公开入口是 `scripts/simple-bootstrap.sh`，并在本机运行。如果本机没有 helper bundle，bootstrap 会从
远端 remote-harness 安装目录读取所需脚本，临时放到本机 `~/.remote-harness/.sessions/...`。

编码 Agent 应立即返回 bootstrap 命令。SSH target、本机路径、远端挂载点、端口和 namespace 都由
本地终端收集，不进入 Agent 对话。远端 `scripts/suggest-via.sh` 的结果只能作为可编辑默认值。

## 执行顺序

1. `simple-bootstrap.sh` 调用 `simple-dispatch.sh`；dispatcher 只接受 reverse。
2. `simple-laptop-setup.sh` 在本地收集远端 SSH target、本机项目目录、可选远端挂载点、Agent CLI
   和审批模式。
3. 远端 `setup-tunnel.sh` 创建会话目录、会话级 SSH config、known-hosts 文件和新的每会话 Ed25519 key。
4. `laptop-setup.sh` 把 `project-host-gateway.sh` 和 `run-on-project-host.sh` 的稳定副本安装到本机
   `~/.remote-harness/bin`。
5. 本机项目根登记到
   `~/.remote-harness/.sessions/gateways/<session-tag>/project-root.b64`。
6. 每会话公钥以带标签托管块加入本机 `~/.ssh/authorized_keys`。授权行只允许来自回环隧道的连接，
   绑定 forced gateway command，并禁用 PTY、port、X11 和 SSH-agent forwarding。
7. 本机 SSH 连接向远端服务器建立 `RemoteForward <port> 127.0.0.1:22`。
8. 远端服务器使用会话 key/config，通过 SSHFS 挂载选定的本机项目。
9. opencode 会先在远端预加载会话 plugin，并且必须写出 readiness marker；失败时在交互式 Agent 启动前中止。
10. 选定 Agent 只在远端服务器、SSHFS 挂载目录内启动。
11. Claude/Codex `PreToolUse` hook 或 opencode `tool.execute.before` plugin 把 Bash 改写到会话
    runner。runner 只通过 forced gateway 发送
    `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`。
12. 本机 dispatcher 验证项目根和物理 cwd，清除常见 AI 凭据环境变量，在 `PATH` 中屏蔽
    `claude`、`codex`、`opencode`，再用本机登录 shell 执行项目命令。
13. 退出清理会删除挂载、注入规则、远端会话 key/config/runtime、本机 gateway 登记、临时授权和
    本机会话 config。

## Gateway 协议

本机 forced gateway 只接受：

- SSHFS 所需的标准 SFTP 请求；
- `remote-harness-health`；
- 固定的 `remote-harness-exec` 请求。

任意 SSH 命令都会被拒绝。如果同一 key 已在托管 forced gateway 块之外获得授权，也会拒绝继续，
因为该授权能够绕过 gateway。

## 多 Agent 行为

Claude 普通、具名和嵌套 subagent 都由远端 Claude 进程创建。它们的 Bash 调用继承同一 hook 并回到
本机项目主机执行；具名 Agent 可使用 Claude 自身的消息能力，同时仍留在远端。

Agent Teams 默认禁用，因为独立 teammate 会话不保证继承临时 settings。Claude worktree 创建被阻止，
因为远端 Agent 主机上的 worktree 无法映射到登记的本机项目根。需要隔离并行开发时，应在本机创建多个
Git worktree，并为每个 worktree 启动一个 remote-harness 会话。

## 安全边界

forced gateway 阻止反向 key 打开任意本机 SSH shell。hook 和 dispatcher 还会拒绝直接启动 Agent CLI、
清除常见 AI 凭据，并屏蔽常见 Agent 二进制名称。

这些措施是围绕通用项目 shell 的策略约束，不是完整 OS sandbox。任意 shell 是图灵完备的，SFTP 也没有
chroot 到选定项目。若需要绝对的“本机不能运行 Agent”以及“只能看到项目目录”边界，应让本机 SSH gateway
运行在独立 OS 账号下；该账号只能访问目标项目，不安装 Agent CLI，也不保存 AI 凭据。

## 前置条件

- 本机可 SSH 登录远端服务器；远端已经安装 remote-harness 和选定 Agent CLI。
- 本机运行 SSH server。
- 远端服务器安装 SSHFS 和 FUSE。
- Claude/Codex 严格路由要求远端 Agent 主机安装 Python 3；opencode 需要当前
  `tool.execute.before` plugin 接口。
- 本机项目主机需要 POSIX `sh`、base64 解码器和项目工具链。
- 远端服务器 sshd 允许 reverse TCP forwarding。

共享服务器或长期连接的容量优化见
[ssh-sshfs-long-lived-connections.cn.md](ssh-sshfs-long-lived-connections.cn.md)。
