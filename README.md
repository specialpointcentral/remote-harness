<h1 align="center">remote-harness</h1>

<p align="center">
  <b>Agent 只在远端服务器运行；本机只提供项目文件和命令执行环境。</b><br>
  <i>Agents run only on the remote server; the local machine provides project files and command execution.</i>
</p>

<p align="center">
  <img alt="platforms" src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL-blue">
  <img alt="agents" src="https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20opencode-8A2BE2">
  <img alt="topology" src="https://img.shields.io/badge/topology-remote--only-success">
  <img alt="transport" src="https://img.shields.io/badge/transport-SSH%20%2B%20sshfs-orange">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-FUSE--T%20(no%20kext)-brightgreen">
  <img alt="shell" src="https://img.shields.io/badge/built%20with-Bash-1f425f">
  <img alt="deps" src="https://img.shields.io/badge/runtime%20deps-ssh%20%2B%20sshfs%20%2B%20python3-lightgrey">
</p>

<p align="center"><b>中文</b> · <a href="#english">English</a></p>

---

> **服务器 SSH/SSHFS 长连接提醒 / Server tuning note：** 如果一台远程开发服务器承载多用户、
> 多个长期 Agent 会话或大量 SSHFS 挂载，建议先优化 `sshd` 容量、keepalive、文件描述符和 TCP 队列。
> 参考 [`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)
> / [`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md)。
> remote-harness 自身会使用会话级 SSH config、`sshfs reconnect` 和 keepalive，但服务器端容量仍会影响长期稳定性。

## 中文

### 目录

