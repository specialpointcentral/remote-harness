# remote-harness Remote-Only 设计

> 英文版见 [design.md](design.md)。

## 角色

- **Agent 主机**：远端服务器。所有 Claude、Codex、opencode、subagent 和独立 Agent 进程都在这里运行。
- **项目主机**：用户本机。保存项目并执行项目命令。

forward/本机 Agent 模式已禁用；兼容入口在执行任何工作前失败。

## 数据流

```text
本地 bootstrap
  -> 到远端服务器的反向 SSH 隧道
  -> 远端每会话 SSH key
  -> 本机 forced-command 授权
  -> 在远端服务器 SSHFS 挂载本机项目
  -> 在远端启动 Claude/Codex/opencode

远端文件工具 -> SSHFS -> 本机项目文件
远端 Bash     -> Claude/Codex hook 或 opencode plugin -> rh-run -> forced gateway -> 本机项目命令
远端 git/rg   -> 会话 PATH 垫片 -> （扫描 / 只读发现）forced gateway 工具动词 -> 本机 git/rg
                               -> （写操作 / 挂载点外）远端 git/rg
远端 Agent 工具 -> 远端 subagent 进程，绝不导向本机
```

## Forced Gateway

本机 `authorized_keys` 行把每会话 key 绑定到 `project-host-gateway.sh <session-tag>`，并禁用 PTY、
port、X11 和 agent forwarding。gateway 只接受：

- SSHFS 使用的标准 SFTP；
- `remote-harness-health`；
- `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`；
- `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`，每个参数编码为
  `base64("x" + arg)`，以逗号连接；
- `remote-harness-wait`：预先打开、接收一行 exec 或 tool 请求的通道（见"预热通道"）。

gateway 拒绝任意 SSH shell，并验证请求项目根与本地 bootstrap 登记的根一致。同一 key 若存在无限制
用户授权，会作为致命配置错误拒绝，而不是复用。

## 命令策略

`route-command.py` 处理 Claude/Codex。生成的 opencode `tool.execute.before` plugin 为 opencode 执行
等价的 Bash 和 cwd 改写。`run-on-project-host.sh` 校验本机物理 cwd，拒绝直接启动 Agent CLI，清除
常见 AI 凭据环境变量，在 `PATH` 中屏蔽 Agent 二进制，然后用项目主机登录 shell 的环境执行。对 bash
和 zsh，这个环境来自会话级快照，而不是每条命令新开一个登录 shell：第一条命令抓取 profile 执行后的结果
（除 AI 凭据和单次连接相关值以外的导出变量、函数、shell 选项、umask、软资源限制），确认能静默且完整加载
后才启用，满 10 分钟或启动文件变化后重新抓取。任何失败（不支持的 shell、超时、权限不安全、另一条命令
正在抓取）都让这条命令改用登录 shell 执行。

远端有 python3 时，`rh-run` 经过 `channel-guard.py` 执行：它在调用存续期间一直持有 SSH 通道的
stdin，并请求 `remote-harness-exec ... watch`。项目主机随后让命令的 stdin 来自 `/dev/null`，把命令放进
独立进程组（Linux 用 `setsid`，macOS 用 `perl` 的 `setpgrp`），并把通道 EOF 视为取消：Bash 调用被停止
或超时、Agent 被杀、连接断开时，先向命令的进程组和进程树发送 TERM，五秒后发送 KILL。主动脱离的
进程（`nohup ... &`、`setsid`、守护进程）不会被追踪。没有 python3，或旧客户端不带 `watch` 时，执行
方式不变。`git`/`rg` 工具动词始终使用同样的看门狗。

这会阻止直接和常见间接本机 Agent 路径。任意项目 shell 仍是图灵完备的，而且 gateway SFTP 没有
chroot 到登记项目。绝对安全边界需要独立本机 OS 账号；该账号只能访问目标项目，不保存 AI 凭据，
也不安装 Agent。

## 内部 Git 与搜索

PreToolUse hook 只能看到工具调用。Git 状态快照、文件补全、Grep/Glob（通过
`USE_BUILTIN_RIPGREP=0`）、opencode 搜索、状态栏，以及其它内部 `git`/`rg` 进程，都经过每会话生成的
PATH 垫片（`project-host-tool.py`）。在 SSHFS 上，这类扫描的每次 lstat、目录读取和文件读取都要
经过一次隧道往返，所以垫片把它们放到项目主机执行：

- 路由：有效 cwd 在挂载点内时的 `git status|diff|diff-files|diff-index|diff-tree|log|show|shortlog|
  whatchanged|ls-files|ls-tree|grep|blame|rev-list` 和 `rg`；
