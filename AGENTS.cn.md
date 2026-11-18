> 中文版。英文原版见 [AGENTS.md](AGENTS.md)（以英文版为准）。

# AGENTS.md - remote-harness 维护指南

本仓库是 remote-only remote-harness skill。Claude、Codex、subagent 和独立 Agent 会话全部运行在
远端服务器。本机只作为项目主机：通过 SSHFS 提供文件，并通过 forced gateway
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
- `scripts/inject-rule.sh`：生成每个会话的设置、hook、runner 和垫片。
- `scripts/run-on-project-host.sh`：校验后的本机项目命令和工具 dispatcher。
- `scripts/project-host-tool.py`：远端会话的 `git`/`rg` PATH 垫片，负责工作区扫描。
- `scripts/session-reaper.sh`：本地清理没有执行时，负责远端会话的 watcher 和 GC。
- `scripts/paseo-session.mjs` / `orca-session.py`：创建原生 Claude 和 Codex 会话。
  `paseo-guard.py` / `orca-claude.py` 保护 Claude 工具调用。`native-codex.py` 将 Codex
  app server 绑定到会话的私有 lease，`codex-project-tools.py` 提供路由工具。
- `scripts/channel-guard.py`：在路由 Bash 命令存续期间持有其 SSH 通道。
- `scripts/session_privacy.py`：v3 真实中心 profile 与 presentation ID/绑定缓存，不保存项目原值映射，
  也不进行结果二次替换。`project-session-info.sh` 在项目主机持有私有表，提供经正常审批的
  `rh-session-info` 会话展示入口。
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
- 终端模式通过 `ssh -tt <远端> ... <claude|codex>` 启动主 Agent。已不再支持 opencode：所有入口都
  拒绝 `--launch opencode`。Claude 选择 `--ui paseo` 时，同一 SSH 会话监管 Harness 桥接进程，
  由同一主机的 Paseo 守护进程带注入设置启动主 Agent。桥接进程在归档和退出前撤销 lease；通道清理后，
  全工具 hook 拒绝旧 Paseo 会话的工具调用。
- 选择 `--ui orca` 时，桥接进程为该会话保留专用挂载点，并在同一 Agent 主机的 Orca Server
  创建原生聊天。包装器将聊天身份和挂载绑定到 lease。清理后需保留身份和挂载的
  预留记录，已结束的聊天不会自行获得路由。只有在本地终端认领它的同一 Agent 启动
  （`orca-session.py claim`）才能在其原挂载点继续；桥接进程重新打开该聊天，Orca 已没有 Claude
  聊天时，则新建聊天接着原对话继续。终端 Claude 启动也可以认领已结束的 Claude 聊天
  （`claim ... terminal`），自己在该挂载点接着其对话继续。Orca Claude 启动则可以接管该项目已结束的
  终端对话（`orca-session.py adopt`）：Orca 只恢复 cwd 为该聊天目录的对话记录，所以 adopt 以新的会话
  ID 复制一份，把其中的 cwd 改到新挂载点，这份副本成为新聊天的身份。只有项目默认挂载点无人使用时才列出
  终端对话，已接管过的要在之后有变化才会再次列出。Orca Codex 聊天的线程和 rollout 保存在
  `.orca-codex-chats/<chat>.state`（会话 `codex-home` 的 `sessions` 链接到这里），凭据副本仍留在会话中。桥接进程仅在重启后的 Orca Server 再次通过启动检查后才接管它；
  两个包装器都会拒绝由不受支持的 Orca 版本（`ORCA_APP_VERSION`）启动的已绑定聊天。不在
  `ORCA_VERSIONS` 中的版本，仅当它是已列出主次版本的更新补丁时才受支持，并在启动器中警告；
  codex-cli 按 `CODEX_VERSIONS` 适用同一规则。
- 启动器把每次 Agent 启动的开始和结束原因追加到本机 `~/.remote-harness/launches.log`，同一项目
  下次启动时提示异常结束。原生桥接进程在聊天于应用中被关闭时退出 0，被信号停止时退出 128 加信号值，
  Orca 桥接进程与 Orca Server 失去联系后退出 3；启动器据此判断原因。
- 终端 Claude 启动的续接菜单把在其挂载点因断线结束的对话列在第一项并默认选中（读取
  `session-reaper.sh resume-peek` 和本机标记，均不消耗）；菜单里的选择就是最终决定，注入步骤消耗两份
  记录，不再询问。
- 原生 Codex 包装器启动私有 stdio app server，禁用内置 shell 和代码执行工具。私有 MCP 命令工具
  使用 Codex 原生审批，执行前检查 lease、gateway 策略及 Codex 规则，再调用项目主机 runner。
  文件编辑使用挂载。桥接 lease 失效后 app server 停止，旧聊天不能用其他挂载或账号继续。
