> 中文版。英文原版见 [reverse.md](reverse.md)（以英文版为准）。

# Simple reverse 参考

Simple reverse 表示：编程 Agent 运行在远端盒子，项目位于用户笔记本。公开 skill 不在聊天中询问
笔记本路径、挂载路径、反向端口或命名空间，而是返回一条运行 `simple-bootstrap.sh` 的本地命令；
具体值由本地终端向导收集。

"远程开发本地"、"远端开发本地项目"、"remote dev local project" 这类说法选择本模式。无法判断时，
省略 `--mode`，让 `simple-dispatch.sh` 在本地询问。

## 隧道模型

笔记本主动向远端盒子打开反向 SSH 隧道。两侧 SSH alias 都是会话级临时配置：

```text
笔记本会话 ssh_config:
  Host <box-session-alias>
      RemoteForward <port> 127.0.0.1:22

远端会话 ssh_config:
  Host rlocal
      HostName 127.0.0.1
      Port <port>
```

simple reverse 将会话 config 和 `known_hosts` 放在 `~/.remote-harness/.sessions/...`，关闭
OpenSSH multiplexing，并在退出时尽量清理临时状态。它不写 `~/.ssh/config`、`known_hosts` 或 SSH key。
唯一的 `~/.ssh` 修改是笔记本侧用于临时反向认证的 `authorized_keys` 托管块。

## Bootstrap 形态

如果脚本来源在远端，skill 输出紧凑的 fetch 形式。保持 zsh 兼容：不要使用 `read -p`。

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
  RH_VIA="$h" RH_LANG=<lang> bash -s -- --mode reverse --launch <launch>
)
```

## 运行流程

1. `simple-bootstrap.sh` 在本地运行。若它是从远端读取的，会把 `_common.sh`、`simple-dispatch.sh`、
   `simple-laptop-setup.sh`、`laptop-setup.sh` 及必要 helper 拉到本地临时目录。
2. `simple-dispatch.sh --mode reverse` 移交给 `simple-laptop-setup.sh`。
3. `simple-laptop-setup.sh` 在本地提示远端 SSH target、本地项目目录、可选远端挂载点，以及调用中未明确指定时的 YOLO 偏好。
4. 它准备远端会话 config 路径，并调用远端
   `setup-tunnel.sh --config <remote-session-config> --alias rlocal --namespace rlocal --gen-key`。
5. 它用 `--box-ssh-config <remote-session-config>` 调用 `laptop-setup.sh`。
6. `laptop-setup.sh` 创建携带 RemoteForward 的笔记本侧会话 config，通过内部 ssh wrapper 连接，
   在远端挂载笔记本项目，为 Claude/Codex 安装严格命令路由（或为 opencode 注入 SSH 规则），
   然后在远端启动选定 Agent。
7. 退出时自动卸载 sshfs、删除会话规则、在没有其它挂载需要时断开反向隧道、删除临时 ssh config，
   并清理默认空挂载目录。

## 前置条件

- 笔记本可以用用户已有 SSH key 登录远端盒子。
- 远端盒子通过反向隧道登录笔记本时，使用远端 `~/.remote-harness/keys` 下生成/复用的
  remote-harness key。本地 setup 会先检查本机是否已有匹配且有效的授权；没有时才追加带
  `remote-harness:reverse-auth:<tag>` 标签、仅限回环来源的 `~/.ssh/authorized_keys` 托管块。
  托管块会引用计数，并在没有活动会话继续使用时于退出清理中删除。
- 远端盒子已安装 remote-harness，默认在 `~/.remote-harness`，或设置了 `RH_HOME`。
- 笔记本可以运行 SSH server；向导会在可行时检测并提示开启。
- 远端盒子已安装 `sshfs` 和选定 Agent CLI（`codex`、`claude` 或 `opencode`）。
- 多用户共享远端盒子或存在大量长期 SSHFS 挂载时，建议按
  `docs/ssh-sshfs-long-lived-connections.cn.md` 优化服务端 sshd 容量和 keepalive。

## 故障排查

- fetch 阶段失败：检查 remote-harness 来源 SSH target，以及远端安装里是否存在
  `scripts/simple-bootstrap.sh`。
- TUI 报 `stdin is not a terminal`：启动阶段必须使用 `ssh -tt` 并把 stdin 接到控制 tty；请使用当前
  `laptop-setup.sh`。
- 端口已监听：`laptop-setup.sh` 会校验归属；若监听者不是本机，会切换到附近空闲端口。
- 陈旧挂载：退出 Agent 后重新运行 remote-harness；脚本会重新校验并替换失效 sshfs 挂载。
- 高负载下频繁断连：检查服务端 `MaxStartups`、`ClientAlive*`、`nofile` 和 TCP 队列设置；
  见 `docs/ssh-sshfs-long-lived-connections.cn.md`。