- [这是什么](#这是什么)
- [安装 Skill](#安装-skill)
- [Quick start](#quick-start)
- [工作原理（remote-only）](#工作原理remote-only)
- [服务器 SSH/SSHFS 长连接优化提醒](#服务器-sshsshfs-长连接优化提醒)
- [环境要求](#环境要求)
- [仓库结构](#仓库结构)
- [安全与隐私](#安全与隐私)
- [故障排查](#故障排查)

### 这是什么

你的**编码 Agent**（Claude Code / Codex / opencode）全部运行在远端服务器，代码库和真实命令环境
保留在本机。`remote-harness` 用 sshfs 把代码挂到远端空目录，并通过 forced-command gateway 将
**编译/测试导向本机**，然后只在远端挂载目录里启动 Agent。Claude Code/opencode 通过
`/remote-harness` 触发；Codex 用 `$remote-harness` 直接调用技能。默认 simple reverse 模式下，Agent
只给你一条命令；具体 SSH、路径、命名空间和挂载点都在你的本地终端里输入，不进入 Agent 聊天。

本 fork 对 Claude Code、Codex 和 opencode 都启用严格命令路由：Claude/Codex 使用会话级
`PreToolUse` hook，opencode 使用会话级 `tool.execute.before` 插件。它们会把每个 Bash 调用自动改写到
代码所在主机执行，并把 SSHFS 挂载下的当前目录映射到项目主机对应子目录。hook/plugin、runner 或 SSH
config 创建失败时，启动器会拒绝启动 Agent，不会退回到 Agent 主机执行。
opencode 还必须在预加载时写出会话 plugin readiness marker，否则交互式 Agent 不会启动。

记号：**A** = 运行 Agent 的机器；**P** = 存放代码的机器（用一个 ssh `<别名>` 指代）。

### 安装 Skill

维护仓库：[`https://github.com/specialpointcentral/remote-harness`](https://github.com/specialpointcentral/remote-harness)
（基于 [`chenjh16/remote-harness`](https://github.com/chenjh16/remote-harness)）。

把 remote-harness 安装到**远端 Agent 服务器**。本机只运行 bootstrap、SSHFS 对端和项目命令 gateway。

**方式一：手动命令安装**

```bash
git clone https://github.com/specialpointcentral/remote-harness.git
cd remote-harness
./manage.sh            # 复制安装到 ~/.remote-harness + 各 Agent 的入口
./manage.sh --dev      # 开发模式：软链到本仓库，改动即时生效
./manage.sh --uninstall [claude|codex|opencode]   # 卸载（不动你的 ssh 配置/挂载）
```

**方式二：一句 Prompt 让 Agent 自动安装**

在目标机器上的 Codex / Claude Code / opencode 里粘贴：

```text
请在当前机器上安装 remote-harness skill。GitHub 仓库是 https://github.com/specialpointcentral/remote-harness，请克隆或更新这个仓库，运行 ./manage.sh 安装到当前用户的 Claude Code / Codex / opencode 入口；不要修改 ~/.ssh；完成后告诉我可用的调用方式。
```

| Agent | 入口位置 | 调用 |
|---|---|---|
| 共享核心 | `~/.remote-harness/{SKILL.md, SKILL.cn.md, scripts/, reference/, docs/}` | （各方共用） |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md` | `/remote-harness` |
| Codex | `~/.codex/skills/remote-harness/SKILL.md` | `$remote-harness` |
| opencode | `~/.config/opencode/command/remote-harness.md` | `/remote-harness` |

**脚本**是唯一的单一事实来源——各 Agent 都调用 `~/.remote-harness/scripts/*`。每个 Agent 的入口
形态不同：Claude Code 与 Codex 都是原生 *skill*（共用同一份 `SKILL.md`；Codex 无自定义斜杠命令，推荐用
`$remote-harness` 直接调用技能），opencode 是让 Agent 去读共享 `SKILL.md` 的自定义命令。

### Quick start

先确认本机能用已有 SSH 身份登录远端 Agent 服务器；远端还需要 `sshfs`。

**远程开发本地项目（默认 reverse）**

在远端盒子里的 Agent 输入：

```text
$remote-harness 中文，远程开发本地，yolo
```

Claude Code / opencode 使用 `/remote-harness 中文，远程开发本地，yolo`。Agent 会返回一段在**本地终端**运行的命令。

**Claude 多 Agent 支持**

| Claude 模式 | 状态 | 说明 |
|---|---|---|
| 普通 / 具名 subagent | 支持 | settings hook 会在 subagent 内继续触发；具名 agents 可互发消息 |
| 嵌套 subagent | 支持 | 每一层 Bash 继续经过同一 hook，深度和并发仍受 Claude 自身限制 |
| Agent Teams | 默认禁用 | teammate 是独立 Claude 会话，临时 `--settings` hook 继承没有明确保证 |
| `isolation: worktree` / `EnterWorktree` | 阻止 | Agent 主机 worktree 路径与项目主机路径映射不兼容 |
| 多个独立 harness 会话 | 推荐 | 每个本机 Git worktree 启动一个 harness 会话，再用 cross-session messaging 协调 |

详细边界和推荐拓扑见 [`docs/claude-multi-agent.cn.md`](docs/claude-multi-agent.cn.md)。

**本机 Agent / forward 模式**

本 fork 已永久禁用。`--mode forward`、`simple-local-setup.sh` 和 `local-setup.sh` 都会在挂载或启动前
返回 remote-only 错误。

随后按这个流程走：

1. 让 Agent 直接返回一条本地 bootstrap 命令。公开入口统一是 `simple-bootstrap.sh`；
   如果脚本在远端 skill 目录，命令会先从远端读取它再在本地运行。
2. 你在本地终端运行该命令，并按提示输入 SSH target、项目目录和可选挂载点。
3. bootstrap 建立 reverse 隧道，通过 forced gateway 完成 SSHFS 和命令通道。
4. 仅在远端挂载目录启动 Agent；会话 hook/plugin 自动把 Bash 路由到本机项目环境。
5. 退出 Agent 时**自动卸载**。随时再次启动 remote-harness 重新连接（幂等；陈旧挂载会被检测并重挂）。

明确或模糊请求都使用 reverse；不会再显示模式选择。任何本机 Agent 请求都会被拒绝。

### 工作原理（remote-only）

唯一模式是 simple reverse：Agent 在远端服务器，代码和项目命令环境在本机。

**① 反向（reverse）— Agent 在远程盒子，代码在你的笔记本（NAT 后）**

盒子无法主动连笔记本，所以笔记本开一条**反向 SSH 隧道**，再把笔记本项目挂到盒子上。

```
笔记本会话级 ssh_config：  Host <会话别名>   RemoteForward <端口> 127.0.0.1:22
        └─ 连接后，盒子的 sshd 在 127.0.0.1:<端口> 监听，转发回笔记本:22

盒子：  ssh <别名>          → 127.0.0.1:<端口> → （隧道） → 笔记本:22
        sshfs <别名>:/项目  → 同一条隧道       → 笔记本文件挂载到这里
```

simple reverse 使用 `~/.remote-harness/.sessions/...` 下的会话级 SSH 配置和 `known_hosts`，并关闭
OpenSSH multiplexing。唯一的 `~/.ssh` 写入例外是在笔记本
`~/.ssh/authorized_keys` 中追加带标签的临时授权块，并在退出时清理。

远端 key 在本机 `authorized_keys` 中绑定 forced command，只允许标准 SFTP、health 和
`remote-harness-exec`。任意本机 SSH shell 命令会被 gateway 拒绝。

### 服务器 SSH/SSHFS 长连接优化提醒

remote-harness 的单次会话会自动做这些事：使用会话级 SSH config；把临时 `known_hosts` 放在
`~/.remote-harness/.sessions/...`；关闭 OpenSSH multiplexing；给 `sshfs` 加 `reconnect` 和 keepalive；
并在退出时尽量清理挂载、规则和临时配置。

但如果远程服务器是多人共享开发盒子，服务器端仍需要足够的 SSH 容量。建议运维侧评估：

- `MaxStartups` / `MaxSessions`，避免突发 SSHFS 挂载时握手阶段被拒。
- `ClientAliveInterval` / `ClientAliveCountMax` / `TCPKeepAlive`，让长期连接更稳并回收半死会话。
- `ssh.service` 与 PAM 的 `nofile`，避免多用户 SFTP/SSHFS 先撞到文件描述符上限。
- `somaxconn`、`tcp_max_syn_backlog` 和 TCP keepalive sysctl，应对连接突发和长期 idle 连接。

完整配置模板、验证命令和回滚方法见
[`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)。

### 环境要求

- 你已经能从一台机器 ssh 到另一台（任意端口 / 常见 `-J` 跳板机都行）。复杂 SSH 选项
  （`ProxyCommand`、`-F`、带空格的引号路径、本地转发等）请先写进 `~/.ssh/config` 的 `Host` 别名，再把别名交给 remote-harness。
  会话隧道别名会继承该别名经 `ssh -G` 解析出的 HostName、Port、User、IdentityFile、IdentitiesOnly、
  ProxyJump 和 ProxyCommand（例如 `gcloud compute start-iap-tunnel` 这类 Google Cloud IAP 连接）。
- **反向 simple**：你已经把笔记本的 SSH 公钥配置到远端服务器账号，所以本地命令能先登录远端抓取脚本。
  远端会在本次会话 SSH config 旁生成新的 remote-harness key；本地脚本可将其公钥作为
  `remote-harness:reverse-auth:<tag>` 临时块写入笔记本 `~/.ssh/authorized_keys`，限制为回环来源并在退出时清理。
  盒子的 sshd 需要允许 TCP 转发（默认即可）。
- **远端 Agent 服务器需要 `sshfs` + FUSE**：
  - Linux/WSL：`sudo apt-get install -y sshfs`（FUSE 通常已就绪；脚本会按发行版给正确命令）。
  - **macOS：用 FUSE-T——无内核扩展、无需降低系统安全级**：
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`。
    **不要用 macFUSE**（它要求降低安全策略）。FUSE-T 保留 sshfs 的同步写，编辑会先落到代码所在机器
    再触发远端构建。（无内核扩展的兜底：`rclone nfsmount`——但写是异步的，故本场景优先 FUSE-T。）
- Claude/Codex 严格路由要求远端 Agent 主机有 `python3`；opencode 要求支持
  `tool.execute.before` 的当前插件接口。项目主机只需 POSIX `sh`、base64 解码器和正常登录 shell。
- 多用户共享远程开发服务器建议按
  [`docs/ssh-sshfs-long-lived-connections.cn.md`](docs/ssh-sshfs-long-lived-connections.cn.md)
  调整 sshd 容量、keepalive、`nofile` 和 TCP 队列。该优化不是 remote-harness 的硬性前置条件，
  但会显著提升大量长期 SSH/SSHFS 会话的稳定性。

### 仓库结构

```
remote-harness/
├── SKILL.md                  # remote-only reverse 入口：只输出本地 bootstrap 命令
├── reference/
│   ├── reverse.md            # 反向完整流程（建隧道 → 发命令）
│   ├── forward.md            # 已禁用本机 Agent 模式的兼容说明
│   └── scripts.md            # 各脚本的 KEY=VALUE 契约
├── scripts/                  # 确定性逻辑（KEY=VALUE 输出），Agent 无关
│   ├── _common.sh            # 共享库（颜色/ask/sq/parse_via/写托管别名/OS 变量）
│   ├── simple-bootstrap.sh   # simple 统一入口（本地运行；可从远端读取）
│   ├── simple-dispatch.sh    # remote-only reverse dispatcher
│   ├── simple-laptop-setup.sh # reverse 本地向导
│   ├── simple-local-setup.sh local-setup.sh # 永久拒绝本机 Agent 的兼容 stub
│   ├── suggest-via.sh        # simple 反向：远端 SSH target 默认值
│   ├── setup-tunnel.sh check-tunnel.sh   # 反向隧道的会话级别名 / 检查
│   ├── mount-project.sh inject-rule.sh   # 两向复用的挂载与规则/hook 注入
│   ├── route-command.py                  # PreToolUse JSON 改写与 cwd 映射
│   ├── run-on-project-host.sh            # SSH 命令传输与项目主机 dispatcher
│   ├── project-host-gateway.sh            # forced-command SSH gateway
│   ├── laptop-setup.sh       # 反向编排（在笔记本上跑）
│   └── local-setup.sh        # 永久拒绝本机 Agent 的兼容 stub
├── adapters/{codex,opencode}.md   # 各 Agent 的入口（只设置 --launch）
├── manage.sh                 # 安装 / --dev / --uninstall
├── docs/                     # 设计与完整流程文档（安装时一并复制/软链）
│   └── ssh-sshfs-long-lived-connections*.md  # 共享服务器 SSH/SSHFS 长连接优化
├── issues/issue1.md          # 共享账号命名空间隔离分析（+ .cn.md）
├── AGENTS.md（+ CLAUDE.md 软链）   # 给「开发本仓库」的 Agent 的指南
└── README.md
```

> **设计文档**：想了解整体架构、四层结构与设计决策，见 [`docs/design.md`](docs/design.md)（中文版
> [`docs/design.cn.md`](docs/design.cn.md)）。
>
> **文档约定**：除 `README.md`（本文，内联双语）外，所有 `*.md` 都配一份中文 `*.cn.md`。详见 `AGENTS.md`。

### 安全与隐私

- simple setup 不在本地或远端 `~/.ssh/config`、用户管理的 SSH key、`config.rh-bak.*` 或
  `known_hosts_<alias>` 下创建、修改、备份、追加或清理内容。所有临时 SSH alias 和 `known_hosts`
  都位于 `~/.remote-harness/.sessions/...`，并在会话结束时尽量清理；会话 config 关闭 OpenSSH multiplexing。
- 反向模式的唯一 `~/.ssh` 写入例外是本机 `authorized_keys`：脚本会先检查是否已有匹配有效 key；
  没有时才追加带 `remote-harness:reverse-auth:<tag>` 标签、`from="127.0.0.1,::1"` 限制的临时块。
  托管块通过 `~/.remote-harness/.sessions/authorized-keys/...` 引用计数，最后一个会话退出时删除。
- 每次会话使用独立远端 key；授权行绑定 `command="...project-host-gateway..."`。同一 key 若已存在为
  无限制用户授权，setup 会拒绝复用。
- 反向隧道用 `RemoteForward <端口> 127.0.0.1:22`（仅回环）；多用户盒子上同机其他用户能到达该端口，
  但没有你的私钥无法认证。
- 多人共用同一个服务器账号时，simple reverse 默认使用会话别名 `rlocal`，别名和 known_hosts 都放在
  远端会话目录中；不会覆盖共享账号的 `~/.ssh/config`。同一台笔记本的多项目会话仍可复用活动隧道，
  最后一个会话退出时清理。
- `--yolo` 会绕过审批，**仅在你明确要求时**才启用；opencode 的 `permission:allow` 只写进**本次会话**
  的配置，退出即清。
- Claude/Codex hook、opencode plugin、runner 和规则都是**会话级**的（不写全局文件、不碰挂载的仓库）；
  退出删除会话目录。路由器加载后，handler 错误会返回拒绝，SSH 失败也不会回退执行原命令。
- 严格命令路由限制的是正常 Agent Bash 调用，不会把 SSHFS 变成安全沙箱。反向会话中的远端主机持有
  一把能访问本机 SSH/SFTP 的临时密钥；请只在你信任的 Agent 主机上使用，不要把敏感目录作为项目挂载。
- forced gateway 的 SFTP 是账号级文件访问，不是项目 chroot。绝对项目边界需要独立、受限的本机 OS 账号。
- Claude 严格模式会设置 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0`，并阻止 `WorktreeCreate`、
  `EnterWorktree` 和 `ExitWorktree`。普通/嵌套 subagent 仍可使用；并行写入时应给 agents 分配互不
  重叠的文件范围。

### 故障排查

详见 `reference/reverse.md`；已禁用入口见 `reference/forward.md`。常见：
- macOS 提示要 macFUSE → 改用 FUSE-T（见[环境要求](#环境要求)）。
- 会话中文件突然读不了（`Transport endpoint is not connected`）→ 隧道断了，退出 Agent 后再次启动
  remote-harness，会自动检测陈旧挂载并重挂。
- 挂载报 `not-empty` → 换一个空目录（脚本会提示）。

---

## English

### Table of Contents

- [What it is](#what-it-is)
- [Install the Skill](#install-the-skill)
- [Quick start](#quick-start-1)
- [How it works (remote-only)](#how-it-works-remote-only)
- [Server SSH/SSHFS Long-Lived Connection Tuning](#server-sshsshfs-long-lived-connection-tuning)
- [Requirements](#requirements)
- [Repo layout](#repo-layout)
- [Security & privacy](#security--privacy)
- [Troubleshooting](#troubleshooting)

### What it is

Your coding agents run only on the remote server while the repository and real command environment
remain on the local project host. `remote-harness` SSHFS-mounts the local code on the server,
routes builds/tests through a forced-command gateway, and launches the
agent in the mount. Claude Code/opencode trigger it with `/remote-harness`; Codex users invoke the
skill with `$remote-harness`. In the default simple reverse mode, the agent returns one command;
concrete SSH targets, paths, namespaces, and mountpoints are entered in the user's local terminal,
not in chat. Generically: **A** = the machine the agent runs on; **P** = the
machine the code lives on (an ssh `<alias>`).

This fork adds strict routing for Claude Code, Codex, and opencode. Claude/Codex use a session
`PreToolUse` hook; opencode uses a session `tool.execute.before` plugin. Each rewrites Bash calls to
the project host and maps the SSHFS-relative cwd to the corresponding project-host directory.
Hook/plugin, runner, or SSH-config failures abort launch instead of falling back to the agent host.
opencode must also produce a session-plugin readiness marker during preloading before its interactive
Agent is allowed to start.

### Install the Skill

Maintained repository: [`https://github.com/specialpointcentral/remote-harness`](https://github.com/specialpointcentral/remote-harness)
(based on [`chenjh16/remote-harness`](https://github.com/chenjh16/remote-harness)).

Install remote-harness on the remote agent server. The local machine runs only the bootstrap,
SSHFS endpoint, and project-host command gateway.

**Option 1: manual command install**

```bash
git clone https://github.com/specialpointcentral/remote-harness.git
cd remote-harness
./manage.sh            # copy-install to ~/.remote-harness + each agent's entry point
./manage.sh --dev      # dev mode: symlink to this repo (edits go live)
./manage.sh --uninstall [claude|codex|opencode]   # uninstall (leaves your ssh config/mounts alone)
```

**Option 2: one-prompt agent install**

Paste this into Codex / Claude Code / opencode on the target machine:

```text
Install the remote-harness skill on this machine. GitHub repository: https://github.com/specialpointcentral/remote-harness; clone or update that repository, run ./manage.sh to install it for the current user's Claude Code / Codex / opencode entries, do not modify ~/.ssh, and tell me the available invocation commands when done.
```

| Agent | Location | Invoke |
|---|---|---|
| shared core | `~/.remote-harness/{SKILL.md, SKILL.cn.md, scripts/, reference/, docs/}` | (used by all) |
| Claude Code | `~/.claude/skills/remote-harness/SKILL.md` | `/remote-harness` |
| Codex | `~/.codex/skills/remote-harness/SKILL.md` | `$remote-harness` |
| opencode | `~/.config/opencode/command/remote-harness.md` | `/remote-harness` |

The **scripts** are the single source of truth — every agent calls `~/.remote-harness/scripts/*`.
Each agent's entry differs by what it supports: Claude Code and Codex both use a native *skill* (the
shared `SKILL.md`; Codex has no custom slash commands, so use `$remote-harness`); opencode is a
custom command that reads the shared `SKILL.md`.

### Quick start

First make sure the local project host can SSH into the remote Agent server with an existing SSH
identity. The remote server also needs `sshfs`.

**Remote agent, local project (default reverse)**

In the agent running on the remote box:

```text
$remote-harness English, remote dev local project, yolo
```

Claude Code / opencode use `/remote-harness English, remote dev local project, yolo`. The agent
returns a command to run in your **local terminal**.

**Claude multi-agent support**

| Claude mode | Status | Behavior |
|---|---|---|
| Ordinary / named subagents | Supported | Settings hooks also run in subagents; named agents can message peers |
| Nested subagents | Supported | Every layer's Bash calls use the same hook, subject to Claude's own limits |
| Agent Teams | Disabled by default | Teammates are independent sessions without a documented temporary-settings guarantee |
| `isolation: worktree` / `EnterWorktree` | Blocked | Agent-host worktree paths are incompatible with project-host path mapping |
| Multiple harness sessions | Recommended for isolation | Mount one local Git worktree per session and coordinate with cross-session messaging |

See [`docs/claude-multi-agent.md`](docs/claude-multi-agent.md) for the full boundary and topology.

**Local-agent forward mode** is permanently disabled. All compatibility entries return a
remote-only error before mounting or launching anything.

Then:

1. The agent returns one local bootstrap command. The public entry is always
   `simple-bootstrap.sh`; if the script lives in a remote skill directory, the command fetches it
   from there and then runs it locally.
2. You run that command in your local terminal and enter the SSH target, project directory, and
   optional mountpoint.
3. The bootstrap opens the reverse tunnel and exposes only the forced SFTP/health/exec gateway.
4. It launches the chosen agent only on the remote server; Bash is routed to the local project host.
5. **Auto-unmounts on exit.** Start remote-harness again anytime to reconnect; stale mounts are
   detected and replaced.

Clear and ambiguous requests both use reverse. Any local-agent request is refused.

### How it works (remote-only)

The only supported topology is a remote agent server with a local project host.

**① Reverse — agent on a remote box, code on your laptop (behind NAT).** The box can't dial the
laptop, so the laptop opens a **reverse SSH tunnel** and its project is sshfs-mounted onto the box.

```
laptop session ssh_config:  Host <session-alias>   RemoteForward <PORT> 127.0.0.1:22
        └─ on connect, the box's sshd listens on 127.0.0.1:<PORT> and forwards back to laptop:22
box:   ssh <alias>          → 127.0.0.1:<PORT> → (tunnel) → laptop:22
       sshfs <alias>:/proj  → same tunnel       → laptop files mounted here
```

Simple reverse uses session-local SSH config files and `known_hosts` under
`~/.remote-harness/.sessions/...`, with OpenSSH multiplexing disabled. The only `~/.ssh` write
exception is that the laptop may get a tagged temporary `authorized_keys` block that is
removed on exit.

The per-session reverse key is bound to a forced SSH command. Only standard SFTP, health checks, and
`remote-harness-exec` are accepted; arbitrary local SSH shell commands are rejected.

### Server SSH/SSHFS Long-Lived Connection Tuning

Each remote-harness session already uses session-local SSH config, keeps temporary `known_hosts`
under `~/.remote-harness/.sessions/...`, disables OpenSSH multiplexing, passes `reconnect` and
keepalive options to `sshfs`, and cleans up mounts/rules/temp configs on exit where possible.

For shared remote development servers, server-side capacity still matters. Operators should review:

- `MaxStartups` / `MaxSessions`, so bursty SSHFS mounts are not rejected during authentication.
- `ClientAliveInterval` / `ClientAliveCountMax` / `TCPKeepAlive`, so long sessions survive short
  network blips and dead sessions are reclaimed.
- `ssh.service` and PAM `nofile`, so SFTP/SSHFS workloads do not hit low file descriptor limits.
- `somaxconn`, `tcp_max_syn_backlog`, and TCP keepalive sysctls for connection bursts and idle flows.

See the full template, verification commands, and rollback notes in
[`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md).

### Requirements

- You can already ssh from one machine to the other (any port / common `-J` jump host is fine).
  For complex SSH options (`ProxyCommand`, `-F`, quoted paths with spaces, local forwards, etc.),
  put them in `~/.ssh/config` as a `Host` alias and give remote-harness that alias.
  The session tunnel alias inherits the alias's `ssh -G` HostName, Port, User, IdentityFile,
  IdentitiesOnly, ProxyJump, and ProxyCommand (for example a Google Cloud IAP
  `gcloud compute start-iap-tunnel` connection).
- **Simple reverse**: the laptop's SSH public key is already accepted by the remote server account,
  so the local command can fetch scripts from the remote box. The box generates a new
  remote-harness key beside the session SSH config; the local setup may add that public key
  to the laptop's `~/.ssh/authorized_keys` as a tagged, loopback-scoped temporary block and remove it
  on exit. The box's sshd must allow TCP forwarding (the default).
- **The remote agent server needs `sshfs` + FUSE**:
  - Linux/WSL: `sudo apt-get install -y sshfs` (FUSE usually present; the script gives the right
    per-distro command).
  - **macOS: use FUSE-T — no kernel extension, no reduced system security**:
    `brew install macos-fuse-t/homebrew-cask/fuse-t && brew install macos-fuse-t/homebrew-cask/sshfs-fuse-t`.
    Avoid macFUSE (it requires lowering security). FUSE-T keeps sshfs's synchronous writes, so edits
    land on the host before remote builds. (Kext-less fallback: `rclone nfsmount`, but its writes are
    async — prefer FUSE-T for this edit-here/build-on-host workflow.)
- Strict Claude/Codex routing requires `python3` on the remote Agent host. opencode requires a
  current plugin interface with `tool.execute.before`. The project host needs POSIX `sh`, a base64
  decoder, and its normal login shell.
- Shared remote development servers should use
  [`docs/ssh-sshfs-long-lived-connections.md`](docs/ssh-sshfs-long-lived-connections.md) to tune sshd
  capacity, keepalive, `nofile`, and TCP queues. This is not a hard prerequisite for remote-harness,
  but it materially improves stability with many long-lived SSH/SSHFS sessions.

### Repo layout

```
remote-harness/
├── SKILL.md                  # remote-only reverse entry: emits one local bootstrap command
├── reference/{reverse,forward,scripts}.md   # active reverse flow, disabled-mode note, script contracts
├── scripts/                  # deterministic helpers (KEY=VALUE stdout), agent-agnostic
│   ├── _common.sh            # shared lib (colors/ask/sq/parse_via/managed-alias/OS vars)
│   ├── simple-bootstrap.sh                   # unified simple entry (local run; remote-fetchable)
│   ├── simple-dispatch.sh                    # remote-only reverse dispatcher
│   ├── simple-laptop-setup.sh                # reverse local wizard
│   ├── simple-local-setup.sh local-setup.sh  # local-agent rejection stubs
│   ├── suggest-via.sh                        # simple reverse remote SSH target default
│   ├── setup-tunnel.sh check-tunnel.sh        # reverse session alias + tunnel check
│   ├── mount-project.sh inject-rule.sh        # shared mount + session rule/hook helpers
│   ├── route-command.py                       # PreToolUse rewrite + cwd mapping
│   ├── run-on-project-host.sh                 # SSH transport + project-host dispatcher
│   ├── project-host-gateway.sh                 # forced-command SSH gateway
│   ├── laptop-setup.sh                        # reverse orchestrator
│   └── local-setup.sh                         # permanent local-agent rejection stub
├── adapters/{codex,opencode}.md
├── manage.sh
├── docs/                            # design and complete-flow docs (installed with the skill)
│   └── ssh-sshfs-long-lived-connections*.md  # shared-server SSH/SSHFS tuning
├── issues/issue1.md                 # shared-account namespacing analysis (+ .cn.md)
├── AGENTS.md (+ CLAUDE.md symlink)   # guide for agents developing this repo
└── README.md
```

> **Design doc:** for the overall architecture, the four-layer structure, and the design decisions,
> see [`docs/design.md`](docs/design.md) (Chinese: [`docs/design.cn.md`](docs/design.cn.md)).
>
> **Docs convention:** every `*.md` except `README.md` (this file, inline-bilingual) ships a Chinese
> `*.cn.md` counterpart. See `AGENTS.md`.

### Security & privacy

- Simple setup does not create, modify, back up, append to, or clean up local or remote
  `~/.ssh/config`, user-managed SSH keys, `config.rh-bak.*`, or `known_hosts_<alias>`. Temporary
  SSH aliases and `known_hosts` live under `~/.remote-harness/.sessions/...` and are cleaned up at
  session end where possible; session configs disable OpenSSH multiplexing.
- The only `~/.ssh` write exception is reverse-mode laptop `authorized_keys`: setup checks for an
  existing active matching key first, otherwise appends a tagged
  `remote-harness:reverse-auth:<tag>` block restricted with `from="127.0.0.1,::1"`. Managed blocks
  are reference-counted under `~/.remote-harness/.sessions/authorized-keys/...` and removed when the
  last session exits.
- Every session uses a separate remote key bound to `project-host-gateway`. Setup refuses a matching
  unrestricted user authorization for that key.
- The reverse tunnel binds loopback only (`RemoteForward <PORT> 127.0.0.1:22`); on a multi-user box
  other local users can reach that port but cannot authenticate without your private key.
- When several people share one server account, simple reverse uses the session alias `rlocal` and
  keeps alias/known_hosts state in the remote session directory, so one run does not overwrite the
  shared account's `~/.ssh/config`. Multiple projects from the same laptop can reuse a live tunnel;
  the last session out cleans it up.
- `--yolo` bypasses approvals and is applied **only when you ask**; opencode's `permission:allow`
  goes into the **per-session** config only and is gone on exit.
- Claude/Codex hooks, the opencode plugin, runners, and instructions are **session-scoped**. Once
  routing is loaded, handler errors deny the call and SSH failures do not fall back to the original
  command.
- Strict command routing is not a filesystem sandbox. In reverse mode the trusted agent host holds
  a temporary key capable of laptop SSH/SFTP access. Do not use an untrusted agent host or mount a
  directory containing unrelated secrets.
- Gateway SFTP is account-level access, not a project chroot. An absolute project boundary requires
  a dedicated, restricted local OS account.
- Claude strict mode sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0` and blocks `WorktreeCreate`,
  `EnterWorktree`, and `ExitWorktree`. Ordinary and nested subagents remain available; parallel
  writers need disjoint file ownership.

### Troubleshooting

See `reference/reverse.md`; disabled compatibility entries are documented in `reference/forward.md`.
Common issues:
- macOS asks for macFUSE → use FUSE-T instead (see [Requirements](#requirements)).
- Files become unreadable mid-session (`Transport endpoint is not connected`) → the tunnel dropped;
  exit the agent and start remote-harness again (it detects the stale mount and remounts).
- Mount reports `not-empty` → pick a different empty dir (the script prompts).
