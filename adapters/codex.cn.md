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

会话把 `git`/`rg` 垫片目录放在 Agent PATH 最前面，并通过 `shell_environment_policy.set.PATH`
固定 Codex shell 子进程的 PATH。这些子进程禁用 login shell 和 shell profile 加载，避免垫片
被重新排序。项目命令仍通过 gateway 使用本机项目主机的 shell。普通和 YOLO 会话均使用这些设置。
启动前，注入器在与 Agent 启动器相同的远端登录交互 shell 环境中发现工具，包括 `~/.local/bin`
下安装的 CLI。

`rg` 垫片优先使用远端 PATH 中的 ripgrep，也支持独立 Codex 安装包里、解析后的 `bin/codex`
旁的 `codex-path/rg`。其他安装布局应在远端 PATH 中安装 ripgrep。PATH 垫片覆盖按名称查找
`git`/`rg` 的外部调用，无法拦截绝对可执行路径、进程内搜索或直接文件读取。内部调用不依赖
Bash hook；真实 Codex 内部调用的覆盖范围仍需手动集成验证。

> 提示：`./manage.sh --dev codex` 会把 `$CODEX_HOME/skills/remote-harness` 软链到本仓库。
> 修改已安装技能后请重启 Codex；已运行的 TUI 可能保留旧的 skill 列表缓存。
