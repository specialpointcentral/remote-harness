> 中文版。英文原版见 [scripts.md](scripts.md)（以英文版为准）。

# 辅助脚本

所有脚本位于 `$RH/scripts/`，其中 `RH="${RH_HOME:-$HOME/.remote-harness}"`。运行时脚本在 stdout 输出
机器可解析的 `KEY=VALUE`，人工提示输出到 stderr。

```bash
RH="${RH_HOME:-$HOME/.remote-harness}"
[ -d "$RH/scripts" ] || echo "scripts missing - run: manage.sh"
```

## 公开 simple 入口

- `"$RH/scripts/simple-bootstrap.sh"`：公开统一 simple 入口，在本地机器运行。本地安装时直接移交给
  `simple-dispatch.sh`；从远端 skill 安装目录 pipe 到本地运行时，只使用 `--via`/`RH_VIA` 抓取当前 simple
  脚本到本地临时目录，再在本地移交。它会把脚本来源 `LAST_VIA` 写入本地
  `~/.remote-harness/simple-cache.env`。
- `"$RH/scripts/simple-dispatch.sh"`：本地模式分发器。接受 `--mode reverse|forward`；未传模式时在本地提示选择，
  第一次默认 reverse，把 `LAST_MODE` 缓存到 `~/.remote-harness/simple-mode-cache.env`，再移交给对应向导。
- `"$RH/scripts/suggest-via.sh"`：bootstrap 提示默认值的远端辅助脚本。它只能使用远端用户名、服务器地址和服务器
  SSH 端口。若读取 `SSH_CONNECTION`，只使用第 3/4 字段（`server-ip` / `server-port`），绝不输出本地/client 字段。

## 分模式向导

- `"$RH/scripts/simple-laptop-setup.sh"`：simple reverse 本地向导。在本地提示笔记本项目目录、可选远端挂载点和启动偏好。
  它使用固定会话别名 `rlocal`，让远端执行
  `setup-tunnel.sh --config <临时config> --namespace rlocal --alias rlocal --gen-key`，然后用确认后的参数调用
  `laptop-setup.sh`。它会缓存本地默认值，供下次运行使用。
- `"$RH/scripts/simple-local-setup.sh"`：simple forward 本地向导。在本地提示服务器 SSH target、服务器项目目录、
  可选本地挂载点和启动偏好，把确认后的默认值写入 `~/.remote-harness/simple-forward-cache.env`，然后调用
  `local-setup.sh`。

## 编排器

- `"$RH/scripts/laptop-setup.sh"`：reverse 编排器，在笔记本运行。它检查本地 sshd；当收到 remote-harness 公钥时，
  管理带标签的临时 `authorized_keys` 块；通过会话级 ssh config 建立反向隧道；在远端挂载笔记本项目；
  为 Claude/Codex 安装严格路由或为 opencode 注入 SSH 规则；远端启动 Agent；退出时清理挂载、规则、
  隧道状态、本地会话 config 和托管授权引用。
- `"$RH/scripts/local-setup.sh"`：forward 编排器，在本地 Agent 所在机器运行。它通过会话级 ssh config 解析服务器目标；
  将服务器项目 sshfs 挂载到本地；为 Claude/Codex 安装严格路由或为 opencode 注入 SSH 规则；在本地
  挂载目录启动 Agent；退出时卸载并删除会话 config。

## 共享运行时 helper

- `"$RH/scripts/setup-tunnel.sh"`：reverse helper，在远端盒子运行。它只把 `rlocal` alias 写入 `--config <绝对路径>`
  指定的会话级 config，输出选定端口和可选的生成公钥，并把生成的 remote-harness key 放在 `$RH_HOME/keys`。
  它永不写 `~/.ssh`。
- `"$RH/scripts/check-tunnel.sh"`：reverse helper，在远端盒子运行。它验证 reverse listener，并通过 `rlocal`
  做真实 SSH 登录测试。
- `"$RH/scripts/mount-project.sh"`：方向无关的 sshfs helper。它把 `<alias>:<remote-path>` 挂载到本地挂载点；
  默认拒绝非空目标（除非传 `--force`）；会重验陈旧挂载；支持 `--unmount`。
- `"$RH/scripts/inject-rule.sh"`：方向无关的会话规则/hook helper，在 Agent 启动所在机器运行。它在
  `$RH_HOME/.sessions/<key>` 下写会话级产物，并返回 Claude、Codex 或 opencode 的启动环境/参数。
  它永不写全局 Agent 配置，也永不写入已挂载仓库。
- `"$RH/scripts/route-command.py"`：Claude/Codex `PreToolUse` handler，保留工具输入，映射挂载点相对
  cwd，并把 Bash 替换为会话 runner。
- `"$RH/scripts/run-on-project-host.sh"`：通过 SSH 传输编码命令，在校验后的项目主机 cwd 和登录 shell
  中执行。
- `"$RH/scripts/_common.sh"`：setup 脚本共同 source 的库，提供输出辅助、安全 shell quoting、`parse_via`、
  会话级 ssh config 默认值和托管 Host block 写入。

## SSH 运行时边界

所有自动 SSH 运行时状态都留在 `~/.remote-harness`，绝不写 `~/.ssh/config`、`~/.ssh/known_hosts`
或生成用户 SSH key。会话 config 把 `UserKnownHostsFile` 指向 `~/.remote-harness/.sessions` 下的临时路径，
并关闭 OpenSSH multiplexing（`ControlMaster no`），避免 macOS/FUSE-T 下的 ControlPath socket 失败。
唯一允许的自动 `~/.ssh` 写入，是 reverse 模式为 remote-harness 公钥追加的带标签、仅限回环来源的
`authorized_keys` 块；它有引用计数，并在会话结束时清理。
