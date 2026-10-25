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
      RemoteForward <port> 127.0.0.1:22    # 或用户态 sshd 的回环端口

远端会话 ssh_config:
  Host rlocal
      HostName 127.0.0.1
      Port <port>
```

simple reverse 将会话 config 和 `known_hosts` 放在 `~/.remote-harness/.sessions/...`，关闭
OpenSSH multiplexing（生成的 config 保持 `ControlMaster no`；路由命令和工具垫片只在命令行上使用
会话级、短路径的复用 master），并在退出时尽量清理临时状态。它不写 `~/.ssh/config`、`known_hosts` 或 SSH key。
唯一的 `~/.ssh` 修改是笔记本侧用于临时反向认证的 `authorized_keys` 托管块；下文的用户态 sshd 连这一处也不改。

## 用户态 sshd

当笔记本的 sshd 不读取 `~/.ssh/authorized_keys`（FreeIPA/sssd 或 LDAP 通过 `AuthorizedKeysCommand`
取公钥、`AuthorizedKeysFile none`、home 在 root_squash 的 NFS 上），或本机没有 SSH 服务时，设置
`RH_LOCAL_SSHD=user`（或给 `simple-laptop-setup.sh` / `laptop-setup.sh` 传 `--local-sshd user`）。
向导检测到 `AuthorizedKeysCommand` 或 `:22` 无服务时会主动询问，并把明确的选择记为
`LAST_LOCAL_SSHD`；`RH_LOCAL_SSHD=system` 可改回。

此时 `laptop-setup.sh` 以当前用户身份为本次会话启动 sshd：在探测到的空闲端口上
`ListenAddress 127.0.0.1`（绑定时被抢占会换端口重试，绑定成功后才写隧道的 `RemoteForward`）、会话私有的
`authorized_keys`（内容是同样的 forced-gateway 授权行）、`AuthorizedKeysCommand none`、
`AuthenticationMethods publickey`、`UsePAM no`、`DisableForwarding yes`、`PermitTTY no`。文件位于
`~/.remote-harness/.sessions/rev.*/sshd/`；资源记录在核对 PID、启动时间和配置路径后，随隧道一起停止它。
挂载失败时会打印其日志中的拒绝原因。它需要 sshd 程序但不需要 root；它不经过 PAM，目录服务的 HBAC
策略不作用于这条回环登录。

## Bootstrap 形态

如果脚本来源在远端，skill 输出紧凑的 fetch 形式。保持 zsh 兼容：不要使用 `read -p`。

```bash
(
set -f
umask 077
p='remote-harness 来源 SSH 目标/参数'
d='<default_via>'
printf '%s' "$p${d:+ [$d]}: " >/dev/tty
IFS= read -r h </dev/tty || exit 2
h=${h:-$d}; h=${h#ssh }; [ -n "$h" ] || exit 2
mkdir -p "$HOME/.remote-harness/.sessions"
s=$(mktemp -d "$HOME/.remote-harness/.sessions/fetch.XXXXXX") || exit 1
trap 'rm -rf "$s"' EXIT
ssh -n -o ClearAllForwardings=yes \
  -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o CheckHostIP=no \
  -o ControlMaster=no -o ControlPath=none \
  $h \
  'cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"' \
  > "$s/simple-bootstrap.sh" || exit 1
[ -s "$s/simple-bootstrap.sh" ] || exit 1
bash -n "$s/simple-bootstrap.sh" || exit 1
RH_VIA="$h" RH_LANG=<lang> bash "$s/simple-bootstrap.sh" --mode reverse --launch <launch>
)
```

## 运行流程

1. 外层完整下载 `simple-bootstrap.sh` 并检查语法后才在本地执行。来源 alias 的已验证主机身份
   保留，采用严格校验，不更新 known-hosts。随后一次 SSH 下载全部八个 helper、bootstrap 副本
   和 SHA-256 清单；文件名、类型、摘要、bootstrap 一致性和 Bash 语法均通过后才启动本地向导。
   包校验详见 `docs/simple-flow.cn.md`。
2. `simple-dispatch.sh --mode reverse` 移交给 `simple-laptop-setup.sh`。
3. `simple-laptop-setup.sh` 在本地提示远端 SSH target、本地项目目录、可选远端挂载点，以及调用中未明确指定时的审批模式（默认 auto，可选普通/YOLO）。
4. 它准备远端会话 config 路径，并调用远端
   `setup-tunnel.sh --config <remote-session-config> --alias rlocal --namespace rlocal --gen-key`。
5. 它用 `--box-ssh-config <remote-session-config>` 调用 `laptop-setup.sh`。
6. `laptop-setup.sh` 创建携带 RemoteForward 的笔记本侧会话 config，通过内部 ssh wrapper 连接，
   在远端挂载笔记本项目，为 Claude/Codex 安装严格 hook，或为 opencode 安装路由 plugin，
   然后在远端启动选定 Agent。
7. 退出时自动卸载 sshfs、删除会话规则、在没有其它挂载需要时断开反向隧道、删除临时 ssh config，
   并清理默认空挂载目录。
8. 如果连接被强制关闭、本机没来得及执行上述清理，远端会话 watcher 会发现 Agent 已退出（或终端
   已挂断），自行完成远端清理；重启等原因遗留的状态由下次启动时的 GC 处理。watcher 还会每
   `RH_HEARTBEAT_INTERVAL`（30）秒经隧道检查一次项目主机，连续失败满 `RH_HEARTBEAT_TIMEOUT`（600）秒
   后结束 Agent。
9. 因断线结束的会话会留下 `$RH_HOME/.sessions/.resume/<挂载点>.<agent>`；下次启动同一挂载点、同一
   Agent 时询问一次是否继续该对话（`--continue` / `resume --last`），`RH_RESUME=1|0` 可强制指定。本机
   清理在远端不可达时按 `RH_RELEASE_RETRY_DELAYS`（10 20 30）秒重试，之后只停止本次启动创建的隧道及其
   用户态 sshd 和本机授权。

## 前置条件

- 笔记本可以用用户已有 SSH key 登录远端盒子。
- 远端盒子通过反向隧道登录笔记本时，使用与本次会话 SSH config 放在一起的新 key。本地 setup 会先
  检查本机是否已有匹配且有效的授权；没有时才追加带
  `remote-harness:reverse-auth:<tag>` 标签、仅限回环来源的 `~/.ssh/authorized_keys` 托管块。
  托管块会引用计数，并在没有活动会话继续使用时于退出清理中删除。
- 远端盒子已安装 remote-harness，默认在 `~/.remote-harness`，或设置了 `RH_HOME`。
- 笔记本可以运行 SSH server；向导会在可行时检测并提示开启。没有 root，或该 sshd 不读取
  `~/.ssh/authorized_keys` 时，改用用户态 sshd。
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
- 在 FreeIPA/sssd 管理、sshd 不读取 `~/.ssh/authorized_keys` 的笔记本上挂载失败（`read: Connection
  reset by peer`、`Permission denied`）：加 `RH_LOCAL_SSHD=user` 重新运行。
- 高负载下频繁断连：检查服务端 `MaxStartups`、`ClientAlive*`、`nofile` 和 TCP 队列设置；
  见 `docs/ssh-sshfs-long-lived-connections.cn.md`。
