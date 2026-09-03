---
name: remote-harness
description: >-
  将 coding-agent 会话连接到另一台机器上的项目，并避免在聊天中收集具体路径或凭据。支持 simple reverse
  （Agent 在远端机器，项目在用户笔记本）和 simple forward（Agent/Codex 在本地，项目与开发环境在 SSH
  服务器）。调用时只返回一条本地 bootstrap 命令；该命令在用户终端中提示输入信息，通过 sshfs 挂载项目，
  注入“在项目所在机器运行命令”的规则，并在挂载目录中启动 claude/codex/opencode。
---

> 中文版。英文原版见 [SKILL.md](SKILL.md)（以英文版为准）。

# Remote Harness

默认模式是 **simple reverse**。当用户明确要求本地 Codex/Agent 连接服务器上的项目或开发环境时，
使用 **simple forward**。

根据用户的简短说法推断模式：

- Simple forward：例如 "本地开发远程项目"、"本地开发服务器项目"、"local dev remote project"、
  "local Codex with server project"、"project/dev environment on server"。
- Simple reverse：例如 "远程开发本地"、"远程开发本地项目"、"远端开发本地"、"remote dev local project"、
  "remote agent with laptop project"。
- 模糊：如果无法准确推定 forward 或 reverse，返回不带 `--mode` 的统一命令。模式提示默认
  reverse，并像其他 simple 选择一样缓存在本地。

## 模式

Simple reverse：

- 编程 Agent 运行在远端机器。
- 代码库在用户笔记本上。
- Agent 不询问本地笔记本信息、本地路径、远端挂载路径、反向端口或命名空间。
- Agent 可以只基于服务器侧事实生成一个远端 SSH target 默认建议值。
- Agent 的任务只是返回一条命令和简短说明。
- 所有具体值都在用户本地终端里输入，不进入聊天上下文。
- 保护本地/客户端信息。若从 `SSH_CONNECTION` 推导默认值，只能使用第 3/4 字段（`server-ip` /
  `server-port`），绝不能暴露第 1/2 字段（`client-ip` / `client-port`）。
- SSH 提示默认值的优先级是：本地缓存优先，其次远端建议值；用户始终可以编辑覆盖。

Simple forward：

- 编程 Agent 运行在本地。
- 项目和开发环境位于可直接 SSH 访问的服务器。
- 命令在本地提示服务器 SSH target、服务器项目目录、可选本地挂载点和启动偏好。
- 文件读取、写入、编辑、搜索都在本地 sshfs 映射目录中进行。
- Claude/Codex 的每个 Bash 调用都会按挂载点相对 cwd 自动路由到服务器；路由创建失败时拒绝启动。
  opencode 仍使用注入的 SSH 提示词规则。

reverse、forward 和无法判断的请求都使用统一的 simple bootstrap 流程。

## 运行时

按当前 Agent 运行时设置启动命令：

- Codex：`--launch codex`
- Claude Code：`--launch claude`
- opencode：`--launch opencode`

如果用户调用时要求 "yolo"、"bypass approvals"、"skip permissions"、"危险模式"、"免审批" 或
"开启yolo模式"，在最终本地命令参数末尾追加 `--yolo`。否则不要追加。
如果因为用户要求而追加了 `--yolo`，本地向导必须把它视为最终选择，不再二次询问是否开启
YOLO/免审批模式。

仅 simple reverse：回复前，如可行，先运行：

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/suggest-via.sh"
```

仅当输出 `STATUS=ok` 时，把它的 `VIA=` 值填入 `<default_via>`；否则省略
`RH_DEFAULT_VIA=...` 前缀。这个值只是提示默认值。不要把辅助脚本输出原样放进回复。

## 输出给用户

### 统一命令

reverse、forward 和不确定模式都输出同一个脚本入口：`scripts/simple-bootstrap.sh`。命令总是在本地执行，
但脚本本身可能在本地，也可能需要从安装了这个 skill 的远端机器读取。用 fenced `bash` 代码块返回，不要放进
项目符号或编号列表。命令要优先保证可复制：尽量少行，但每一行都不能长到容易被 Codex/聊天界面自动换行切断。
`simple-bootstrap.sh` 会委托给 `simple-dispatch.sh`；用户不直接调用 dispatcher。

当请求明确是远端 Agent 开发本地笔记本项目时，使用 `--mode reverse`。当请求明确是本地 Agent 开发服务器项目时，
使用 `--mode forward`。当请求无法判断时，省略 `--mode`；dispatcher 会在本地询问，第一次默认
reverse，并缓存模式选择。

如果用户运行命令的本机已经安装 remote-harness，使用本地形式：

```bash
RH_LANG=<lang> bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  <mode-arg> --launch <launch>
```

如果 skill/source 目录在远端机器上，或者不确定本地是否已有安装，使用 fetch 形式。把
`<source_prompt>` 替换成 `remote-harness 来源 SSH 目标/参数` 或
`remote-harness source SSH target/args`，把 `<default_via>` 替换成远端建议值或空字符串，
并使用同样的 `<mode-arg>` 规则：

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
  RH_VIA="$h" RH_LANG=<lang> bash -s -- <mode-arg> --launch <launch>
)
```

`<mode-arg>` 为：

- 明确 simple reverse 时：`--mode reverse`；
- 明确 simple forward 时：`--mode forward`；
- 不确定模式时：省略。

只有当调用中明确要求 YOLO/免审批/无审核模式时，才追加 `--yolo`。在 fetch 形式中，source SSH target
只是 remote-harness 脚本来源；reverse 模式会复用它作为远端盒子 target，forward 模式仍会在本地另行询问项目服务器 target。

