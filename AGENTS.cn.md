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
- `reference/`、`docs/`：英文 Markdown 必须有 `.cn.md` 对应版本。

## Simple Reverse 规则

- 所有公开命令都使用 `simple-bootstrap.sh --mode reverse`。
- 不得新增本机 Agent 或 forward 启动路径；兼容脚本必须在挂载、连接或启动前失败。
- 命令在本机运行，但 script may live remotely；fetch 形式必须紧凑但可复制，并取得全部 reverse helper。
- 具体 SSH target、本机路径、挂载点和审批只在本机终端收集。
- 若从 `SSH_CONNECTION` 推导默认值，第 1/2 字段是本地客户端数据，绝不能输出；只可使用第 3/4 字段。
- 用户明确要求 YOLO 后，不得再二次询问确认。
- `laptop-setup.sh` 必须可与下载到同目录的 sibling helper 独立运行。
- 主 Agent 只能通过 `ssh -tt <远端> ... <claude|codex|opencode>` 在远端启动。
- Claude/Codex/opencode Bash 导向本机；Agent/Spawn 工具仍在远端执行。

## Gateway 安全

- 每个远端会话目录生成独立 reverse key。
- 本机授权包含 `command="...project-host-gateway..."`、回环来源限制、no PTY、no port/X11/agent forwarding。
- 同一会话 key 若已出现在无限制用户授权行中，必须拒绝。
- gateway 只接受标准 SFTP、`remote-harness-health`、
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64> [watch]`，以及
  `remote-harness-tool <root-b64> <cwd-b64> <git|rg> <args>`；工具动词直接 exec 二进制
  （不经 shell、固定 PATH）。watch 模式的 exec 和工具动词让命令的 stdin 来自 `/dev/null`，并在 SSH
  通道关闭时终止命令的进程组和进程树。
- 每次 exec 的项目根必须与本机会话登记的物理根一致。
- hook 和 dispatcher 都拒绝直接在本机启动 `claude`、`codex`、`opencode`；清除常见 AI 凭据，
  并在本机命令 PATH 中屏蔽这些二进制。
- 任意项目 shell 是图灵完备的；绝对隔离需要无 AI 凭据和 Agent 安装的独立本机 OS 账号。

## 内部 Git 与搜索

- Agent 内部发起的 `git`/`rg` 调用不经过 PreToolUse hook。会话 PATH 垫片只把工作区扫描
  （`status`、`diff`、`log`、`ls-files`、`grep`、`rg` 等）路由到项目主机，路径发现命令
  （`rev-parse`、`config` 等）保留在远端执行。
- 挂载点之外、或指定了其它仓库/index 的调用，原样执行真实工具。
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
3. `~/.ssh` 下只允许修改带标签的 forced-gateway `authorized_keys` 块。
4. 清理必须移除挂载、远端会话 key、gateway 登记、授权、hook 和临时 SSH 状态。本地清理无法执行时，
   由远端会话 watcher 和下次启动的 GC 回收已死会话；它们只处理 `$RH_HOME/.sessions` 的直接子目录，
   且绝不卸载其它存活会话仍在使用的挂载。
5. 被程序解析的脚本 stdout 保持 `KEY=VALUE`。
6. 中英文 Markdown 必须同步。

## 验证

```bash
bash -n manage.sh tests/regression.sh scripts/*.sh
python3 -m py_compile scripts/route-command.py scripts/project-host-tool.py scripts/channel-guard.py tests/codex_tui_e2e.py
bash tests/regression.sh
git diff --check
```

完整远端服务器到本机项目的 SSHFS 流程仍需人工集成测试。未经用户要求不得 commit/push；只推送
授权 fork，并使用 GitHub noreply 身份。
