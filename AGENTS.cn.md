> 中文版。英文原版见 [AGENTS.md](AGENTS.md)（以英文版为准）。

# AGENTS.md - remote-harness 维护指南

本仓库是 remote-only remote-harness skill。Claude、Codex、opencode、subagent 和独立 Agent
会话全部运行在远端服务器。本机只作为项目主机：通过 SSHFS 提供文件，并通过 forced gateway
执行项目命令。

## 仓库结构

- `SKILL.md`：reverse-only skill 入口。
- `scripts/simple-bootstrap.sh`：公开本地 bootstrap，可从远端 fetch helper。
- `scripts/simple-dispatch.sh`：只接受 reverse，拒绝 forward。
- `scripts/simple-laptop-setup.sh` / `laptop-setup.sh`：本地 reverse 编排。
- `scripts/simple-local-setup.sh` / `local-setup.sh`：永久拒绝本机 Agent 的兼容 stub。
- `scripts/project-host-gateway.sh`：只接受 SFTP、health、exec，以及白名单 `git`/`rg` 工具动词的
  forced SSH command。
- `scripts/route-command.py`：Claude/Codex hook 策略和 cwd 映射。
- `scripts/inject-rule.sh`：同时生成会话级 opencode `tool.execute.before` plugin。
- `scripts/run-on-project-host.sh`：校验后的本机项目命令和工具 dispatcher。
- `scripts/project-host-tool.py`：远端会话的 `git`/`rg` PATH 垫片，负责工作区扫描。
- `scripts/session-reaper.sh`：本地清理没有执行时，负责远端会话的 watcher 和 GC。
- `scripts/channel-guard.py`：在路由 Bash 命令存续期间持有其 SSH 通道。
- `scripts/warm_pool.py`：每会话一个、在 gateway 的 wait 动词上预先打开通道的通道池（`serve`），以及
  channel-guard 和工具垫片使用的客户端部分。
- `reference/`、`docs/`：英文 Markdown 必须有 `.cn.md` 对应版本。

## Simple Reverse 规则

- 所有公开命令都使用 `simple-bootstrap.sh --mode reverse`。
- 不得新增本机 Agent 或 forward 启动路径；兼容脚本必须在挂载、连接或启动前失败。
- 命令在本机运行，但 script may live remotely；fetch 形式必须紧凑但可复制，并取得全部 reverse helper。
- 具体 SSH target、本机路径、挂载点和审批只在本机终端收集。
- 若从 `SSH_CONNECTION` 推导默认值，第 1/2 字段是本地客户端数据，绝不能输出；只可使用第 3/4 字段。
- 用户明确指定审批模式（`--approval auto|normal|yolo` 或 `--yolo`）后，不得再二次询问确认。未指定时
  向导会询问，默认沿用上次的选择，否则为 auto；auto 使用远端 CLI 的自动审核（`claude --permission-mode
  auto`、`codex --approve-for-me`），CLI 不支持时退回普通审批。
- `laptop-setup.sh` 必须可与下载到同目录的 sibling helper 独立运行。
- 主 Agent 只能通过 `ssh -tt <远端> ... <claude|codex|opencode>` 在远端启动。
- Claude/Codex/opencode Bash 导向本机；Agent/Spawn 工具仍在远端执行。
- Claude 的 hook 对路由调用绝不返回审批决定：`allow` 会跳过 Claude 的审批提示和 auto 模式自动审核。它改写成
  可读的 `rh-run --cwd <目录> -- <命令>`，由用户选择的审批模式判断原始命令。Codex 的 hook 和 opencode
  插件写同样的格式；Codex 只接受与 `allow` 一起返回的 `updatedInput`，这不会跳过它自己的审批。
- Claude 只能看到 rh-run，所以它的 hook 用原始命令对照用户自己的规则：`Bash(...)` deny/ask 对共享词法器
  找到的任意一条简单命令生效，allow 只在 default/acceptEdits/dontAsk 模式（绝不包括 auto）下对单条普通命令
  生效。规则文件只在标识变化时重读。Codex 和 opencode 自己检查原命令：改写后在 `exit` 之后另起一行附上
  原命令，shell 不会解析这一行，Codex 的执行策略（`.rules` 规则、带 `-f` 的 `rm`）和 opencode 的 bash 规则
  都会读它；opencode 插件还把工作目录设为原命令自己的目录。
- Claude 会话禁止 Read/Edit 访问 `$RH_HOME/.sessions`，禁止 Read 访问 `/proc`。`rh-session` 清除
  `SSH_CONNECTION`/`SSH_CLIENT` 中笔记本的地址和端口。Linux 上的 sshfs 挂载使用 `fsname=remote-harness`，
  挂载来源保存在挂载记录里；`mounts` 目录仅本人可访问。垫片的 stderr 把项目根路径映射回挂载点。

## Gateway 安全

- 每个远端会话目录生成独立 reverse key。
- 本机授权包含 `command="...project-host-gateway..."`、回环来源限制、no PTY、no port/X11/agent forwarding。
- 同一会话 key 若已出现在无限制用户授权行中，必须拒绝。
- `RH_LOCAL_SSHD=user`（`--local-sshd user`）用以用户身份运行的会话级 sshd 替代系统 sshd：仅回环、
  探测空闲端口并在绑定失败时重试、同样的 forced-gateway 授权行放在会话私有 `authorized_keys`、
  `AuthorizedKeysCommand none`、只允许公钥、不走 PAM、无转发和 TTY。用于 sshd 不读取
  `~/.ssh/authorized_keys` 的 FreeIPA/sssd 类主机，随隧道的资源记录一起停止。
