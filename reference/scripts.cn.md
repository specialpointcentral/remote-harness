> 中文版。英文原版见 [scripts.md](scripts.md)（以英文版为准）。

# 辅助脚本

- `simple-bootstrap.sh`：公开本地入口；skill 只在远端时 fetch reverse helper。
- `simple-dispatch.sh`：reverse-only dispatcher，拒绝 forward。
- `simple-laptop-setup.sh`：本地 reverse 向导。记住的远端挂载点只在对应的项目目录下作为默认值；
  其它情况默认 auto（`~/.remote-harness/mounts/<项目目录名>`）。
  `--local-sshd auto|system|user`（或 `RH_LOCAL_SSHD`）选择隧道连接的本机 SSH 服务；auto 在系统 sshd
  使用 `AuthorizedKeysCommand` 或 `:22` 无服务时询问是否改用用户态 sshd。
- `laptop-setup.sh`：建立反向隧道、forced 授权、挂载、远端 Agent 和清理。本机检查完成后建立一条只通过
  命令行参数启用的复用主连接（短路径 `/tmp/rh.*` socket，`ControlPersist=300`），后续 setup 调用和
  清理都复用它，省去每次 SSH 握手；反向隧道和交互式 Agent 会话仍使用独立连接，启动前还会把本机终端
  尺寸设置到远端 pty 上。`--local-sshd user` 时以当前用户身份启动会话级回环 sshd（`_common.sh` 中的
  `user_sshd_*` 辅助函数），隧道转发到它。
  Agent 会话期间，后台守护进程每 5 秒检查一次本次创建的隧道，隧道 ssh 退出时在同一端口重建
  （`ExitOnForwardFailure`；失败之间按 5、10、20、30、60 秒退避），资源记录始终指向当前的 ssh；它只写
  `tunnel.log`（ssh 的报错写入 `tunnel.log.ssh`），启动器不在了就自行退出，清理时先停止它并接管它最后
  启动的隧道。复用其它启动建立的隧道时不做守护。会话 Host 的 keepalive 能容忍 `RH_KEEPALIVE_TIMEOUT` 秒
  （默认 300）无响应。
- `simple-local-setup.sh`、`local-setup.sh`：拒绝本机 Agent 的兼容 stub。
- `setup-tunnel.sh`：创建远端会话 SSH config 和每会话 key。`IdentitiesOnly yes` 将认证限制为已配置
  的密钥；新密钥的注释不包含主机名。
- `check-tunnel.sh`：通过 `remote-harness-health` 检查 forced gateway。成功时只报告状态；旧有输出键
  `LAPTOP_HOSTNAME`/`LAPTOP_USER` 保留为空，即使对端是旧版 gateway 也不转述身份信息。SSH 失败
  诊断仍会保留。
- `mount-project.sh`：在远端 Agent 主机通过 SSHFS 挂载本机项目，默认只用一条 SFTP 连接（`RH_SSHFS_MAX_CONNS`
  设为大于 1 时，在 sshfs 支持的情况下启用并行连接；在约 360ms 的线路上实测，它会让并发查询慢约 7 倍）；libfuse 版 sshfs
  还会在内核里缓存路径查找、文件属性和「文件不存在」的结果 `RH_SSHFS_CACHE_SECONDS` 秒（默认 20，设为 `0`
  关闭），因为 Agent 会反复探测同一批 `.git` 路径；`auto_cache` 让未变化的文件内容在多次打开之间保持缓存。
  默认由项目主机解析符号链接（`follow_symlinks`）：所有链接都与在项目主机上读取的结果一致，链接文件和目录
  表现为普通条目，因此递归扫描也会进入链接指向的目录树。若要保留链接本身，在本机终端先运行
  `export RH_SSHFS_FOLLOW_SYMLINKS=0`，再运行 bootstrap 命令；`laptop-setup.sh` 校验 `0|1` 后传给远端挂载，
  挂载改用 `transform_symlinks`。相对目标保持原样；项目内部的绝对目标在挂载中转为相对路径，项目中保存的
  链接不会改变。此时由远端主机自己解析链接：项目外部的目标不会被重新映射，可能不存在，或指向远端主机上的
  路径；默认开启符号链接 containment 的 sshfs 版本（例如 Debian 12 的安全更新 `3.7.3-1.2~deb12u1`，
  CVE-2026-47187）会拒绝所有含 `..` 或绝对路径的目标，项目内部的链接也不例外。containment 保持开启；
  需要用到这类链接时请使用路由 Bash。该方式在创建挂载时确定并记录在挂载记录中：复用另一个会话正在使用的
  挂载时沿用现有方式，与请求不一致时启动器会给出提示。挂载解除后如果 sshfs 进程没有退出，
  只有在它的 FUSE superblock 已经释放，并且满足以下之一时才会结束它：正常卸载成功（内核已确认没有打开的文件，等 1 秒），
  或 sshfs 自身在 `RH_SSHFS_IDLE_SECONDS`（默认 3）秒内没有任何 I/O 进展（其 ssh 连接的 keepalive 不计入），之后其 sftp ssh 会因 EOF 自行退出。
  只要还有 cwd、打开的文件、内存映射、其他 mount namespace 或阻塞中的请求引用已卸下的挂载，内核就会在 fusectl
  （`/sys/fs/fuse/connections/<设备号>`）下保留这个 superblock；设备号在卸载前从 `/proc/self/mountinfo` 读取。
  不再扫描其他进程的 `/proc` 链接：sshd 等 non-dumpable 进程的链接读不到，lazy 卸载后的文件也不再显示在原挂载点之下。
  拿不到 fusectl 的结论时，lazy 卸载后的 sshfs 会保留。仍在刷写数据的 sshfs 不会被打断（等待上限由
  `RH_SSHFS_SYNC_MAX_SECONDS` 控制，默认 120）。没有 `/proc` 的系统上不会结束任何进程。
