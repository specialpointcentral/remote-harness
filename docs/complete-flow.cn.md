# Remote-Only 完整流程

> 英文版见 [complete-flow.md](complete-flow.md)。

1. 用户在远端服务器调用 `$remote-harness` 或 `/remote-harness`。
2. skill 返回本机运行的 `simple-bootstrap.sh --mode reverse` 命令。
3. 本地向导询问远端 SSH target、本机项目、远端挂载点和审批模式。
4. 远端服务器创建每会话 SSH key 和会话级 `rlocal` config。
5. 本地 bootstrap 将 `project-host-gateway.sh` 和 `run-on-project-host.sh` 安装到
   `~/.remote-harness/bin`。
6. 本机 `authorized_keys` 把会话 key 绑定到 forced gateway；若存在同 key 的无限制授权则拒绝。
7. 本机向远端服务器建立 `RemoteForward <port> 127.0.0.1:22`。
8. 本地 bootstrap 为 gateway 会话登记物理项目根。
9. 远端服务器调用 `remote-harness-health` 验证 gateway，然后 SSHFS 挂载本机项目。
10. `inject-rule.sh` 安装 Claude/Codex hook 或 opencode 会话 plugin，以及远端 `rh-run`。
11. opencode 会话会预加载 plugin，并要求 readiness marker；失败时中止启动。
12. 所选 Agent 通过 `ssh -tt` 在远端服务器启动。
13. 文件工具使用 SSHFS；Bash 使用 `remote-harness-exec`，在映射后的本机项目 cwd 执行。
14. Agent/Spawn 工具创建远端 subagent，不会导向本机。
15. 清理移除挂载、远端 key、临时授权、gateway 登记、hook 和临时 config。

forward/本机 Agent 流程已禁用；兼容入口在执行工作前返回错误。

SFTP 是账号级访问，并没有 chroot 到登记项目。绝对的项目文件边界和禁止本机 Agent 边界需要独立、
受限的本机 OS 账号。
