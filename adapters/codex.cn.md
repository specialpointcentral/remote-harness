> 中文版（参考）。功能性提示以英文版 [codex.md](codex.md) 为准。

# Codex —— 以原生技能方式安装

Codex 不为这个流程暴露自定义 `/` 斜杠命令。`manage.sh codex` 会把 remote-harness 安装成 Codex
原生技能，位置为 `$CODEX_HOME/skills/remote-harness`（`CODEX_HOME` 默认为 `~/.codex`）。

调用方式：

```text
$remote-harness
```

Codex 应读取 `SKILL.md` 并立即返回 reverse bootstrap 命令。不要在聊天中询问 SSH target、路径、端口或命名空间；这些信息会由命令在用户本地终端里提示输入。remote-only 模式是强制要求：Codex 及所有 subagent 都留在远端服务器。若用户要求在本机运行 Codex，应说明维护 fork 会拒绝该拓扑。
setup 脚本使用 `~/.remote-harness` 下的会话级 SSH config 和 wrapper。只有 reverse 模式下
`authorized_keys` 临时 forced-command 托管块需要提到 `~/.ssh` 修改；不要暗示会编辑 config、known_hosts 或用户管理的 SSH key。

因为这是 Codex 适配入口，输出命令必须使用：

```bash
--launch codex
```

如果用户要求 yolo / bypass approvals，则追加 `--yolo`。

> 提示：`./manage.sh --dev codex` 会把 `$CODEX_HOME/skills/remote-harness` 软链到本仓库。
> 修改已安装技能后请重启 Codex；已运行的 TUI 可能保留旧的 skill 列表缓存。
