> 中文版。英文原版见 [AGENTS.md](AGENTS.md)（以英文版为准）。

# AGENTS.md — 面向在此仓库上工作的编程智能体的指南

本仓库是 **remote-harness** 技能：它可在两种方向上连接分别位于不同机器上的编程智能体与代码库，并向用户提供一条复制即用的命令来挂载代码并启动智能体。（面向用户的文档：`README.md`；运行时技能规范：`SKILL.cn.md`。）本文件面向正在*开发* remote-harness 本身的智能体。

> `CLAUDE.md` 是指向本文件的符号链接，Claude Code 将以此加载；Codex/opencode 则原生读取 `AGENTS.md`。

## 仓库结构

- `SKILL.md` — 精简的 simple 模式技能入口。默认只输出一条本地 bootstrap 命令；不得让 Agent
  收集 SSH target、路径、端口或命名空间。
- `reference/{reverse,forward,scripts}.md` — 当前 simple reverse/forward 行为与辅助脚本契约。
- `docs/{design,complete-flow,simple-flow,simple-forward-flow,ssh-sshfs-long-lived-connections}.md`
  — 设计、完整流程、分模式方案和共享服务器 SSH/SSHFS 长连接优化。每份文档都应同步维护中文
  `.cn.md` 版本。
- `scripts/*.sh` — 确定性辅助脚本（stdout 输出 `KEY=VALUE`，stderr 输出说明信息）。`_common.sh` 是被
  source 的公共库（非入口脚本）。`simple-bootstrap.sh` 是公开的统一 simple 入口；它既可以从本地安装运行，
  也可以从远端 skill 安装目录读取后在本地运行。它会移交给 `simple-dispatch.sh`，由后者选择/分发
  reverse 或 forward；`simple-laptop-setup.sh` 和 `simple-local-setup.sh` 是分模式本地向导。
  `suggest-via.sh` 是远端侧辅助脚本，用于生成 bootstrap SSH 默认值；`laptop-setup.sh`（reverse 方向）/
  `local-setup.sh`（forward 方向）是底层编排器；`mount-project.sh`、`inject-rule.sh` 两个方向共用。
- `adapters/{codex,opencode}.md` — 各智能体专属说明。`opencode.md` 装成 opencode 的自定义命令；`codex.md` 仅供参考（Codex 没有自定义斜杠命令，所以 manage.sh 把共享的 `SKILL.md` 作为 Codex 原生**技能**装到 `$CODEX_HOME/skills/` 下，并通过 `$remote-harness` 调用）。两者都只是告知智能体读取 `SKILL.md` 并传入正确的 `--launch`。
- `manage.sh` — 安装（拷贝）/ `--dev`（符号链接）/ `--uninstall`。将核心安装到
  `~/.remote-harness/{SKILL.md,SKILL.cn.md,scripts/,reference/,docs/}`，并安装智能体专属入口文件；
  原生 skill 目录也会包含 `docs/`，确保 copy 安装后 `SKILL.md` 的链接可用。

## 当前产品形态

默认产品形态是 **simple reverse**：**A** = 运行编程 Agent 的远端机器，**P** = 位于 NAT 后、存放代码的用户笔记本。Agent 只返回一条本地 bootstrap 命令；所有具体 SSH/路径选择都在用户本地终端完成。对应支持的另一种形态是 **simple forward**：**A** = 运行 Codex/Agent 的本地机器，**P** = 存放项目和开发环境的 SSH 服务器。`reference/` 应与 simple 流程保持一致。

内部仍使用通用角色定义：**A** = 智能体运行所在机器；**P** = 代码所在机器（通过 ssh `<alias>` 访问）。底层 reverse 流程使用反向 SSH 隧道；forward 流程使用直接 ssh。两种方向均会将 P 上的项目通过 sshfs 挂载到 A 上的空目录；`inject-rule.sh` 为 Claude/Codex 安装严格 Bash 路由，或为 opencode 注入 SSH 指令，然后在挂载目录启动智能体。

## Simple Reverse 规则

