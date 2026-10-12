> 中文版。英文原版见 [scripts.md](scripts.md)（以英文版为准）。

# 辅助脚本

- `simple-bootstrap.sh`：公开本地入口；skill 只在远端时 fetch reverse helper。
- `simple-dispatch.sh`：reverse-only dispatcher，拒绝 forward。
- `simple-laptop-setup.sh`：本地 reverse 向导。
- `laptop-setup.sh`：建立反向隧道、forced 授权、挂载、远端 Agent 和清理。
- `simple-local-setup.sh`、`local-setup.sh`：拒绝本机 Agent 的兼容 stub。
- `setup-tunnel.sh`：创建远端会话 SSH config 和每会话 key。
- `check-tunnel.sh`：通过 `remote-harness-health` 检查 forced gateway。
- `mount-project.sh`：在远端 Agent 主机通过 SSHFS 挂载本机项目。
- `inject-rule.sh`：安装会话 instruction、Claude/Codex hook 或 opencode plugin，以及远端 runner；
  opencode 还会返回启动前必须出现的 readiness marker 路径。
  会话目录按挂载点加本次启动的 session id 区分，因此重复启动同一项目或清理已断开的会话时，
  不会删除其它仍在运行的会话的 hook 或 runner。
- `route-command.py`：校验 Agent/Bash、拒绝直接本机 Agent 启动、映射 cwd。
- `run-on-project-host.sh`：校验并执行本机项目命令（watch 模式下 stdin 为 `/dev/null`、使用独立
  进程组和通道 EOF 看门狗），或直接运行白名单内的 `git`/`rg`（不经 shell、
  固定 PATH），SSH 通道关闭时终止该工具。客户端一侧设置每连接 keepalive 和可选的复用 master。
- `project-host-gateway.sh`：只接受 SFTP、health、固定 exec 协议和 `git`/`rg` 工具动词的
  forced SSH command。
- `channel-guard.py`：远端有 python3 时包装会话 Bash runner，命令运行期间一直持有 SSH 通道，
  使项目主机在取消或断线时终止命令树。
- `project-host-tool.py`：远端会话的 `git`、`rg` PATH 垫片。挂载点内的工作区扫描在项目主机执行，
  路径双向翻译；路径发现命令和挂载点外的调用使用远端真实工具。路由调用共享并发上限
  （`RH_TOOL_CONCURRENCY`，默认 6），传输失败时不经复用 master 重试一次，否则以非零退出。
- `session-reaper.sh`：远端每会话 watcher 加启动时 GC。Agent 进程消失（或其终端已挂断）时，
  停止复用 master 和残留的路由进程，在没有其它存活会话使用时卸载该会话挂载，并删除会话目录
  以及会话 SSH config 和 private key。
  挂载登记、launcher 释放和 GC 共用锁，分别追踪命令配置和实际 SSHFS 配置。卸载失败保留重连
  配置及实现。`release-config` 仅在具体通道可回收后返回 `USED=0`；失败时保留本地隧道、配置和
  授权记录，供后续重试。运行入口使用每会话 `impl` 副本，本机 gateway 按密钥保存副本。

运行状态位于 `~/.remote-harness/.sessions`。`~/.ssh` 下唯一写入是带标签、仅回环、forced-command
的 `authorized_keys` 块。清理会删除授权、gateway 登记、远端 private key、挂载、hook 和临时 config。若本地一侧先断开，
远端 watcher 或下次启动的 GC 会完成其中远端部分；残留的本机 `authorized_keys` 块随之失效，
因为对应 private key 已不存在。

SFTP 授权是账号级访问，并没有 chroot 到登记项目。需要项目级文件隔离时，应使用独立本机 OS 账号。
