# Simple 流程方案

## 结论

可行。`remote-harness` 现有反向流程里，真正需要 Agent 做的事情只是收集连接信息、项目目录、挂载点和启动偏好；后续的隧道、SSH 认证检查、挂载、规则注入和启动已经由脚本完成。把这些交互迁移到用户本地终端后，Agent 可以只返回一条通用命令和说明，不再接触本地路径、服务器地址、远端账号、端口等具体信息。

本文覆盖 simple reverse：Agent 运行在远端机器，代码在用户本地笔记本。Simple forward 已在
`docs/simple-forward-flow.cn.md` 中单独实现和说明。

"远程开发本地"、"远端开发本地项目" 这类简短说法应选择该模式。"本地开发远程项目" 应选择
simple forward。若请求模糊，则输出不带 `--mode` 的 `simple-bootstrap.sh`；它会移交给
`simple-dispatch.sh` 在本地选择，默认 reverse。

## 参考 CodexMonitor 的流程抽象

remote-harness-gui 的 CodexMonitor 二开实现把 Remote Harness 的关键边界放得很清楚：

- `src/features/workspaces/components/AddWorkspacePrompt.tsx` 在本地 UI 收集 SSH target、本地目录、远端挂载路径、Agent 启动参数等。
- `src/services/tauri.ts` 和 `src-tauri/src/workspaces/commands.rs` 负责 SSH 检查、目录选择、挂载远端 home 等本地侧动作。
- `src-tauri/src/backend/app_server.rs` 生成远端执行脚本和 app-server 连接逻辑，Agent 进入的是已经准备好的 workspace。
- `REMOTE_BACKEND_POC.md` 和 `docs/mobile-ios-tailscale-blueprint.md` 的远端 daemon/TCP/token 方案也遵循同一个原则：连接配置与执行权在应用/本地运行时里，Agent 不负责询问和持有这些值。

Shell 版没有 GUI，所以等价替代是：用本地 CLI wizard 收集信息，用脚本执行确定性步骤，让 skill 只给用户一条 bootstrap 命令。唯一例外是远端 SSH target 的最佳努力默认值：Agent 本来就在那台远端机器上运行，可以知道远端用户名/地址；该值只是可编辑默认值，本地缓存仍然优先。

## 隐私边界

新的默认边界如下：

- Agent 只输出固定模板命令，不询问本地笔记本信息、本地路径、远端挂载路径、反向端口或命名空间。
- 用户在本地终端输入 SSH target、本地项目目录、可选远端挂载点和是否启用 YOLO/免审批模式。
- 如果本地缓存里没有 SSH target，第一次 SSH target 提示可以使用 `scripts/suggest-via.sh` 生成的服务器侧建议值。该脚本只能使用远端 `id -un`、服务器地址和服务器 SSH 端口。
- 若用 `SSH_CONNECTION` 生成建议值，只能使用第 3/4 字段（`server-ip` / `server-port`）。第 1/2 字段是本地客户端数据，不能打印、缓存或嵌入命令。
- 建议的 SSH target 只是可编辑默认值。它在 Host 别名、跳板机、NAT、VPN、IPv6、公网/内网地址选择等场景下可能不准，所以用户始终可以覆盖。
- 如果调用时已经要求 YOLO/免审批模式，bootstrap 命令会包含 `--yolo`，本地向导不会再问一次。
  如果调用时没有明确要求，则本地向导按本地缓存作为默认值询问。
- simple 反向流程默认使用固定的远端回连别名 `rlocal`。
- `rlocal` 只写入远端会话级临时 ssh config：`~/.remote-harness/.sessions/.../ssh_config`。
- simple 反向流程把临时 SSH config 和 `known_hosts` 放在
  `~/.remote-harness/.sessions/...`，并关闭 OpenSSH multiplexing；退出清理时会尽量删除这些会话级目录。
  它不写 `~/.ssh/config`、`known_hosts` 或 SSH key；唯一的 `~/.ssh` 修改是笔记本侧用于临时反向认证的
  `authorized_keys` 托管块。
- Claude/Codex 启动时加入会话级 `PreToolUse` hook 和 runner，自动把 Bash 路由到 `rlocal`；
  opencode 继续使用临时 `ssh` wrapper 和提示词规则。
- 服务器只在实际部署时收到必要配置，例如 `rlocal` 临时别名、反向端口和挂载请求。
- 本地路径不会进入 Agent 聊天上下文；如果用户不主动粘贴，Agent 看不到这些值。

## 用户体验

公开 simple 入口统一为 `scripts/simple-bootstrap.sh`。命令总是在本地运行，但脚本可以来自本地安装，
也可以从远端 skill/source 安装目录读取。Agent 的回答只包含类似命令：

```bash
(
set -f
p="remote-harness 来源 SSH 目标/参数"
d="<default_via>"
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
  '\''cat "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh"'\'' |
  RH_VIA="$h" RH_LANG=zh bash -s -- --mode reverse --launch codex
)
```

输出命令的维护原则：尽量减少行数，但不能为了少行数制造超长行；简单本地处理可以用分号合并，
远端 `ssh ... | bash ...` 管道保持为短行续行，确保用户能从 Codex/聊天界面直接复制运行。

运行后，本地终端会询问：