- 路由并映射输出：只读发现命令（`rev-parse`、`config --get/--list`、列出用的 `branch`、
  `symbolic-ref`、`show-ref`、`for-each-ref`、`describe`、`merge-base`、`cat-file`、`remote -v`、
  `worktree list` 等）。在 SSHFS 上，每条都要逐个往返读取十几个 `.git` 文件（慢速链路上每条 5–20
  秒，Agent 在首次提示前就会执行好几条）；输出中出现在路径边界上的项目主机根路径都会映射回挂载点
  （如 `<path>  <sha> [branch]`、`worktree <path>`），而 rg 的输出只改写每条记录开头的路径，因为其余
  部分可能是文件内容；
- 留在远端：会写入的发现命令形式（`config key value`、`branch -d` 等）、其它写操作、设置了
  `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` 的调用、`--stdin`/`--batch`，以及参数里出现挂载点外
  已存在的远端路径。在挂载点上远端执行的 git 会带上 `-c core.checkStat=minimal
  -c core.trustctime=false`，避免项目主机写入的 index 迫使逐个读取文件内容；
- 通过环境变量传入的 git 配置（Claude Code 内部调用会设置的 `GIT_CONFIG_PARAMETERS`，以及
  `GIT_CONFIG_COUNT`/`KEY`/`VALUE`）会转成 `-c` 一起转发；只有无法解析时才留在远端执行，因此会话启动时的
  git 快照不会在 SSHFS 上扫描整个工作区；
- 参数里的挂载路径映射为项目根，rg 输出记录再映射回挂载路径；
- 在项目主机上，工具从固定 PATH 直接 exec、不经 shell；SSH 通道关闭时终止该工具，所以调用方被
  取消或链路断开时不会留下仍在扫描的进程；
- 每会话并发上限（默认 6）让路由调用低于项目主机 sshd 的 `MaxSessions`；传输失败时不经复用
  master 重试一次，之后以非零退出，绝不表现为 clean 或无匹配；
- 项目主机可达但答复未安装该工具时（例如 Mac 未装 ripgrep），本会话记录一次，此后该工具在远端
  经挂载点执行。这样 Claude 的 Grep/Glob 仍可用；这不属于传输失败后的回退；
- 路由调用读取项目主机的 Git 配置（全局 excludes、`core.autocrlf` 等），留在远端的 git 读取
  远端用户的全局配置和共享的仓库 `.git/config`。因此仓库级设置一致，用户级设置可能不同。

## 连接

路由命令和工具调用只在命令行上传入 `ServerAliveInterval=10`、`ServerAliveCountMax=3`、
`ConnectTimeout=10`、`Compression=yes`，以及复用 master（`ControlMaster=auto`、
`ControlPersist=300`），其 socket 位于会话 `runtime/` 目录。该路径超过 Unix socket 长度限制时不启用
复用。隧道断开后 master 约 30 秒内退出，空闲 master 五分钟后退出，失效 socket 会被自动替换，
SSHFS 使用自己独立的连接。

## 预热通道

新开一条 SSH 通道，要 2 到 3 个往返才能执行命令（80ms 的线路上约 240ms）。Agent 主机有 python3 时，
`rh-session` 会启动 `warm_pool.py serve`：它通过自己的复用连接（`runtime/wm.<会话 ID>`）在 gateway
的 `remote-harness-wait` 动词上保持若干已经打开的通道，于是一次路由的 Bash 或 git/rg 调用只需约 1 个
往返：

1. 客户端（Bash 用 channel-guard，git/rg 用工具垫片）向通道池的私有 Unix socket
   （`runtime/warm.<会话 ID>`）要一条就绪通道，以文件描述符的形式拿到它的 stdin、stdout、stderr；
   通道池自己不再保留任何一个。
2. 客户端写入与作为 SSH 命令发送时完全相同的请求行。gateway 在执行任何东西之前先用 `RH_WAIT_GOT`
   确认，然后走同样的校验和 dispatcher。
3. 客户端转发输出；通道的 ssh 退出时，通道池报告退出码并补开一条。每条通道只服务一次请求，所以
   输出流、退出码和"关闭 stdin 即停止命令"都不变。

请求最多执行一次。完整的一行没能写进去的请求并没有执行，改走普通路径。一旦整行写出，没有收到确认就
属于送达不确定（通道可能在 gateway 读到这一行之前或之后断开），所以 Bash 以 255 失败、绝不重发；只读的
git/rg 调用保持原有的重试。已确认的 Bash 请求同样绝不重发。没有通道池、没有就绪通道、或旧版 gateway
不支持 wait 动词，都走普通路径。

