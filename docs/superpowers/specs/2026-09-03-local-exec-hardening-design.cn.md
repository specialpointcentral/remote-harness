# 本机执行加固设计

## 目标

Claude Code 或 Codex 继续运行在 Agent 主机，并通过 SSHFS 做文件操作；所有 shell 命令都转发到
项目所在主机执行。路由失败时必须阻止命令，不能回退到 Agent 主机执行。

## 架构

`inject-rule.sh` 创建会话级 runner 和 `PreToolUse` hook。hook 读取工具事件，把调用目录从 SSHFS
挂载路径映射到项目主机路径，保留原始工具输入，仅替换命令字段。会话 runner 将编码后的命令交给
`run-on-project-host.sh`；后者通过 SSH 传输一个小型 POSIX dispatcher，并在项目主机的登录 shell
中执行命令。

SSHFS 仍是文件传输层。读取、编辑、写入和 patch 工具继续操作挂载目录。所有 Bash 调用，包括
Git 和只读检查命令，都在项目主机执行。

## 强制规则

- 规则或 hook 创建失败时中止 Agent 启动。
- hook 调用目录不在已配置挂载点内时拒绝执行。
- 两端都拒绝非法相对路径。
- SSH 或项目主机失败作为命令失败返回；原始命令绝不在 Agent 主机执行。
- Codex 使用会话级内联 hook 配置并显式信任该生成 hook；Claude 使用会话级 settings 文件。

## 兼容性

严格路由要求 Agent 主机安装 `python3` 以处理 hook JSON。项目主机只需要 POSIX `sh`、base64
解码器及其正常登录 shell。现有 reverse/forward、会话级 SSH 配置、SSHFS 清理和用户自有 SSH
配置保持不变。

严格路由不支持交互 PTY 和任意端口转发。长期进程应使用非交互命令；如果服务运行在本机项目
主机，本机用户可直接访问。

## 测试

回归测试必须覆盖命令改写、cwd 映射、工具输入保留、挂载点外拒绝、非法路径拒绝、启动失败关闭，
以及 Claude/Codex hook 配置有效性。现有回归测试和 shell 语法检查继续保留。
