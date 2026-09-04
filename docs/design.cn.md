> 中文版。英文原版见 [design.md](design.md)（以英文版为准）。

# remote-harness — 设计

面向用户的文档见 [`../README.md`](../README.md)，运行时技能规格见 [`../SKILL.md`](../SKILL.md)，
开发指南见 [`../AGENTS.md`](../AGENTS.md)。

## 1. 问题

remote-harness 连接两台机器：

- **A**：编程 Agent 运行所在机器。
- **P**：项目和开发环境所在机器。

它用 sshfs 把 P 的项目挂载到 A，然后在挂载目录启动选定 Agent。Claude 和 Codex 获得会话级 hook，
将每个 Bash 调用改写到 P；opencode 保留提示词 SSH 路由。

## 2. 两个方向

- **Simple reverse**：A 是远端盒子，P 是用户笔记本。笔记本向盒子打开反向 SSH 隧道，盒子通过
  `rlocal` 回连笔记本。
- **Simple forward**：A 是本地机器，P 是 SSH 服务器。本地机器直接挂载服务器项目。
- **无法判断**：输出命令省略 `--mode`；`simple-dispatch.sh` 在本地询问并缓存模式。

所有情况的公开入口都是 `scripts/simple-bootstrap.sh`。命令总是在本地运行；脚本本身可以来自本地安装，
也可以从安装了 skill 的远端机器读取。

## 3. 分层

```text
SKILL.md
  -> simple-bootstrap.sh
      -> simple-dispatch.sh
          -> simple-laptop-setup.sh  -> laptop-setup.sh
          -> simple-local-setup.sh   -> local-setup.sh
              -> setup-tunnel/check-tunnel/mount-project/inject-rule
```

`_common.sh` 是被 source 的公共库，提供引用、提示、`parse_via` 和 `write_managed_alias`。辅助脚本在
stdout 输出可解析的 `KEY=VALUE`，在 stderr 输出人工提示。

## 4. SSH Config 模型

当前 simple 流程只使用**会话级 SSH config**：

| 流程 | Alias | Config 位置 | 作用 |
|---|---|---|---|
| reverse，笔记本 -> 盒子 | `<host>-remote-harness` | 本地 `~/.remote-harness/.sessions/.../ssh_config` | 携带 `RemoteForward <port> 127.0.0.1:22` |
| reverse，盒子 -> 笔记本 | `rlocal` | 远端 `~/.remote-harness/.sessions/.../ssh_config` | 通过盒子回环端口连回笔记本 |
| forward，本地 -> 服务器 | 已有 Host alias 或 `<host>-dev` | 本地 `~/.remote-harness/.sessions/.../ssh_config` | 给 sshfs 和服务器命令使用的短 alias，并隔离 SSH 运行期文件 |

simple 流程不得创建、编辑、备份、追加或清理本地或远端 `~/.ssh/config`、`known_hosts`、SSH key、
`config.rh-bak.*` 或 `known_hosts_<alias>`。临时 SSH config 和 `known_hosts` 都位于
`~/.remote-harness/.sessions/...`；生成的 config 关闭 OpenSSH multiplexing。

唯一有意的 `~/.ssh` 修改是 simple reverse 中笔记本侧的 `authorized_keys`：当远端提供
remote-harness 公钥时，`laptop-setup.sh` 会先检测本机是否已有匹配且有效的授权；若没有，才追加带
`remote-harness:reverse-auth:<tag>` 标签、并用 `from="127.0.0.1,::1"` 限制为回环来源的托管块。
`~/.remote-harness/.sessions/authorized-keys/...` 下的引用 token 用来避免一个会话退出时删除仍被
其他会话使用的授权。除此之外，`~/.ssh` 中已有历史文件都属于用户，除非用户明确要求，否则不修改。

Claude/Codex 获得会话级 `PreToolUse` hook 和 `bin/rh-run`。opencode 继续通过会话级 `bin/ssh`
wrapper 使用 `ssh rlocal ...` / `ssh <server-alias> ...` 短命令。