- Agent 不得在聊天中询问本地笔记本信息、本地路径、远端挂载路径、反向端口或命名空间。Agent 只返回
  bootstrap 命令和简短说明。
- 公开 simple 命令必须指向 `simple-bootstrap.sh`，而不是某个分模式 helper。明确 reverse 时传
  `--mode reverse`，明确 forward 时传 `--mode forward`，无法判断时省略 `--mode`。
- 命令总是在本地执行，但脚本可能在远端。不要假设用户笔记本已有
  `~/.remote-harness/scripts`。如果 skill/source 目录在远端，应输出 fetch 形式：通过 SSH 读取远端
  `scripts/simple-bootstrap.sh`，再 pipe 给本地 `bash -s -- <mode args>`。
- bootstrap 命令必须紧凑但可复制：使用较少的短行，不要压成单个超长行。远端
  `ssh ... | bash ...` 管道保持可读续行，避免聊天界面换行切断一个逻辑 shell 行。
- 本地 bootstrap 命令可以读取本地 `LAST_VIA` 缓存来预填第一个提示。如果缓存为空，可以回退到
  `scripts/suggest-via.sh` 根据远端侧信息生成的 SSH target 建议值。
- 远端 SSH target 建议值只能使用服务器侧事实：远端 `id -un`、服务器地址和服务器 SSH 端口。若读取
  `SSH_CONNECTION`，只能使用第 3/4 字段（`server-ip` / `server-port`）；第 1/2 字段是本地客户端数据，
  绝不能打印、缓存或放入命令。
- 建议的 SSH target 只能作为可编辑的提示默认值。本地缓存优先于远端建议值；用户必须可以直接回车接受，
  也可以输入其他 Host 别名或 SSH 参数，以覆盖 ProxyJump、NAT、VPN、IPv6 或非标准路由场景。
- 如果调用时明确要求 YOLO/免审批/无审核模式，生成的命令必须传入 `--yolo`，本地向导不得再二次询问
  是否开启 YOLO。只有调用时没有做出该选择，才询问 YOLO 问题。
- 缓存的项目路径和挂载点只是默认值，不是静默选择。若存在缓存的本地项目目录，必须展示为默认值，
  让用户回车确认或输入新目录。
- simple 流程使用固定会话别名 `rlocal`。默认 simple 路径中不要重新引入 `<user>-mac` /
  `rlocal-mac` 命名。
- `rlocal` 只写入远端会话级临时 ssh config：`$RH_HOME/.sessions/.../ssh_config`。simple 路径不得写远端
  `~/.ssh/config`。
- 笔记本侧携带 RemoteForward 的 alias 也只写入本地
  `~/.remote-harness/.sessions/.../ssh_config`。`laptop-setup.sh` 不得写本地
  `~/.ssh/config`、`~/.ssh/known_hosts`、SSH key、备份文件或 control socket，也不得自动清理或重写
  用户已有 ssh config block。
- simple reverse 可以临时管理本地 `~/.ssh/authorized_keys` 中的一条远端 remote-harness key 授权。
  该授权必须放在带 `remote-harness:reverse-auth:<tag>` 范围标签的托管块中，用
  `from="127.0.0.1,::1"` 限制为回环来源，并在
  `~/.remote-harness/.sessions/authorized-keys/...` 下做引用计数；退出时只有没有其他活动会话引用时
  才删除。若本机已有匹配且有效的用户授权行，则复用它，不追加任何内容。
- 除上述 reverse-auth 明确例外外，SSH 认证仍由用户拥有。simple 流程可以读取已有用户
  SSH config/key/agent 行为，但不得安装 key，也不得静默创建凭据。
- remote-harness 的会话级 keepalive、`sshfs reconnect` 和临时 SSH config 不能替代服务器容量配置。
  多用户共享远程盒子或大量长期 SSHFS 挂载时，应在文档和用户提醒中指向
  `docs/ssh-sshfs-long-lived-connections*.md`，由服务器运维侧调整 sshd、`nofile` 和 TCP 队列。