通道池启动时保持 `RH_WARM_MIN` 条就绪通道（1），客户端每遇到一次池空就加一条，就绪通道最多
`RH_WARM_READY_MAX` 条（2），同时打开中的最多 `RH_WARM_OPENING_MAX` 条（2），每条打开超过
`RH_WARM_OPEN_TIMEOUT` 秒（10）就放弃。连接上包括已交出的通道在内最多 `RH_WARM_MAX` 条：默认 9，
低于 system sshd 未另行配置时的 `MaxSessions 10`；使用 user 模式 sshd（`RH_SSHD_MAX_SESSIONS`，32）时，
启动器把它提高到比该值少 1，最多 16。打开通道只走复用（`ProxyCommand=false`），被拒的 session 不会悄悄
变成一条新连接；被拒后按最长 30 秒退避。空闲超过 `RH_WARM_IDLE` 秒（90）的通道关闭到下限；就绪通道每
`RH_WARM_MAX_AGE` 秒（600）更新一次。它的连接用比路由命令更短的 keepalive（`ServerAliveInterval=5`、
`ServerAliveCountMax=3`）：在发现隧道已断（约 15 秒）之前，就绪通道看起来都正常，写在上面的请求属于送达
不确定。断开的连接会重建。Agent 退出（包括尚未被回收的僵尸进程）或会话目录消失时，通道池停止交出通道，
等已交出的命令结束后退出，只删除自己创建的 socket，日志写在会话目录的 `warm.log`。`RH_WARM_MAX=0` 可关闭。

拿不到预热通道的 Bash 调用走普通路径，受每会话 `RH_FOREGROUND_CONCURRENCY`（6）个并发的配额限制。
超出配额的调用最多排队 `RH_CHANNEL_QUEUE_SECONDS`（600）秒，排队期间持续向通道池要通道，空出来的预热
通道会接手；只有排队超时才以 255 失败。显式的后台 Bash（`run_in_background`）不用通道池，使用独立连接，
配额为 `RH_BACKGROUND_CONCURRENCY`（8），排队时间较短，为 `RH_BACKGROUND_QUEUE_SECONDS`（10），因为长时间
运行的后台任务很少释放名额。git/rg 调用有自己的配额 `RH_TOOL_CONCURRENCY`（6），最多排队
`RH_TOOL_QUEUE_SECONDS`（600）秒。

这些容量设置只接受白名单内的数字，来自环境变量或本机可选的 `~/.remote-harness/transport.conf`
（`KEY=VALUE` 行，只解析、绝不 source；环境变量优先）。启动器把每个值作为 SSH 命令的显式 `env` 前缀
转发，会话把它们固定在自己的 runner 和 launcher 里，所以子 Agent 共用同一套限制。

## 异常断开

最终启动 Agent 时经过 `rh-session`：它记录 Agent 的 pid、启动时间和终端，并启动一个脱离会话的
`session-reaper.sh watch`。Agent 退出，或终端已挂断而 Agent 仍残留（此时依次发送 HUP、TERM、
KILL）后，watcher 先等待一个短暂的宽限期让本地正常清理；若本地清理没有发生，它会停止复用
master，终止残留的路由进程，在没有其它存活会话使用时卸载会话挂载，并删除会话目录以及会话
SSH config 和 private key。每次 `inject-rule.sh on` 还会启动 `session-reaper.sh gc`，对已死会话、
超过 30 分钟仍未启动的会话、超过一小时的孤立会话 SSH config 执行同样的清理。private key 删除后，
残留的本机 `authorized_keys` 块也无法再被使用。

挂载登记、launcher 释放和 reaper/GC 释放共用资源锁。lease 分别记录命令 SSH 配置和实际 SSHFS
配置；复用挂载时，即使新会话使用另一个端口，也保留原挂载的通道。卸载、关闭共享 mux 或删除
配置、密钥、runtime 前均检查引用。卸载失败则保留通道及清理实现，供 GC 重试；无法验证来源的
活跃挂载会被拒绝复用，而非替换。本地 `resources.env` 保存隧道 PID、启动时间、配置、gateway
和授权，远端确认释放后才回收；后续启动重试延期清理，网络或检查失败时保留资源。PID 被复用
不会导致误杀隧道。

每个注入会话具有 `impl` 快照，包含 router、guard、dispatcher、工具垫片、reaper 和依赖。
生成的入口及 watcher 使用这些副本，实现目录位于 Codex 可写的 SSH runtime 根之外。本机 gateway
也按反向密钥保存快照。开发目录修改只影响新会话，已有会话保留自己的副本；无快照的旧会话不在
运行中改写或迁移。

## Claude 多 Agent

普通、具名和嵌套 Claude subagent 都留在远端 Agent 主机。settings hook 会在这些 subagent 内运行，
只有 Bash 跨 gateway。Agent Teams 和 Claude worktree 创建被禁用。隔离并行 Agent 使用多个本机 Git
worktree 和远端服务器上的多个 reverse 会话，并通过 cross-session messaging 协调。

## 会话状态

- 远端：SSH config、host key、每会话 private key、mount、hook、runner、工具垫片、复用 socket、
  工具并发槽以及会话/owner 元数据位于 `~/.remote-harness/.sessions/...`。
- 本机：临时 SSH config、forced authorization 块、每密钥 gateway 快照，以及
  `~/.remote-harness/.sessions/gateways/...` 下的每会话项目根登记。

最后一个资源引用消失后才删除状态和授权。保留挂载时也保留其实现快照；本地清理无法验证时保留
资源记录。