- `inject-rule.sh`：安装会话 instruction、Claude/Codex hook 或 opencode plugin，以及远端 runner；
  opencode 还会返回启动前必须出现的 readiness marker 路径。
  会话目录按挂载点加本次启动的 session id 区分，因此重复启动同一项目或清理已断开的会话时，
  不会删除其它仍在运行的会话的 hook 或 runner。
  规则要求 Agent 按用户最近一条消息的语言回复，而不是按指令、工具输出或项目文件的语言回复，
  并在每一轮用户消息上重复一行提醒：Claude 和 Codex 用 `UserPromptSubmit` hook，opencode 用
  `experimental.chat.messages.transform` 插件钩子，只在内存中附加到最新一条用户消息上。只靠规则时，
  它位于上下文开头，大量英文工具输出会让回复逐渐变成英文。
- `route-command.py`：校验 Agent/Bash、拒绝直接本机 Agent 启动、映射 cwd。
- `diagnostics.py`：Agent 主机上的路由诊断 helper。OpenSSH 自身的错误写入 SSH config 旁
  `runtime/diagnostics` 下仅属主可读写的文件；框架摘要只包含失败类别、退出码和不含主机信息的通道会话
  编号（尚不可用时为 `unknown`），共享通道的会话共用该编号。日志保留到通道的正常清理，因为持久 SSH
  master 在发起调用返回后仍可能写入。Agent 不得自动读取
  原始日志或带入上下文，只有用户明确要求详细诊断时才可读取。这是工作流程约定，无法隔离同一 OS
  账号下的进程。本机终端中的 bootstrap 和隧道设置保留面向操作者的诊断。
- `run-on-project-host.sh`：校验并执行本机项目命令（watch 模式下 stdin 为 `/dev/null`、使用独立
  进程组和通道 EOF 看门狗），或直接运行白名单内的 `git`/`rg`（不经 shell、
  固定 PATH），SSH 通道关闭时终止该工具。客户端一侧设置每连接 keepalive 和可选的复用 master。
  `--find-tool <git|rg>` 报告工具动词会在哪里找到该工具；`laptop-setup.sh` 在启动前用它打印 ✓，
  或打印 ⚠ 和安装命令，因为缺少工具时 Agent 会通过 SSHFS 扫描项目。
  `$SHELL` 是 bash 或 zsh 时，项目命令加载登录 shell 快照，不再每次新开登录 shell（profile 较重的主机上
  每次 200ms 以上）。第一条命令把 profile 执行后的结果（导出变量、函数、shell 选项、umask、软资源限制；
  从不包含 AI 凭据和 `SSH_CONNECTION` 这类单次连接相关的值）抓取到 gateway 会话目录的 `shell-snapshot.sh`，
  确认能静默且完整加载后才启用。满 10 分钟或启动文件（`~/.profile`、`~/.zprofile`、`/etc/profile.d`
  等）变化后重新抓取。抓取失败或超过 30 秒记入 `shell-snapshot.failed`，10 分钟后或启动文件变化后再试；
  在此之前，以及快照不可用时（其它 shell、权限不安全、另一条命令正在抓取），命令用登录 shell 执行。
  运行时快照加载失败，则拒绝这一条命令（状态 125）并丢弃快照。启动时设置 `RH_SHELL_SNAPSHOT=off`
  可关闭。两个 dispatch 动词都会从命令环境清除常见 AI 凭据及 `SSH_CLIENT`、`SSH_CONNECTION`、
  `SSH_TTY`、`SSH_ORIGINAL_COMMAND`、`RH_GATEWAY_SESSION_DIR`、`HOSTNAME` 和 `HOST`。shell 命令
  在 profile 或快照加载后再次清理；若只读变量阻止清理，则以状态 125 拒绝执行命令。不会带过来的：
  未导出的 shell 变量和 zsh 的 alias（bash 本来就不在命令里展开 alias）。