- 远端 SSH target/args，例如 `-p 2222 user@example.com` 或 SSH config 的 `Host` 别名；下次默认使用本地缓存值。若没有缓存，则使用远端建议值。
- 本地项目目录，默认当前目录。
- 远端挂载点，留空则使用远端 `~/.remote-harness/mounts/<project>`。
- 是否用 YOLO/免审批模式启动，默认 yes，除非本地缓存记录为 no；如果调用时已明确要求，则跳过。

目录推荐暂不实现；用户直接输入路径，脚本校验目录是否存在。

本地脚本会把上次成功确认的参数写入 `~/.remote-harness/simple-cache.env`，下次作为默认值展示。
缓存只保存在本机，不发送给 Agent；如需清空，删除该文件即可。

## 执行流程

1. Agent 可先运行 `scripts/suggest-via.sh`，然后输出带 `--mode reverse` 的 `simple-bootstrap.sh` 命令，并把该值作为可编辑的 SSH target 默认值。
2. 若不假设本地已有 remote-harness，用户在本地终端输入 remote-harness source SSH target；命令通过 SSH 从该 source 读取 `~/.remote-harness/scripts/simple-bootstrap.sh`。
3. `simple-bootstrap.sh` 从 source 抓取本地侧 helper bundle 到 `~/.remote-harness/.sessions` 下的临时目录，然后调用
   `simple-dispatch.sh --mode reverse --source-via <source>`。
4. `simple-dispatch.sh` 移交给 `simple-laptop-setup.sh`。
5. `simple-laptop-setup.sh` 在本地终端收集项目目录、可选挂载点和 YOLO 启动偏好。若已经传入
   `--yolo`，则跳过 YOLO 提问。
6. `simple-laptop-setup.sh` 在远端创建临时 ssh config 路径：`~/.remote-harness/.sessions/.../ssh_config`。
7. `simple-laptop-setup.sh` 通过 SSH 调远端 `setup-tunnel.sh --config <临时config> --namespace rlocal --alias rlocal --gen-key`，准备反向隧道别名和 remote-harness 专用 key。
8. `simple-laptop-setup.sh` 调用现有 `laptop-setup.sh`，并传入 `--box-ssh-config <临时config>`。
9. `laptop-setup.sh` 会为笔记本到远端的 RemoteForward alias 创建本地会话级 ssh config，并通过内部
   `ssh` wrapper 保持脚本调用仍是短命令（`ssh <target>`）。
10. `laptop-setup.sh` 后续所有远端回连笔记本的操作都显式使用远端这份 config：`check-tunnel.sh`、
   `mount-project.sh`、端口切换后的别名重写、Claude/Codex runner，以及 opencode 会话 `ssh` wrapper。
11. Agent 退出后，脚本自动卸载、清理会话级规则、删除两端的临时 ssh config，并清理
    `~/.remote-harness/mounts` 下的默认空挂载目录。

## 前置条件

- 远端已安装 remote-harness，默认在 `~/.remote-harness`，或者设置了远端环境变量 `RH_HOME`。
- 用户本地 SSH 公钥已经配置到远端服务器，可以免密或通过本地 ssh-agent 登录。
- 远端通过反向隧道登录笔记本时，使用远端 `~/.remote-harness/keys` 下生成/复用的
  remote-harness key。本地 setup 会先检查 `authorized_keys` 中是否已有匹配且有效的授权；没有时才追加
  带 `remote-harness:reverse-auth:<tag>` 标签、仅限回环来源的托管块，并在退出且没有其他活动会话引用时删除。
- 本地机器可运行 SSH server；脚本会检测并在可行时提示开启。
- 远端机器有 `sshfs` 和 FUSE；缺失时 `laptop-setup.sh` 会给出安装命令并允许重试。
- 远端机器已经安装要启动的 Agent CLI：`codex`、`claude` 或 `opencode`。
- 多用户共享远端机器或大量长期 SSHFS 挂载场景，建议按
  `docs/ssh-sshfs-long-lived-connections.cn.md` 优化 sshd 容量、keepalive、`nofile` 和 TCP 队列。

## 失败与恢复

- SSH target 填错：重新运行命令。
- 远端缺少 `~/.remote-harness`：先在远端安装或同步 remote-harness。
- 远端缺少 `sshfs`：按脚本提示安装后重试。
- 挂载点非空：按脚本提示换一个空目录。
- 隧道端口冲突：现有 `laptop-setup.sh` 会尝试切换到邻近端口并更新远端别名。

## 已实现文件

- `scripts/simple-bootstrap.sh`：统一 simple bootstrap，可本地运行或从远端读取后在本地运行。
- `scripts/simple-dispatch.sh`：本地模式分发器。
- `scripts/simple-laptop-setup.sh`：本地 CLI wizard，收集参数并交给现有反向流程。
- `scripts/setup-tunnel.sh --config`：支持写入远端会话级临时 ssh config。
- `scripts/check-tunnel.sh --ssh-config`：检查隧道时使用指定 config。
- `scripts/mount-project.sh --ssh-config`：sshfs 挂载时使用指定 config。
- `scripts/laptop-setup.sh --box-ssh-config`：把临时 config 贯穿核心反向流程。
- `SKILL.md` / `SKILL.cn.md`：默认只输出 simple 命令，不再要求 Agent 逐项提问。
- `adapters/codex*.md` / `adapters/opencode*.md`：按运行时传入对应 `--launch`。

## 后续可扩展

- 为 simple forward 增加更多真实双机端到端覆盖。
- 增加可选的目录选择器，但仍必须在本地终端或 GUI 中完成，不能回退到 Agent 询问。
