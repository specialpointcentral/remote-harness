---
name: remote-harness
description: >-
  当 Claude、Codex 或 opencode 必须运行在远端服务器，同时编辑并执行用户本机项目时使用。只返回
  reverse bootstrap 命令；绝不在本机项目主机启动 Agent。
---

> 中文版。英文原版见 [SKILL.md](SKILL.md)（以英文版为准）。

# Remote Harness

本 fork 是 **remote-only**：

- Claude、Codex、opencode、它们的 subagent 和独立 Agent 会话都运行在远端服务器；
- 项目保留在用户本机；
- 文件工具通过远端服务器上的 SSHFS 挂载操作项目；
- Bash 命令先经 Claude/Codex hook 或 opencode 会话 plugin，再通过 forced project-host gateway
  导向本机项目环境；
- 所有公开和兼容 forward 入口都拒绝在本机启动 Agent。

明确或模糊请求都使用 reverse。若用户要求本机 Agent，应说明本 fork 有意不支持该拓扑。

## 运行时

- Codex：`--launch codex`
- Claude Code：`--launch claude`
- opencode：`--launch opencode`

仅当用户明确要求免审批模式时追加 `--yolo`。中文使用 `RH_LANG=zh`，其他情况使用 `RH_LANG=en`。

reverse 请求可先尝试获得服务器侧 SSH 建议：

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/suggest-via.sh"
```

只有 `STATUS=ok` 时才使用 `VIA=`，且它只能作为可编辑提示默认值。绝不能暴露
`SSH_CONNECTION` 的客户端地址和端口字段。

## 返回给用户的命令

若用户本机已经安装 remote-harness：

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch <launch>
```

若 skill 只安装在远端服务器，返回 fetch 形式。填入 `<source_prompt>`、`<default_via>`、
`<lang>` 和 `<launch>`；只有用户明确要求时才追加 `--yolo`。

```bash
(
set -f
p='<source_prompt>'
d='<default_via>'
printf '%s' "$p${d:+ [$d]}: " >/dev/tty
IFS= read -r h </dev/tty || exit 2
h=${h:-$d}; h=${h#ssh }; [ -n "$h" ] || exit 2
mkdir -p "$HOME/.remote-harness/.sessions"
s=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit 1
trap 'rm -rf "$s"' EXIT
ssh -n -o ClearAllForwardings=yes \
  -o UserKnownHostsFile="$s/known_hosts" \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=accept-new \
  -o ControlMaster=no -o ControlPath=none \
  $h \
  'cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"' |
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode reverse --launch <launch>
)
```

告诉用户在新的本地终端运行命令。具体 SSH target、项目路径、挂载点和审批选择都在终端收集，
不进入 Agent 聊天。

## 严格执行边界

本地 bootstrap：

1. 从本机向远端服务器建立反向 SSH 隧道；
2. 创建远端每会话 SSH key；
3. 本机只用 forced-command project-host gateway 授权该 key；
4. 在远端服务器 SSHFS 挂载本机项目；
5. 在远端服务器启动 Agent；
6. Bash 只走 `remote-harness-exec`，任意本机 SSH shell 命令会被拒绝；
7. 退出时删除挂载、会话 key、授权、gateway 登记和临时 config。

命令路由器或 opencode plugin 会在执行前改写 Bash。本机 dispatcher 拒绝直接启动 `claude`、`codex`
和 `opencode`，清除常见 AI 凭据环境变量，并在 `PATH` 中屏蔽这些二进制。这些是纵深防护；任意项目
shell 代码仍是图灵完备的，SFTP 也不是项目 chroot。若要绝对保证，需要让 project-host gateway 使用
没有 AI 凭据和 Agent 安装、且只能访问目标项目的独立 OS 账号。

## Claude 多 Agent

支持普通、具名和嵌套 Claude subagent。Claude settings hook 会继续在 subagent 内运行，因此其 Bash
使用同一条远端到本机命令路由。具名 subagent 可以通过 `SendMessage` 通信，消息不代表用户授权。

严格会话关闭 Agent Teams，并阻止 Claude 创建 worktree。需要隔离并行时：

- 在本机项目主机创建多个 Git worktree；
- 在远端服务器为每个 worktree 启动一个 reverse remote-harness 会话；
- 用 cross-session messaging 协调这些远端 Claude 会话。

完整边界见 `docs/claude-multi-agent.cn.md`。

## 前置条件

- remote-harness 和所选 Agent CLI 安装在远端服务器；
- 本机可以 SSH 到远端服务器；
- 远端服务器有 SSHFS；Claude/Codex 还需要 Python 3，opencode 需要当前
  `tool.execute.before` plugin 接口；
- 本机运行 SSH server，并有 POSIX `sh` 和 base64；
- 远端服务器被信任，可访问所挂载的项目内容；
- 本机不存在对本次生成会话 key 的无限制授权。

## 参考

- `docs/claude-multi-agent.cn.md`
- `docs/design.cn.md`
- `docs/complete-flow.cn.md`
- `docs/simple-flow.cn.md`
- `reference/reverse.cn.md`
- `reference/scripts.cn.md`