## 5. 隐私边界

Agent 返回命令，不在聊天中收集具体 SSH target、本地路径、挂载路径或端口。这些由本地终端向导收集。
simple reverse 中，Agent 可以只基于服务器侧事实给出远端 SSH target 默认建议值。若使用
`SSH_CONNECTION`，只能使用第 3/4 字段（`server-ip`、`server-port`）；第 1/2 字段是本地客户端数据。

## 6. 共享服务器容量

remote-harness 的 simple 流程会在客户端侧使用会话级 SSH config、临时 `known_hosts`、
`sshfs reconnect`、keepalive 和退出清理，但这些不能替代服务器端容量配置。多人共享远程开发盒子、
大量长期 Agent 会话或大量 SSHFS 挂载时，运维侧应按
[`ssh-sshfs-long-lived-connections.cn.md`](ssh-sshfs-long-lived-connections.cn.md) 评估
`sshd` 的 `MaxStartups` / `MaxSessions` / `ClientAlive*`、systemd/PAM `nofile` 和 TCP 队列。

该优化不是单个小会话的硬性前置条件；它是共享服务器长期稳定性的运行环境要求。

## 7. 规则与 hook 注入

`inject-rule.sh` 是会话级且方向无关。它写入 `$RH_HOME/.sessions/<key>`，永不写入被挂载仓库。
Claude/Codex 会创建 `PreToolUse` hook 和 `bin/rh-run`。hook 保留工具输入，把 cwd 映射为挂载点
相对目录，并只替换 Bash 命令。runner 通过 SSH 传输编码命令，在 P 的登录 shell 中执行，并设置
`GIT_OPTIONAL_LOCKS=0`。

规则、hook、runner、Python 或会话 SSH config 不可用时，启动立即中止。hook 拒绝或 SSH 失败时，
hook 成功加载后，handler 错误返回拒绝，SSH 失败不会回退到 A 执行。客户端 hook 框架仍是防护机制，
不是完整隔离边界。

各 Agent 通道：

- Claude：`--append-system-prompt-file <rule> --settings <会话 settings>`。
- Codex：会话 `developer_instructions`、内联 `hooks.PreToolUse`，并显式信任生成的 hook；非 yolo
  仍启用 workspace-write 网络和会话 writable roots。
- opencode：`OPENCODE_CONFIG=<session config>`，继续使用提示词 SSH 路由。

hook 是命令路由防护，不是文件系统隔离。SSHFS 和反向 SSH key 仍要求 A 是可信主机，并可访问所选
项目主机账号。

### Claude 多 Agent 边界

Claude settings hooks 会在普通和嵌套 subagent 内运行，因此这些 agent 的 Bash 共用同一个 runner
和 cwd 映射。具名 subagents 可以通过 `SendMessage` 通信；接收方仍使用自己的工具和路由 hook。同一
会话内的 subagents 共用一个挂载点，并行写入必须拥有互不重叠的文件范围。

严格会话关闭实验性 Agent Teams 并阻止 worktree 创建。teammates 是独立会话，官方没有保证 lead 的
临时 `--settings` 被继承；Claude worktree 也跨越 Agent 主机与项目主机路径边界。隔离并行工作应为
每个 agent 准备一个项目主机 Git worktree 和一个 remote-harness 会话，再用 cross-session messaging
协调。

## 8. 不变量

1. `simple-bootstrap.sh` 是唯一公开 simple 入口。
2. 输出命令必须紧凑但可复制：少量短行，不输出超长单行 shell 块。
3. 调用中已明确 YOLO 时，传 `--yolo`，不得再二次询问。
4. simple 流程不扫描远端服务器发现项目；在本地询问路径，并把确认值缓存为默认值。
5. `laptop-setup.sh` 被 fetch 到无本地安装的笔记本时仍必须独立运行。
6. 所有拼进远程命令的值都用 `sq()` 做 shell 引用。
7. 会话清理会移除挂载、注入规则、临时 config，并在没有其它挂载需要时断开隧道。
