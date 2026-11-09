# 在 Paseo 原生聊天中使用 Claude

项目文件保存在项目主机上。项目主机负责运行反向 bootstrap 和执行路由后的 Bash 命令。
Agent 主机同时运行 Claude 和 Paseo。手机配对到该 Paseo 守护进程后，即可打开原生 Claude 会话。
文件工具通过 SSHFS 挂载读写，Claude 的 Git 和 ripgrep 扫描通过路由在项目主机上执行。

## 设置 Agent 主机

安装当前版本的 Harness 脚本，并准备 Paseo 守护进程 0.15.3、Node.js 22+、Python 3 和
Claude Code 2.1.295 或更新版本。Paseo 需要与 Harness 挂载使用同一账户，其 Claude provider
也需要完成认证。桥接进程会检查 Paseo 实际配置的 Claude 版本。守护进程设置和手机配对步骤见
[Paseo 连接指南](https://paseo.sh/docs/connectivity)。

如果桥接进程无法从 Paseo CLI 的安装位置找到客户端，在 Agent 主机安装固定版本。

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
npm install --prefix "$rh/paseo" @getpaseo/client@0.15.3
```

将 Claude provider 配置为使用 Harness 包装器。先在 Agent 主机保存真实 Claude 可执行文件路径
（替换示例路径）：

```bash
(umask 077
 mkdir -p "$rh/paseo"
 printf '%s\n' '{"claude":"/absolute/path/to/claude"}' > "$rh/paseo/claude.json")
```

在现有 Paseo 守护进程配置中，将 `agents.providers.claude.command` 设为单元素数组
`["/absolute/path/to/.remote-harness/scripts/paseo-claude.py"]`，保留其他 provider 和账号设置。
如果 provider 命令未使用该包装器，桥接进程会拒绝启动。其他项目中的普通聊天由包装器原样交给
已配置的 Claude 执行。

桥接进程默认使用 `ws://127.0.0.1:6767/ws`。若守护进程使用其他回环 WebSocket 地址，在
Agent 主机的 SSH 登录 shell 环境中导出 `RH_PASEO_URL`。若监听端需要密码，在同一环境中
导出 `RH_PASEO_PASSWORD`。可导出 `RH_PASEO_MODEL` 选择模型，留空时使用 provider 的默认模型。

Paseo 的 Claude provider 默认配置须留空 `options.settings` 和旧版的 `params.settings`。
Paseo 0.15.3 启动 Claude 时可能用这些值覆盖 Harness hook。桥接进程会在创建会话前检查。
使用 Harness 会话期间，包括查看或重新打开旧会话时，需维持兼容的 provider 命令和选项。

## 启动和结束

在项目主机的终端运行 bootstrap，在向导中选择 Agent 主机和项目目录。项目主机已安装 Harness
时使用以下命令。若 Harness 只安装在远端，在[下载命令](../reference/reverse.cn.md#bootstrap-形态)的
最后一行追加相同的 `--ui paseo` 参数。

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch claude --ui paseo
```

在 Paseo 中打开新出现的 **Remote Harness · 项目名** 会话，并从 Paseo 发送第一条消息。普通审批
在 Paseo 中显示。Auto 使用守护进程的 Claude 自动审批模式，不支持时退回普通审批。YOLO 仍需显式选择。

请保持项目主机唤醒、启动器持续运行。关闭手机应用或结束 Claude 的单次回复后，会话仍然可用。
在 Paseo 中归档或删除会话，或在项目主机终端按 Ctrl-C，都会结束会话并释放挂载和命令通道。
启动器退出时也会尝试在 Paseo 中归档会话。如果异常退出后旧会话仍可见，其工具调用授权已失效。
重新运行 bootstrap 可创建新会话。

Paseo 模式每次创建新会话。`RH_RESUME` 恢复提示适用于终端启动。普通 Claude subagent
继承会话 hook。Harness Claude 会话内禁用了 Paseo 管理工具。Paseo 自己的工作区终端、脚本和
版本控制操作在 Agent 主机运行。需要 Harness 路由时，请使用 Claude 聊天中的工具。

Harness 工作区只接受启动器创建的聊天。在该目录或子目录中手动创建普通聊天时，已配置的
Claude 包装器会在 Agent 启动前拒绝；其他项目仍可创建普通聊天。每个启用的 Claude
provider 都应配置对应包装器。界面可能仍会出现无法使用的标签页，关闭这个额外标签页并返回原聊天即可。
需要另一个 Harness 聊天时，在项目主机重新运行原启动命令。请保留 `$RH_HOME/.paseo-workspaces`，
这些路径预留记录在清理后仍保留，防止旧工作区悄悄变成普通聊天。正在运行的旧会话需重新启动，才能获得
新的路径预留与包装器绑定。

## 冒烟测试

使用临时项目。在 Paseo 中让 Claude 创建一个文件，再运行打印 `pwd` 和 `hostname` 的命令。
到项目主机核对文件和命令输出。重新打开手机应用，在同一会话中发送后续消息，再归档会话，确认本机
启动器完成清理。另起一个会话，按 Ctrl-C 结束；若之后取消归档，确认旧会话的工具调用会被阻止。

可用已安装的 Paseo server 和 client（均为 0.15.3）及真实 Claude CLI 运行回环集成测试。
测试启动临时守护进程和模拟模型端点，验证原生审批、命令路由，以及对冲突配置的拒绝。

```bash
RH_TEST_CLAUDE_CLI=/path/to/claude \
RH_TEST_PASEO_NODE_MODULES=/path/to/node_modules \
python3 tests/test_paseo.py -v
```
