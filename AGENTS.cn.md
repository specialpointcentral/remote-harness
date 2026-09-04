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
- `scripts/project-host-gateway.sh`：只接受 SFTP、health、exec 的 forced SSH command。
- `scripts/route-command.py`：Claude/Codex hook 策略和 cwd 映射。
- `scripts/inject-rule.sh`：同时生成会话级 opencode `tool.execute.before` plugin。
- `scripts/run-on-project-host.sh`：校验后的本机项目命令 dispatcher。
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
- gateway 只接受标准 SFTP、`remote-harness-health` 和
  `remote-harness-exec <root-b64> <cwd-b64> <command-b64>`。
- 每次 exec 的项目根必须与本机会话登记的物理根一致。
- hook 和 dispatcher 都拒绝直接在本机启动 `claude`、`codex`、`opencode`；清除常见 AI 凭据，
  并在本机命令 PATH 中屏蔽这些二进制。
- 任意项目 shell 是图灵完备的；绝对隔离需要无 AI 凭据和 Agent 安装的独立本机 OS 账号。

## Claude 多 Agent

- 支持继承 settings hook 的普通、具名和嵌套 subagent。
- 关闭 Agent Teams 和 Claude worktree 创建。
- 隔离并行时使用多个本机 Git worktree 和多个 reverse harness 会话；所有 Claude 进程仍在远端，
  可通过 cross-session messaging 协调。

## 不变量

1. 所有拼入远程命令的值必须正确 shell quoting；绝不 `eval` 用户 SSH 输入。
2. 会话 SSH config 和可变 host-key 状态位于 `~/.remote-harness/.sessions`。
3. `~/.ssh` 下只允许修改带标签的 forced-gateway `authorized_keys` 块。
4. 清理必须移除挂载、远端会话 key、gateway 登记、授权、hook 和临时 SSH 状态。
5. 被程序解析的脚本 stdout 保持 `KEY=VALUE`。
6. 中英文 Markdown 必须同步。

## 验证

```bash
bash -n manage.sh tests/regression.sh scripts/*.sh
python3 -m py_compile scripts/route-command.py tests/codex_tui_e2e.py
bash tests/regression.sh
git diff --check
```

完整远端服务器到本机项目的 SSHFS 流程仍需人工集成测试。未经用户要求不得 commit/push；只推送
授权 fork，并使用 GitHub noreply 身份。
