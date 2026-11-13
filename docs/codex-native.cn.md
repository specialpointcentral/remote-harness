# 在 Paseo 和 Orca 中使用原生 Codex 聊天

反向启动器运行在项目主机。Agent 主机运行管理器，并为每个 Harness 会话启动独立的 Codex app server。
在已配对的管理器客户端中打开聊天。项目文件留在项目主机。

## Agent 主机设置

安装当前版本的 Harness 脚本。原生 Codex 已验证的版本为 **codex-cli 0.167.0**，且 Harness 的
SSH 登录环境需要 **Python 3.11+**。更新的 0.167 补丁版本会被接受，并在启动器中显示警告；其他版本
会被拒绝。使用 Paseo 守护进程 **0.15.3** 和 Node.js 22+，或 [Orca 指南](orca.cn.md)所述受支持的
Orca Server。管理器和 Harness 登录必须使用同一个 Unix 账号。安装客户端和配对的步骤见
[Paseo 指南](paseo.cn.md)或 [Orca 指南](orca.cn.md)。

在 Agent 主机的私有文件中配置 Codex 可执行文件。请替换示例中的绝对路径。

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
(umask 077
 cat > "$rh/codex.json" <<'JSON'
{"codex": "/absolute/path/to/codex"}
JSON
 chmod 600 "$rh/codex.json")
printf '%s\n' "$rh/scripts/native-codex.py"
```

- **Paseo**。把 Codex provider 的 command 设为只包含上述包装器绝对路径的数组。守护进程 JSON 配置
  中对应 `agents.providers.codex.command`。按 [Paseo 指南](paseo.cn.md)安装固定版本的 Paseo 客户端。
  可在 Harness SSH 登录环境设置 `RH_PASEO_MODEL`。
- **Orca**。把服务端 Codex **Command** 设为同一个包装器路径，Codex **Arguments** 留空。
  使用默认服务端 profile 和项目分组时，创建只含 `{}` 的私有 `$RH_HOME/orca/codex.json`。
  将 `orca` 目录权限设为 700，文件权限设为 600。可选的 `profile`、`projectGroupId` 和 `model`
  分别选择服务端 profile、本地项目分组和初始 Codex 模型，规则见 [Orca 指南](orca.cn.md)。分组
  必须带有目录路径，工作区才能出现在桌面客户端的远程工作区列表中。Harness 会检查该列表后再报告
  聊天就绪。

重新打开原生 Harness 聊天时也保留该包装器。管理器的普通聊天由包装器直接交给已配置的 Codex。
包装器使用管理器所选 Codex 账号（`CODEX_HOME`，默认 `~/.codex`）及 provider 环境。
它将模型、provider 设置和私有 `auth.json` 复制到会话专用的 Codex 目录。支持文件登录或 provider
环境凭据。包装器使用所配置或内置模型目录的私有副本，启用直接工具调用和原生 Multi-Agent V2，保留模型
ID、协作元数据及所配置的 provider。仅用系统钥匙串登录时，需要改用支持的凭据来源。会话私有文件内的
凭据刷新不会写回源账号。
并行启动或需要长期有效的凭据时，可在 provider 支持的情况下使用 API key 环境配置。

## 启动与审批

在项目主机执行常规的[反向启动命令](../reference/reverse.cn.md#bootstrap-形态)，并选择相应界面。

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch codex --ui paseo --approval normal
# 使用 Orca 时改为 --ui orca。
```

在已配对的应用中打开 Codex 聊天并发送首条消息。聊天通过 Harness 的私有 `remote_harness` MCP
工具执行 shell 命令。审批卡显示原命令和相对于项目的工作目录。`normal` 在应用内逐次询问命令和 MCP
写文件操作，`auto` 将这些操作交给 Codex 自动审核，明确选择 `yolo` 时跳过这些审批。所有模式下原生
文件编辑的沙箱都限制在工作区。模型提供 `apply_patch` 时可以直接使用。私有 `read_file` 和
`write_file` 也可读写挂载内的 UTF-8 文件。