- Claude/Codex Bash 导向本机；Agent/Spawn 工具仍在远端执行。
- Claude 要求 2.1.295+，路由 hook 必须设置 `onFailure: "block"`；hook 被取消或失败时，绝不能让
  原始 Bash 命令在 Agent 主机执行。生成的会话设置会保持 hooks 启用，即使项目设置了
  `disableAllHooks`。路由 hook 的超时预算必须大于内部命令策略检查的超时；新设置需要新建 harness 会话。
- Claude 的 hook 对路由调用绝不返回审批决定：`allow` 会跳过 Claude 的审批提示和 auto 模式自动审核。它改写成
  可读的 `rh-run --cwd <目录> -- <命令>`，由用户选择的审批模式判断原始命令。Codex 的 hook 写同样的格式；Codex 只接受与 `allow` 一起返回的 `updatedInput`，这不会跳过它自己的审批。
  会话设置加一条 `autoMode.environment`，写明 runner，要求自动审核判断引号里的命令，而不是包装本身。
  它绝不添加放行规则；只有会话启动时用户和托管设置都没有 environment，才带上 `"$defaults"`。
  不在项目默认挂载点时，会话设置还会把 `autoMemoryDirectory` 指向默认挂载点的记忆目录，除非用户或
  托管设置已有该项。
- Claude 只能看到 rh-run，所以它的 hook 用原始命令对照用户自己的规则：`Bash(...)` deny/ask 对共享词法器
  找到的任意一条简单命令生效，allow 只在 default/acceptEdits/dontAsk 模式（绝不包括 auto）下对单条普通命令
  生效。规则文件只在标识变化时重读。Codex 自己检查原命令：改写后在 `exit` 之后另起一行附上原命令，
  shell 不会解析这一行，Codex 的执行策略（`.rules` 规则、带 `-f` 的 `rm`）会读它。
- Claude 会话禁止 Read/Edit 访问 `$RH_HOME/.sessions`，禁止 Read 访问 `/proc` 和主机元数据文件
  （包括 timezone/localtime 及其解析目标）。`rh-session` 清除 `SSH_CONNECTION`/`SSH_CLIENT` 中所有
  地址和端口。v3 展示已认证中心的真实主机名、机器 ID、有效 TZ/TZDIR 和已验证的身份地址；私有固定表
  只在项目侧持有和执行，中心只缓存目标 profile、presentation UUID 和绑定摘要。`rh-session-info`
  经正常审批的 exec 返回 `view=session`，正文不能自行声明可信。命令、路径、目的地址、业务数据、
  诊断、项目 HOSTNAME/HOST/TZ 和 SSHFS/SFTP 字节保持原值。`--project-timezone` / `RH_PROJECT_TZ`
  仅显式覆盖项目执行，v3 拒绝旧 `--session-timezone` / `RH_SESSION_TZ`，已冻结 v2 保留原语义。
  native claim/adopt 保留展示身份，Claude 断线恢复指定确切 UUID；终端 Codex 通用 `resume --last`
  无法证明绑定而被拒绝，native Codex 保留已登记 thread。不虚构可选字段。首版报告
  timestamp_conversion=false，保留完整时间组。新 native lease 明确记录策略版本，不能因策略缺失而
  降级；pre-policy 活会话需要已知的私有只读 injector 快照，保留原环境和冻结 MCP 实现。
  select/bind 使用 injector 返回的绝对 Python 和冻结脚本路径。完整保留 POSIX TZ 字符串及安全
  自定义时区文件名，TZDIR 单独校验。Linux sshfs 使用 fsname=remote-harness，挂载来源保存在仅本人
  可读的挂载记录里；垫片 stderr 把项目根路径映射回挂载点。

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

把 Orca Server 版本加入 `ORCA_VERSIONS` 之前，在 Agent 主机上运行
`tests/verify-orca-version.sh <orcad 包或 CLI> [<上一版本的包或 CLI>]`；设置 `RH_TEST_CODEX_CLI`
可同时测试原生 Codex 聊天。它只使用临时 profile。启动测试报告的 Claude 参数需先审查，再加入
`KNOWN_FLAGS`。

Agent 主机上装有 Claude 时，还需运行
`RH_TEST_CLAUDE_CLI=/absolute/path/to/claude python3 tests/test_claude_hooks.py -v`。
它使用临时 HOME、虚拟 API key 和回环模型 fixture，验证真实 CLI 的 hook 取消、无效输出及启动失败。
未保护的对照必须复现 Agent 主机上的执行；受保护的失败场景必须不生成两端执行标记。不调用真实模型。
