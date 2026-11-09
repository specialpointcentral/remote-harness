# 在 Orca 原生聊天中使用 Claude

Codex 请参阅[原生 Codex 设置](codex-native.cn.md)。本页适用于 Claude。

在项目主机运行反向 bootstrap。项目文件保留在项目主机，经过路由的 Bash 命令由项目主机上的强制
SSH 网关执行。Agent 主机运行 Orca Server 和 Claude Code。Claude 通过 SSHFS 挂载读写文件，
经过路由的 Git 和 ripgrep 扫描也在项目主机执行。

## 配置 Agent 主机

将当前版本的 Remote Harness 脚本安装到 `$RH_HOME`（默认 `~/.remote-harness`）。此适配要求
Orca Server **1.4.251**、Python **3.8+** 和 Claude Code **2.1.295+**。启动 Orca Server，
将手机或桌面客户端与该服务器配对。Orca Server、Claude 和 Harness 的 SSH 登录必须使用同一个
Unix 账号。Claude 必须能在 Orca Server 的运行环境中认证。参见
[Orca Server 安装与配对](https://www.onorca.dev/docs/remote-servers)。

在 Agent 主机创建包装器配置，将示例中的路径替换为实际的 Claude Code 可执行文件。

```bash
rh="${RH_HOME:-$HOME/.remote-harness}"
(umask 077
 mkdir -p "$rh/orca"
 cat > "$rh/orca/claude.json" <<'JSON'
{"claude": "/absolute/path/to/claude"}
JSON
 chmod 700 "$rh/orca"
 chmod 600 "$rh/orca/claude.json")
printf '%s\n' "$rh/scripts/orca-claude.py"
```

在**服务器的** Orca 设置中，将 Claude **Command** 设为上面打印出的包装器绝对路径。使用 Harness
会话（包括重新打开旧记录）期间保持该设置。普通会话仍由包装器将 Orca 的参数原样传给配置的 Claude
程序。自定义认证沿用 Orca 的 Claude 账号或运行环境。对于 Harness 会话，如果保存的 Claude
Arguments 覆盖会话 ID、hooks、系统提示词或执行模式，启动可能被拒绝。

若 Orca Server 使用非默认 profile，在 `claude.json` 添加 `"profile"`，值为 profile 的绝对路径。
桥接进程通过该 profile 的认证 Unix socket 连接服务器。Linux 默认目录为
`${XDG_CONFIG_HOME:-$HOME/.config}/orca`，macOS 默认为 `~/Library/Application Support/orca`。
可添加 `"model"` 指定 Claude 模型。默认使用以 `$RH_HOME/.orca-mounts` 为目录的本机 Orca
**Remote Harness** 分组，缺失时自动创建。分组必须带有目录路径，否则 Orca 不会将其中的原生文件夹
工作区列入远程工作区列表。旧版本创建的无目录分组会保留，新会话使用带目录的分组。
如需选择其他本机目录分组，请在 `"projectGroupId"` 填入对应分组 ID。

## 启动与退出

如果项目主机已安装 Harness，可执行以下命令。如果只在远端安装，在
[拉取并运行脚本的命令](../reference/reverse.cn.md) 后同样追加 `--ui orca`。

```bash
bash "${RH_HOME:-$HOME/.remote-harness}/scripts/simple-bootstrap.sh" \
  --mode reverse --launch claude --ui orca
```

在向导里选择 Agent 主机和项目。Orca 模式为每次启动分配独立的远端挂载点和文件夹工作区，
不接受 `--remote-mountpoint` 或 `--setup-only`。在已配对设备的 Orca 中打开
**Remote Harness · 项目名** 下的 **Claude Chat** 标签页，并发送第一条消息。Normal 模式通过
Orca 原生卡片审批。Auto 使用 Claude 的自动审核，缺失时退回 Normal。YOLO 需要显式选择。

项目主机需保持唤醒，启动器需持续运行。关闭手机 App 或完成一轮对话不会释放通道。关闭聊天标签页、
归档对应文件夹工作区，或在项目主机终端按 Ctrl-C，即可结束会话。Harness 在清理前撤销 lease。
启动器退出时会尝试关闭 Orca 聊天并归档工作区。旧对话记录可能仍可查看，如需继续使用工具，请重新启动。
保留 `$RH_HOME` 下私有的 `.orca-identities` 记录和 `.orca-mounts` 保留目录，防止旧会话
身份和挂载路径被再次使用。

每次启动都会创建一个新聊天。在启动器运行期间，可继续使用同一聊天。Claude 普通子 Agent 继承会话 hooks。
聊天会阻止直接运行 Orca 管理命令及调用 Orca 管理 MCP 工具。清空上下文、分叉或回退等会改变 Claude 会话 ID 的动作超出该已登记会话的范围。Orca 自己的工作区终端、
Git 界面和工作区脚本运行在 Agent 主机。需要在项目主机运行命令时，请在 Claude 聊天中执行。

已配置的 Claude 包装器会在启动 Claude 前，拒绝通过 **＋** 在 Harness 工作区及其子目录中误开的
普通聊天。请使用启动器创建的聊天，或重新启动另一个 Harness 会话。其他项目中的普通聊天仍可使用。
**＋** 按钮本身仍可点击，因此可能出现额外的失败标签页。如果同时启用 Claude 和 Codex，需分别配置
两个 provider 的 Harness 包装器；每个包装器保护对应 provider 的启动。

## 冒烟测试

用一个临时项目，请 Orca 聊天里的 Claude 创建文件，并运行打印 `pwd` 和 `hostname` 的命令。
在聊天中批准 Bash 调用，再从项目主机确认文件和命令结果。关闭手机 App 后重新打开同一聊天发送下一条消息。
然后关闭聊天标签页，确认项目主机的启动器完成清理。可在另一个会话中测试归档工作区，
或在手机断开时按 Ctrl-C 结束会话。