- Claude/Codex 必须获得会话级 `PreToolUse` hook 和 `rh-run`，普通 Bash 命令按 cwd 自动映射并路由。
  临时 `bin/ssh` wrapper 继续服务于 opencode 和内部 SSH config 解析。
- 默认远端挂载点位于远端 `~/.remote-harness/mounts/<project>`，退出时如为空应清理。用户手动输入的
  挂载点属于明确选择，可以创建/使用。
- `RH_LANG=zh` 时，本地脚本提示应使用中文。skill 命令只负责选择 `RH_LANG`；其余交互由本地脚本负责。

## Simple Forward 规则

- 当用户要求本地 Codex/Agent 连接 SSH 服务器上的项目、工具链或开发环境时，使用 simple forward。
  "本地开发远程项目"、"本地开发服务器项目" 这类简短描述必须触发 forward。
- skill 输出仍应通过 `scripts/simple-bootstrap.sh`，并传入 `--mode forward`、`RH_LANG=<lang>`、
  `--launch <agent>` 和可选 `--yolo`。如果脚本来源在远端，使用 fetch 形式；source SSH target 只用于读取
  remote-harness 脚本，forward 向导会另外询问项目服务器 target。
- 服务器 SSH target、服务器项目目录、本地挂载点，以及调用中未明确指定的 YOLO 偏好，都由本地向导收集。
- simple 路径不得扫描服务器来发现项目目录。缓存值只能作为提示默认值。
- 映射目录用于本地文件读取、写入、编辑和搜索。Claude/Codex 的 Bash 调用由会话 hook 按 cwd
  自动路由到服务器；opencode 继续使用注入的 `ssh <alias> 'cd ... && <cmd>'` 规则。
- `local-setup.sh` 必须为每个服务器 target 使用会话级 SSH config，包括已有 Host alias。用户提供原始
  SSH 参数时可以创建 `<host>-dev`；用户提供 Host alias 时可通过会话 config 使用该短名。临时
  `known_hosts` 留在本地 `~/.remote-harness/.sessions/...` 下，并关闭 multiplexing。
- 默认本地挂载点位于本地 `~/.remote-harness/mounts/<project>`，退出时如为空应清理。用户手动输入的
  挂载点属于明确选择，可以创建/使用。

## 模糊 Simple 模式

- 如果用户请求无法明确判断 reverse 或 forward，输出不带 `--mode` 的 `simple-bootstrap.sh` 命令，不要在聊天中追问。
- `simple-dispatch.sh` 在本地提示 reverse/forward，第一次默认 reverse，缓存 `LAST_MODE`，然后移交给所选模式的本地向导。
- 因为每次输出的命令都在本地运行，模式、服务器、项目、挂载点和 YOLO 选择都优先放到本地终端提示和本地缓存中处理。聊天里的命令保持短，把分支逻辑放进 `simple-bootstrap.sh` / `simple-dispatch.sh`。

## 不变量 — 不得破坏

