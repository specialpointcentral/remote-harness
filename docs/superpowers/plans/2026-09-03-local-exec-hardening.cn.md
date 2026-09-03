# 本机执行加固实施计划

本计划对应英文主计划 `2026-09-03-local-exec-hardening.md`。目标是在不改变现有 reverse/forward
与 SSHFS 文件流的前提下，通过会话级 `PreToolUse` hook 将所有 Bash 命令强制转发到项目主机。

实施顺序：先为命令改写、cwd 映射、挂载点外拒绝和失败关闭增加失败测试；再实现 Python hook、
SSH runner 与项目主机 dispatcher；随后接入 Claude/Codex 会话配置；最后同步中英文文档、增加 CI，
并运行完整回归、语法、skill 和 diff 检查后提交推送。
