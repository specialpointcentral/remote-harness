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
- `setup-tunnel.sh`：创建远端会话 SSH config 和每会话 key。
- `check-tunnel.sh`：通过 `remote-harness-health` 检查 forced gateway。
- `mount-project.sh`：在远端 Agent 主机通过 SSHFS 挂载本机项目，默认只用一条 SFTP 连接（`RH_SSHFS_MAX_CONNS`
  设为大于 1 时，在 sshfs 支持的情况下启用并行连接；在约 360ms 的线路上实测，它会让并发查询慢约 7 倍）；libfuse 版 sshfs
  还会在内核里缓存路径查找、文件属性和「文件不存在」的结果 `RH_SSHFS_CACHE_SECONDS` 秒（默认 20，设为 `0`
  关闭），因为 Agent 会反复探测同一批 `.git` 路径；`auto_cache` 让未变化的文件内容在多次打开之间保持缓存。挂载解除后如果 sshfs 进程没有退出，
  只有在没有进程使用该挂载点，并且满足以下之一时才会结束它：正常卸载成功（内核已确认没有打开的文件，等 1 秒），
  或 sshfs 自身在 `RH_SSHFS_IDLE_SECONDS`（默认 3）秒内没有任何 I/O 进展（其 ssh 连接的 keepalive 不计入），之后其 sftp ssh 会因 EOF 自行退出；
  仍在刷写数据的 sshfs 不会被打断（等待上限由 `RH_SSHFS_SYNC_MAX_SECONDS` 控制，默认 120）。没有 `/proc`
  的系统上不会结束任何进程。
- `inject-rule.sh`：安装会话 instruction、Claude/Codex hook 或 opencode plugin，以及远端 runner；
  opencode 还会返回启动前必须出现的 readiness marker 路径。
  会话目录按挂载点加本次启动的 session id 区分，因此重复启动同一项目或清理已断开的会话时，
  不会删除其它仍在运行的会话的 hook 或 runner。
  规则要求 Agent 按用户最近一条消息的语言回复，而不是按指令、工具输出或项目文件的语言回复，
  并在每一轮用户消息上重复一行提醒：Claude 和 Codex 用 `UserPromptSubmit` hook，opencode 用
  `experimental.chat.messages.transform` 插件钩子，只在内存中附加到最新一条用户消息上。只靠规则时，
  它位于上下文开头，大量英文工具输出会让回复逐渐变成英文。
- `route-command.py`：校验 Agent/Bash、拒绝直接本机 Agent 启动、映射 cwd。
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
  可关闭。两种方式都会在 profile 之后再次清除 AI 凭据。不会带过来的：未导出的 shell 变量和 zsh 的 alias
  （bash 本来就不在命令里展开 alias）。
- `project-host-gateway.sh`：只接受 SFTP、health、固定 exec 协议和 `git`/`rg` 工具动词的
  forced SSH command。它把自己的会话目录传给 exec dispatcher，覆盖客户端可能带来的同名值。
- `channel-guard.py`：远端有 python3 时包装会话 Bash runner，命令运行期间一直持有 SSH 通道，
  使项目主机在取消或断线时终止命令树。
- `project-host-tool.py`：远端会话的 `git`、`rg` PATH 垫片。挂载点内的工作区扫描在项目主机执行，
  只读发现命令（`rev-parse`、`config --get` 等）也在项目主机执行，路径双向翻译；会写入的 git 调用和挂载点外的
  调用使用远端真实工具。路由调用共享并发上限
  （`RH_TOOL_CONCURRENCY`，默认 6），传输失败时不经复用 master 重试一次，否则以非零退出。
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

运行状态位于 `~/.remote-harness/.sessions`。`~/.ssh` 下唯一写入是带标签、仅回环、forced-command
的 `authorized_keys` 块（用户态 sshd 模式不写，授权放在其会话目录中）。清理会删除授权、gateway 登记、远端 private key、挂载、hook 和临时 config。若本地一侧先断开，
远端 watcher 或下次启动的 GC 会完成其中远端部分；残留的本机 `authorized_keys` 块随之失效，
因为对应 private key 已不存在。

SFTP 授权是账号级访问，并没有 chroot 到登记项目。需要项目级文件隔离时，应使用独立本机 OS 账号。