1. **`laptop-setup.sh` 必须能够独立运行。** 在 reverse 方向中，它会被下载到笔记本（笔记本上没有安装）后在那里执行。它通过 `. "$(dirname "$0")/_common.sh"` source `_common.sh`，因此生成的一条命令会将两个文件一并下载到同一个临时目录中。不要添加仅存在于安装目录中的依赖。
2. **始终确认，切勿静默选择。** 默认 simple 路径中，SSH target、项目目录、挂载点和 YOLO 偏好都必须是明确选择；缓存值或生成值只能预填。调用中明确要求 yolo 已经是选择，不要再问一次。方向和位置始终必须是用户明确选择；自动检测只用于预填。
3. **`inject-rule.sh` 与方向无关，且永远不写入已挂载的仓库。** 每次会话的临时文件位于 `$RH_HOME/.sessions/<key>` 下。规则措辞使用 `<alias>` / "this machine"。
4. **将拼接进远程命令的所有值用 `sq()`（来自 `_common.sh`）进行 shell 引号处理** — 路径中可能含有单引号；未加引号的插值存在注入/中断风险。切勿对 `--via` 使用 `eval`。
5. **可移植性**：目标平台为 Linux、WSL 和 macOS。使用 `#!/usr/bin/env bash`；避免 GNU 专属标志（提供 BSD 回退方案）；端口监听检查顺序为 `ss → netstat -an → lsof`；sshfs 安装提示应感知操作系统；**macOS 使用 FUSE-T（无需内核扩展），绝不使用 macFUSE**。探针脚本使用 `set -uo pipefail`（不用 `-e`）以保证持续输出。
6. **脚本在 stdout 输出 `KEY=VALUE`，在 stderr 输出人类可读说明。** 保持该契约不变，消费方依赖解析它。
7. **除 reverse authorized_keys 例外外，simple 路径不得把 SSH 运行期状态写进 `~/.ssh`。**
   reverse 和 forward setup 必须把会话级 ssh config、临时 `known_hosts` 及其他 SSH 运行期文件放在
   `~/.remote-harness/.sessions/...` 下。生成的 config 保持 OpenSSH multiplexing 关闭，避免 macOS 上的
   ControlPath socket 失败。simple 流程不得创建、编辑、备份、追加或清理本地或远端 `~/.ssh/config`、`known_hosts`、SSH key、`config.rh-bak.*` 或
   `known_hosts_<alias>`。唯一允许的 `~/.ssh` 修改是上文描述的 simple reverse 托管
   `authorized_keys` 块；它必须幂等、范围受限，并通过引用计数清理。为用户明确输入的 Host alias 读取
   用户已有 SSH config/key 是允许的；其他修改不允许。

## 约定

- **双语文档（必须）：** 每份 Markdown 文档必须有一个命名为 `<name>.cn.md` 的中文对应版本（中文为主要受众）。**例外：** `README.md`（行内双语，中文优先）和 `CLAUDE.md`（符号链接）。新增或编辑任何 `*.md` 时，须在同一次变更中创建/更新对应的 `*.cn.md`，以保持同步。示例：`SKILL.md`→`SKILL.cn.md`，`reference/reverse.md`→`reference/reverse.cn.md`，`adapters/codex.md`→`adapters/codex.cn.md`。
- 保持 `SKILL.md` 精简；将深度内容放入 `reference/`。
- 面向维护者的设计原则应写在 `AGENTS*.md`；只有在对用户或运行时有帮助时，才同步镜像到
  `SKILL*`/`docs*`/`reference*`。
- 每个脚本只负责一项职责；通过 `_common.sh` 共享逻辑。

## 开发与测试

- 每次修改后执行 `bash -n scripts/*.sh manage.sh`（语法检查门控）。
- 在沙盒 `HOME`/`RH_HOME` 中对各部分进行空跑（例如 `inject-rule.sh on … ; off …`；
  `mount-project.sh --unmount`；`setup-tunnel.sh --config …`）。验证在修改 `_common.sh` 时
  reverse 模式生成的 managed-alias 输出保持不变。
- Forward 回环端到端测试：向 `localhost` 添加一个 ssh 别名，运行 `local-setup.sh --via … --remote-path … --mountpoint /tmp/… --launch claude`；确认挂载、规则注入及退出时的卸载均正常。
- 完整的双主机端到端测试（从远程主机 reverse / forward 到服务器，包括 macOS FUSE-T）为手动测试。
- 仅在被要求时提交。本仓库发布到 GitHub（`origin/main`）。
- **提交身份（必须）。** 每个提交都必须使用 **GitHub noreply** 邮箱——GitHub 会拒绝任何会暴露真实邮箱的推送（错误 `GH007`）。在没有配置 git 身份的 clone 上（例如远程开发盒子），请**逐次提交**临时设置，不写入 `.git/config` 或 `--global`：
  `git -c user.name=chenjh16 -c user.email=chenjh16@users.noreply.github.com commit …`
- **推送。** 只在持有 GitHub 推送凭据的机器上 push。要把在无推送权限的开发盒子上做的工作发出去：在盒子上用上面的逐次身份提交，然后在推送机器上 `git fetch` 那个盒子的 clone（先加为 remote）并 `git push origin main`。盒子作为活跃源期间，推送机器只中转、不要也独立提交，避免分叉。