命令通过已有的强制 SSH gateway 执行，使用空 stdin 和非交互通道。Harness 使用 Codex `execpolicy`
检查所选账号的 `rules/` 和 `/etc/codex/rules/`，检查对象为 gateway 识别的命令片段。
`forbidden` 规则在所有模式下阻止执行，`prompt` 规则在 YOLO 下阻止执行，`allow` 规则不会跳过
MCP 审批。该会话排除项目 Codex 配置、外部 MCP server、插件和可执行工具，并禁用内置 shell 和代码
执行工具。原生 Codex 子代理在 Agent 主机的同一个私有 app server 中运行。V2 的 `collaboration`
工具支持启动具名子代理、发送消息和后续任务、等待消息更新以及中断子代理的轮次。子代理沿用主会话的
挂载、路由工具和审批模式。在 normal 模式下，管理器在执行前展示子代理的原命令和工作目录。子代理
默认继承完整历史，也可以用 `fork_turns="none"` 从空白上下文开始。Codex 根据模型的协作元数据判断
子代理能否继续派生。不同工作区分别启动会话。

在 Orca 的 Harness 工作区中，请使用启动器创建的聊天。点击 **＋** 新建 Codex 聊天不会登记新的
Harness 连接：已配置的包装器会在启动 Codex 前拒绝该聊天，并提示返回已有聊天，或在项目主机重新
运行原来的 Harness 启动命令。Orca Server 1.4.251 和 1.4.254 都没有按工作区禁用 **＋** 的设置，
因此界面仍可能出现一个无法使用的聊天标签页，只需关闭这个额外标签页。保持已配置的包装器设置，
此保护才会生效。
Paseo 也会在 `$RH_HOME/.paseo-workspaces` 预留各个 Harness 工作区，Codex 包装器会拒绝在这些
目录中创建普通聊天，其他目录不受影响。清理后仍需保留这些记录。如果同时启用 Claude，按
[Paseo 指南](paseo.cn.md)或 [Orca 指南](orca.cn.md)配置其包装器，防止切换 provider 后绕过
工作区检查。已有 Paseo 会话需重新启动，才能获得路径预留。

## 断开与结束

保持项目主机和启动器运行。聊天空闲或手机断开不会结束 lease。在 Paseo 归档或删除 Agent，
在 Orca 关闭聊天或归档文件夹，或在项目主机终端按 Ctrl-C，均可结束会话。桥接 lease 失效后，
私有 Codex app server 停止，路由工具拒绝继续调用。再次启动会创建新聊天。应用可能保留旧聊天
历史。请保留 Orca 的挂载和身份预留记录。管理器终端、工作区脚本和 Git 界面仍运行在 Agent 主机。
Orca Server 重启时的处理见 [Orca 指南](orca.cn.md#启动与退出)。

可用临时项目做冒烟测试。在聊天中读取并修改一个文件，再审批一个打印 `pwd` 和 `hostname` 的路由
命令。确认文件和命令结果都来自项目主机。启动器仍运行时关闭并重开应用，然后发送后续消息。
结束会话后，确认旧聊天不能执行新命令。

维护者可用独立的本地回环模型测试 app server 和两套真实管理器。管理器测试需要受支持版本的 Orca CLI，
以及包含 `@getpaseo/client@0.15.3` 和 `@getpaseo/server@0.15.3` 的 `node_modules` 目录。
两条测试命令均需要 `zstd`。`tests/verify-orca-version.sh` 可从 orcad 包构建 Orca CLI 并运行 Orca 测试。

```bash
RH_TEST_CODEX_CLI=/absolute/path/to/codex python3 tests/test_native_codex.py -v
RH_TEST_CODEX_CLI=/absolute/path/to/codex RH_TEST_ORCA_CLI=/absolute/path/to/orca \
  RH_TEST_PASEO_NODE_MODULES=/absolute/path/to/node_modules \
  python3 tests/test_native_codex_managers.py -v
```