- `project-host-gateway.sh`：只接受 SFTP、health、固定 exec 协议、`git`/`rg` 工具动词和
  `remote-harness-wait` 的 forced SSH command。`remote-harness-wait` 先输出 `RH_WAIT_READY`，从通道读一行
  完整的 exec 或 tool 请求，以 `RH_WAIT_GOT` 确认，然后按同样的 SSH 命令处理。它把自己的会话目录传给
  exec dispatcher，覆盖客户端可能带来的同名值。
- `channel-guard.py`：远端有 python3 时包装会话 Bash runner，命令运行期间一直持有 SSH 通道，
  使项目主机在取消或断线时终止命令树。带 `--warm SOCKET --warm-request LINE`（由 `rh-run` 写入）时，
  先在预热通道上发送请求并转发输出；完整的一行没写进去的请求改走普通路径，已写出却没有收到确认的请求以
  255 失败（送达不确定，绝不重试）。带 `--slots-dir` 时普通路径占用一个每会话名额：
  `RH_FOREGROUND_CONCURRENCY`（6），最多排队 `RH_CHANNEL_QUEUE_SECONDS`（600）秒，排队期间持续向预热池
  要通道；`--background`（显式的后台 Bash，使用独立连接，不用通道池）使用 `RH_BACKGROUND_CONCURRENCY`（8）
  和 `RH_BACKGROUND_QUEUE_SECONDS`（10）。
- `warm_pool.py`：`serve`（由 `rh-session` 启动，每会话一个）通过自己的复用连接
  （`runtime/wm.<会话 ID>`）在 gateway 的 wait 动词上保持已打开的通道，经 `runtime/warm.<会话 ID>`
  以文件描述符的形式交给客户端，并报告退出码。就绪通道保持在 `RH_WARM_MIN`（1）到 `RH_WARM_READY_MAX`
  （2）条，同时最多打开 `RH_WARM_OPENING_MAX`（2）条、每条限时 `RH_WARM_OPEN_TIMEOUT`（10 秒），包括已交出的
  通道在内最多 `RH_WARM_MAX` 条（system sshd 为 9；user 模式 sshd 按 `RH_SSHD_MAX_SESSIONS` 最多 16）。
  空闲 `RH_WARM_IDLE`（90 秒）后收缩，就绪通道每 `RH_WARM_MAX_AGE`（600 秒）更新；只经自己的 master 打开
  通道（`ProxyCommand=false`），被拒或打不开时退避，约 15 秒内发现隧道断开（keepalive 5 秒 × 3），断开的
  连接重建，遇到不支持 wait 的 gateway 就停用，随 Agent 或会话目录排空已交出的命令后退出，日志写在会话目录的
  `warm.log`。`RH_WARM_MAX=0` 关闭。模块的客户端部分（`claim`、`run`）只用少量标准库模块。
- 传输设置（`scripts/_common.sh`）：上面的预热池、配额和排队时间，加上 `RH_SSHD_MAX_SESSIONS`（32，user 模式
  sshd 的 `MaxSessions`），都只接受白名单内的数字，来自环境变量或本机可选的
  `~/.remote-harness/transport.conf`（`KEY=VALUE`，只解析、绝不 source；环境变量优先）。`laptop-setup.sh`
  以显式的 `env` 前缀转发全部设置，每个会话把它们固定在 `rh-run` 和 `rh-session` 里。
