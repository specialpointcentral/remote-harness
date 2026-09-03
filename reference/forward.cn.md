> 中文版。英文原版见 [forward.md](forward.md)（以英文版为准）。

# Simple forward 参考

Simple forward 表示：Codex 或其他编程 Agent 在本地运行，而项目文件和开发环境位于 SSH 服务器上。
用户可以说“本地开发远程项目”或“本地 Codex 开发服务器项目”。skill 仍输出同一个
`simple-bootstrap.sh` 入口，并传入 `--mode forward`。

## 边界

- 文件读取、写入、编辑和搜索发生在本地 sshfs 挂载目录。
- Claude/Codex 的 Bash 调用会按挂载点相对 cwd 自动改写到服务器；opencode 继续接收明确的
  `ssh <alias> 'cd <project> && <cmd>'` 指令。
- simple 路径不扫描服务器项目目录。服务器路径由用户输入；缓存值只作为提示默认值。

## SSH 状态

所有服务器 target 都通过本地 `~/.remote-harness/.sessions/...` 下的会话级 ssh config 使用。若用户提供
Host alias，该 alias 通过会话 config 解析；若用户提供 `-p 2222 dev@example.com` 这类原始 SSH 参数，
`local-setup.sh` 会在该 config 中创建会话级 `<host>-dev` alias。它不会在本地 `~/.ssh` 下创建或修改任何内容；
临时 `known_hosts` 留在 `~/.remote-harness/.sessions/...`，且会话 config 关闭 OpenSSH multiplexing。
临时 config 通过会话级 `ssh` wrapper 对启动后的 Agent 隐藏。

## Bootstrap 形态

本地安装：

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode forward --launch <launch>
```

远端脚本来源：

```bash
(
set -f
p='remote-harness 来源 SSH 目标/参数'
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
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode forward --launch <launch>
)
```

source SSH target 只用于读取 remote-harness 脚本。forward 模式仍会在本地另行询问项目服务器 SSH target。

## 运行流程

1. `simple-bootstrap.sh` 在本地运行，并移交给 `simple-dispatch.sh --mode forward`。
2. `simple-local-setup.sh` 在本地询问服务器 SSH target、服务器项目目录、可选本地挂载点，以及调用中未明确指定时的 YOLO 偏好。
3. 它把确认过的默认值保存到 `~/.remote-harness/simple-forward-cache.env`。
4. `local-setup.sh` 准备会话级 ssh config/服务器 alias，用 `mount-project.sh` 将
   `<server-alias>:<project>` 挂载到本地，并把会话级 ssh config 传给 `inject-rule.sh`。
5. `inject-rule.sh` 创建会话级规则和可选 ssh wrapper。
6. 选定的本地 Agent 在挂载目录中启动。
7. 退出时自动卸载 sshfs、删除会话规则、删除临时 ssh config，并在默认挂载点目录为空时清理它。

## 故障排查

- 出现密码提示：为服务器配置 SSH key，以便 sshfs 和命令执行更顺滑。
- `not-empty`：选择另一个空的本地挂载点。
- macOS sshfs：使用 FUSE-T，不使用 macFUSE；`mount-project.sh` 会给出安装提示。
- 编辑后立刻执行远端命令失败：可能是挂载尚未刷新，重跑一次；不要在本地运行构建/安装工具。
- 高负载下频繁断连：优化服务器 sshd 容量、keepalive、`nofile` 和 TCP 队列；见
  `docs/ssh-sshfs-long-lived-connections.cn.md`。