用户应在新开的本地终端运行命令。

### Simple Reverse

命令启动后，终端会询问：

- 远端 SSH target/args 或 Host 别名，并以上次本地缓存值作为默认；若无缓存，则使用远端建议值；
- 本地项目目录；
- 可选远端挂载点，留空则使用远端 `~/.remote-harness/mounts/<project>`；
- 是否用 YOLO/免审批模式启动，默认 yes，除非本地缓存记录为 no。若调用时已经明确要求 yolo，
  且命令包含 `--yolo`，则跳过这个问题。

脚本默认使用固定的本次会话笔记本别名 `rlocal`。在 simple 流程中，这个别名只写入远端临时
ssh config：`~/.remote-harness/.sessions/.../ssh_config`，退出清理时删除；不会在远端
`~/.ssh` 下创建或修改任何文件。笔记本侧携带 RemoteForward 的 alias 也只写到本地
`~/.remote-harness/.sessions/.../ssh_config`，由 setup 脚本内部 ssh wrapper 隐藏，并在退出时清理；
临时 SSH config 和 `known_hosts` 都位于 `~/.remote-harness/.sessions/...`，不会写入笔记本
`~/.ssh`；会话 config 会关闭 OpenSSH multiplexing。

反向认证方面，远端会在自己的 `~/.remote-harness/keys` 下生成或复用 remote-harness key。本地 setup
可以把这把公钥加入笔记本 `~/.ssh/authorized_keys` 中带
`remote-harness:reverse-auth:<tag>` 标签的托管块，并用 `from="127.0.0.1,::1"` 限制为回环来源。
追加前会先检查本机是否已有匹配且有效的授权；已有则复用，不重复追加。托管授权会在
`~/.remote-harness/.sessions/authorized-keys/...` 下引用计数，退出时只有没有活动会话继续引用才删除。

Claude/Codex 会获得会话级 `PreToolUse` hook 和 runner。Agent 直接运行普通相对命令，hook 会把挂载
目录 cwd 映射到笔记本项目并改写 Bash。opencode 继续使用会话级 `ssh` wrapper 和明确 SSH 指令。

脚本会把上次确认过的值记录在本地 `~/.remote-harness/simple-cache.env`，下次作为默认值展示。
该缓存只在本地；删除此文件即可重置默认值。

simple 流程暂不做目录推荐。

### Simple Forward

forward 模式启动后，终端会询问：

- 服务器 SSH target/args 或 Host 别名，并以上次本地缓存值作为默认；
- 服务器项目目录，并以上次本地缓存值作为默认；
- 可选本地挂载点，留空则使用本地 `~/.remote-harness/mounts/<project>`；
- 是否用 YOLO/免审批模式启动，默认 yes，除非本地缓存记录为 no。若调用时已经明确要求 yolo，
  且命令包含 `--yolo`，则跳过这个问题。

启动后的 Agent 工作在本地挂载目录中。Claude/Codex 的文件工具使用挂载目录，所有 Bash 自动改写到
服务器；严格路由创建失败则中止启动。opencode 保留提示词 SSH 路由。退出 Agent 后自动卸载项目并
删除会话产物。

forward setup 始终使用本地 `~/.remote-harness/.sessions/.../ssh_config` 下的会话级 ssh config。
当用户输入的是原始 SSH 参数而不是 Host alias 时，会在其中创建会话级 `<host>-dev` alias。它不会在本地
`~/.ssh` 下创建或修改任何文件；临时 `known_hosts` 也位于 `~/.remote-harness/.sessions/...`，
且会话 config 会关闭 OpenSSH multiplexing。临时 config 会通过同样的会话级 `ssh` wrapper 对启动后的 Agent 隐藏。

## 前置条件

- 脚本来源：remote-harness 已安装在本地 `~/.remote-harness`，或安装在 fetch 命令使用的 SSH source 机器上。
- Simple reverse：远端已安装 remote-harness，默认在 `~/.remote-harness`，或者远端 `RH_HOME` 指向安装目录。
- Simple reverse：笔记本可以用已配置好的 SSH key 登录远端。
- Simple reverse：远端可以通过反向隧道登录笔记本。本地 setup 可以把 remote-harness 公钥作为带标签、
  仅限回环来源的临时块写入 `~/.ssh/authorized_keys`，退出时删除；若本机已有匹配且有效的用户授权，
  则直接复用且不修改。
- Simple reverse：远端有 `sshfs` 和要启动的 Agent CLI。
- Claude/Codex：Agent 主机有 `python3`；项目主机有 POSIX `sh` 和 base64。
- Simple reverse：笔记本可以运行 SSH server；必要时 `laptop-setup.sh` 会检测并提示开启。
- Simple forward：本地机器可以 SSH 登录服务器，并且本地有 `sshfs`；缺失时脚本会提示安装。
- 多用户共享远端服务器或存在大量长期 SSHFS 挂载时，建议优化 sshd 容量、keepalive、文件描述符和
  TCP 队列。这不是单个小会话的硬性前置条件；详见 `docs/ssh-sshfs-long-lived-connections.cn.md`。

## 更多细节

可行性分析和完整方案见：

- `docs/complete-flow.md`
- `docs/complete-flow.cn.md`
- `docs/complete-flow.html`
- `docs/simple-flow.md`
- `docs/simple-flow.cn.md`
- `docs/simple-forward-flow.md`
- `docs/simple-forward-flow.cn.md`
- `docs/ssh-sshfs-long-lived-connections.md`
- `docs/ssh-sshfs-long-lived-connections.cn.md`
