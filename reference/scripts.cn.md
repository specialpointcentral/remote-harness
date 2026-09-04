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
- `route-command.py`：校验 Agent/Bash、拒绝直接本机 Agent 启动、映射 cwd。
- `run-on-project-host.sh`：校验并执行本机项目命令。
- `project-host-gateway.sh`：只接受 SFTP、health 和固定 exec 协议的 forced SSH command。

运行状态位于 `~/.remote-harness/.sessions`。`~/.ssh` 下唯一写入是带标签、仅回环、forced-command
的 `authorized_keys` 块。清理会删除授权、gateway 登记、远端 private key、挂载、hook 和临时 config。

SFTP 授权是账号级访问，并没有 chroot 到登记项目。需要项目级文件隔离时，应使用独立本机 OS 账号。
