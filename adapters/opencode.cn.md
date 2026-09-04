> 中文版（参考）。功能性命令以英文版 [opencode.md](opencode.md) 为准。

---
description: 通过 remote-harness simple 工作流将此 Agent 连接到另一台机器上的项目
---

运行 **remote-harness** simple 工作流。

读取 `~/.remote-harness/SKILL.md` 并立即返回 reverse bootstrap 命令。不要在聊天中询问 SSH target、路径、端口或命名空间；这些信息会由命令在用户本地终端里提示输入。remote-only 模式是强制要求：opencode 及所有子 Agent 都留在远端服务器。若用户要求在本机运行 Agent，应说明维护 fork 会拒绝该拓扑。
setup 脚本使用 `~/.remote-harness` 下的会话级 SSH config 和 wrapper。只有 reverse 模式下
`authorized_keys` 临时 forced-command 托管块需要提到 `~/.ssh` 修改；不要暗示会编辑 config、known_hosts 或用户管理的 SSH key。

因为这是 opencode 适配入口，输出命令必须使用：

```bash
--launch opencode
```

如果用户要求 yolo / bypass approvals，则追加 `--yolo`。