- `project-host-tool.py`：远端会话的 `git`、`rg` PATH 垫片。挂载点内的工作区扫描在项目主机执行，
  只读发现命令（`rev-parse`、`config --get` 等）也在项目主机执行，路径双向翻译；会写入的 git 调用和挂载点外的
  调用使用远端真实工具。路由调用共享并发上限
  （`RH_TOOL_CONCURRENCY`，默认 6），先尝试预热通道（`--warm-socket`）；传输失败且没有输出时改走普通
  路径，再不经复用 master 重试一次，否则以非零退出。
  rg 只翻译搜索路径和取路径值的选项，保留模式、替换文本与 glob。未知或有歧义的选项，以及指定 Agent
  端程序的选项（`--pre`、`--hostname-bin`），在规划时留在 Agent 主机执行；传输失败绝不会改走此路径。
  rg 文本始终映射行首的项目根路径前缀，包括单个绝对路径文件的 `--vimgrep` 输出。仅含内容的匹配若以相同
  前缀开头，就无法与文件名区分，也会接受同样的映射。JSON 映射在内存中逐条解码完整记录，只修改
  `data.path.text` 或 base64 编码的 `bytes` 变体；内容和匹配偏移的值不变，但 JSON 格式可能变化。
  Git 发现输出按换行/NUL 分隔的记录逐条映射路径。rg 文本改写使用有界内存。项目 stderr 逐字节保留，
  最多缓存 64 KiB 以识别工具缺失协议，超出后流式输出。即使命令返回 255，只要有项目 stderr 就不再
  重试；传输错误和容量信息由独立的私有 SSH 诊断提供，stdout 的既有路径映射不变。
- `session-reaper.sh`：远端每会话 watcher 加启动时 GC。Agent 进程消失（或其终端已挂断）时，
  停止复用 master 和残留的路由进程，在没有其它存活会话使用时卸载该会话挂载，并删除会话目录
  以及会话 SSH config 和 private key。经隧道的心跳检查连续失败满 `RH_HEARTBEAT_TIMEOUT` 秒后结束 Agent；
  断线会留下 `.resume` 标记，由 `inject-rule.sh on` 以 `RH_RESUME_AVAILABLE=<原因>,<时间戳>` 报告一次。
  Agent 在项目主机不可达时自行退出（如收到 SIGHUP）也会留下标记（`exited`）。交互 ssh 以 255 退出时，
  `laptop-setup.sh` 会在本机记下标记；任一标记存在都会询问是否继续。
  挂载登记、launcher 释放和 GC 共用锁，分别追踪命令配置和实际 SSHFS 配置。卸载失败保留重连
  配置及实现。`release-config` 仅在具体通道可回收后返回 `USED=0`；sshfs 进程（及其 sftp ssh）只在其挂载点
  仍处于挂载状态时才算正在使用该配置。失败时保留本地隧道、配置和
  授权记录，供后续重试。运行入口使用每会话 `impl` 副本，本机 gateway 按密钥保存副本。
  现有清理流程会随闲置通道一同删除遗留的 SSH config 临时副本，保留活跃或共享的通道，以及仍被挂载
  引用的实现副本。本机和远端的恢复标记在现有清理中使用相同的七天过期条件。这些检查由 watcher
  或下次启动触发，没有增加定时删除服务；无法确认释放状态时，继续保留安全重试所需的记录。

运行状态位于 `~/.remote-harness/.sessions`。`~/.ssh` 下唯一写入是带标签、仅回环、forced-command
的 `authorized_keys` 块（用户态 sshd 模式不写，授权放在其会话目录中）。清理会删除授权、gateway 登记、远端 private key、挂载、hook 和临时 config。若本地一侧先断开，
远端 watcher 或下次启动的 GC 会完成其中远端部分；残留的本机 `authorized_keys` 块随之失效，
因为对应 private key 已不存在。

设置脚本即使在调用者使用宽松 umask 时也会创建私有目录和数据文件；生成的 launcher 保留 Agent 原有
的 umask。权限修改只针对框架自己的文件，不递归修改挂载项目。规则文本不包含具体项目主机路径和别名，
运行时 runner 与 SSH config 仍保留路由所需的真实值。

SFTP 授权是账号级访问，并没有 chroot 到登记项目。需要项目级文件隔离时，应使用独立本机 OS 账号。