- gateway 只接受标准 SFTP、`remote-harness-health`、
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`、
  `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`，以及 `remote-harness-wait`；工具动词
  直接 exec 二进制（不经 shell、固定 PATH）。watch 模式的 exec 和工具动词让命令的 stdin 来自
  `/dev/null`，并在 SSH 通道关闭时终止命令的进程组和进程树。
- `remote-harness-wait`（Agent 主机的预热通道池 `warm_pool.py`）先输出 `RH_WAIT_READY`，只读取一行
  完整请求，这一行本身必须是 exec 或 tool 请求；在执行任何东西之前先以 `RH_WAIT_GOT` 确认，然后走同样
  的校验和 dispatcher。它绝不接受 health、SFTP 或嵌套的 wait。客户端只在请求确定没有送达（完整的一行
  没能写进去）时才改走普通路径。完整写出却没有收到确认的请求属于送达不确定：Bash 以 255 失败，绝不重试；
  只有只读的 git/rg 调用可以再执行一次。
- 传输容量设置（`RH_WARM_*`、`RH_SSHD_MAX_SESSIONS`、Bash/工具的并发配额和排队时间）只接受白名单内的
  数字，来自环境变量或 `~/.remote-harness/transport.conf`；该文件只解析、绝不 source。启动器以 `env`
  前缀显式转发这些值，每个会话把它们固定在自己的 runner 和 launcher 里。
- 每次 exec 的项目根必须与本机会话登记的物理根一致。
- hook 和 dispatcher 都拒绝直接在本机启动 `claude`、`codex`、`opencode`；清除常见 AI 凭据，
  并在本机命令 PATH 中屏蔽这些二进制。
- 路由的 bash/zsh 命令加载会话的登录 shell 快照（位于 gateway 会话目录，私有，使用前校验，从不包含
  AI 凭据），不再启动登录 shell；任何失败路径都回退到 `$SHELL -lc`。两种方式都会在 profile 之后再次清除凭据。
- 任意项目 shell 是图灵完备的；绝对隔离需要无 AI 凭据和 Agent 安装的独立本机 OS 账号。

## 内部 Git 与搜索

- Agent 内部发起的 `git`/`rg` 调用不经过 PreToolUse hook。会话 PATH 垫片把工作区扫描
  （`status`、`diff`、`log`、`ls-files`、`grep`、`rg` 等）和只读的仓库发现命令（`rev-parse`、
  `config --get`、`branch --show-current`、`symbolic-ref` 等）路由到项目主机，并把发现命令输出中
  项目主机的绝对路径映射回挂载点；会写入的 git 调用留在远端执行。
- 挂载点之外、或指定了其它仓库/index 的调用，原样执行真实工具。
- Claude 会话默认把 `CLAUDE_CODE_BASH_EDIT_DIFF` 设为 `0`（远端登录 shell 导出的值优先）：它按目录
  建立的 inotify 监听看不到路由命令造成的修改，还会在 SSHFS 上卡住。
- 无法连到项目主机的路由调用必须以非零退出；绝不报告 clean 或无匹配，也不回退为扫描 SSHFS。
  只有可达的项目主机明确答复"未安装该工具"时，本会话此后才改用远端的该工具。
- 路由调用共享每会话并发上限，以及只通过命令行传入的短期 OpenSSH 复用 master；生成的
  `ssh_config` 仍保持 `ControlMaster no`。

## Claude 多 Agent

- 支持继承 settings hook 的普通、具名和嵌套 subagent。
- 关闭 Agent Teams 和 Claude worktree 创建。
- 隔离并行时使用多个本机 Git worktree 和多个 reverse harness 会话；所有 Claude 进程仍在远端，
  可通过 cross-session messaging 协调。

## 不变量

1. 所有拼入远程命令的值必须正确 shell quoting；绝不 `eval` 用户 SSH 输入。
2. 会话 SSH config 和可变 host-key 状态位于 `~/.remote-harness/.sessions`。
3. `~/.ssh` 下只允许修改带标签的 forced-gateway `authorized_keys` 块；用户态 sshd 不修改该目录。
4. 清理必须移除挂载、远端会话 key、gateway 登记、授权、hook 和临时 SSH 状态。本地清理无法执行时，
   由远端会话 watcher 和下次启动的 GC 回收已死会话；它们只处理 `$RH_HOME/.sessions` 的直接子目录，
   且绝不卸载其它存活会话仍在使用的挂载。watcher 只在隧道心跳在整个 `RH_HEARTBEAT_TIMEOUT` 内持续失败
   后才结束 Agent；本机清理只有在隧道由本次启动创建、且重试期间远端始终不可达时，才在没有远端答复的
   情况下停止隧道。会话期间，启动器的守护进程只重建本次启动创建的隧道，端口不变，每次重建都写入记录；
   任何清理步骤之前都会先停止它并接管它的隧道。
5. 被程序解析的脚本 stdout 保持 `KEY=VALUE`。
6. 中英文 Markdown 必须同步。

## 验证

```bash
for script in manage.sh tests/*.sh scripts/*.sh; do bash -n "$script" || exit 1; done
python3 -m py_compile scripts/*.py tests/*.py tests/fixtures/*.py
bash tests/regression.sh
git diff --check
```

装有 sshfs 和 FUSE（macOS 上为 FUSE-T）时，像 CI 一样用 `RH_TEST_REAL_SSHFS=1` 运行回归测试：
真实的本机 SFTP 挂载测试无法运行时会失败，而不是跳过。

完整远端服务器到本机项目的 SSHFS 流程仍需人工集成测试。未经用户要求不得 commit/push；只推送
授权 fork。
