# 在 Orca 原生聊天中使用 Claude

Codex 请参阅[原生 Codex 设置](codex-native.cn.md)。本页适用于 Claude。

在项目主机运行反向 bootstrap。项目文件保留在项目主机，经过路由的 Bash 命令由项目主机上的强制
SSH 网关执行。Agent 主机运行 Orca Server 和 Claude Code。Claude 通过 SSHFS 挂载读写文件，
经过路由的 Git 和 ripgrep 扫描也在项目主机执行。

## 配置 Agent 主机

将当前版本的 Remote Harness 脚本安装到 `$RH_HOME`（默认 `~/.remote-harness`）。此适配要求
Python **3.8+** 和 Claude Code **2.1.295+**，已验证的 Orca Server 版本为 **1.4.251** 和
**1.4.254**。更新的 1.4 补丁版本（例如 Orca 自动更新安装的版本）会被接受，并在启动器中显示警告。
其他版本的 Orca Server 会在创建工作区或聊天之前被拒绝，提示中会写明当前运行的版本。启动 Orca Server，将手机或桌面客户端与该服务器配对。Orca Server、Claude 和 Harness 的
SSH 登录必须使用同一个 Unix 账号。Claude 必须能在 Orca Server 的运行环境中认证。参见
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

Claude Code 在所配置路径下自动更新时，正在运行的 Harness 聊天不受影响。若将 `"claude"` 改为
其他可执行文件，需要重新启动 Harness。

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
项目主机与 Agent 主机的连接断开时，会话同样结束；启动器会说明，下次启动时可以继续该聊天。
项目主机上的 `~/.remote-harness/launches.log` 记录了每次启动的结束原因。
启动器退出时会尝试关闭 Orca 聊天并归档工作区。已结束的聊天没有工具，除非之后的启动按下文所述继续它。
保留 `$RH_HOME` 下私有的 `.orca-identities` 记录和 `.orca-mounts` 保留目录。它们把每个聊天
绑定到自己的挂载路径，已结束的聊天因此无法使用其他启动的路由。

启动器运行期间如果 Orca Server 重启（例如自动更新），桥接进程最多等待两分钟，并对重启后的
服务器重新执行启动时的检查。版本受支持时，聊天和 lease 保持不变；其他版本会结束会话。
在重启后的服务器重新列出聊天标签页之前（通常在已配对设备重新连接后），关闭标签页不会结束
会话，请改为归档工作区或按 Ctrl-C。

除非继续一个已结束的聊天，每次启动都会创建新聊天。在启动器运行期间，可一直使用该聊天。Claude 普通子 Agent 继承会话 hooks。
聊天会阻止直接运行 Orca 管理命令及调用 Orca 管理 MCP 工具。清空上下文、分叉或回退等会改变 Claude 会话 ID 的动作超出该已登记会话的范围。Orca 自己的工作区终端、
Git 界面和工作区脚本运行在 Agent 主机。需要在项目主机运行命令时，请在 Claude 聊天中执行。

已配置的 Claude 包装器会在启动 Claude 前，拒绝通过 **＋** 在 Harness 工作区及其子目录中误开的
普通聊天。请使用启动器创建的聊天，或重新启动另一个 Harness 会话。其他项目中的普通聊天仍可使用。
**＋** 按钮本身仍可点击，因此可能出现额外的失败标签页。如果同时启用 Claude 和 Codex，需分别配置
两个 provider 的 Harness 包装器；每个包装器保护对应 provider 的启动。

## 继续已结束的聊天

同一项目、同一 Agent 之后的启动可以继续启动器已退出的聊天。挂载项目前，启动器显示一个菜单，按时间
倒序列出该项目已结束的聊天，以及最近活动时间和你的最后一条消息。菜单默认停在“新建会话”，用上下键
选择，回车确认。所选对话带着完整历史，在原挂载路径下继续，使用新启动的路由、hooks、lease 和审批
模式。Orca 仍保留该聊天时，会重新打开它。

Orca 已没有某个 Claude 聊天时（例如其文件夹工作区已被删除），会在同一挂载路径的文件夹工作区中新建
聊天，接着原 Claude 对话继续，Orca 根据 Claude 的对话记录显示之前的内容。Codex 聊天只能在 Orca
仍保留它时继续。Harness 把 Orca Codex 聊天的对话（Codex 线程和 rollout 记录）保存在会话之外的
`$RH_HOME/.orca-codex-chats/<chat>.state`，清理不会删除；Codex 登录凭据的副本仍只在会话中。
删除该目录即可丢弃这段对话。

只有项目主机终端能选择聊天。已结束的聊天不会自行接入任何启动，Orca 客户端也无法选择。若不想
出现菜单，可把 `RH_RESUME_CHAT` 设为菜单中的名称，例如 `RH_RESUME_CHAT=rev.Ab12Cd`。
`RH_RESUME=0`、`--yes` 或不支持光标控制的终端（`TERM=dumb`）不会提供续接。之前的启动器退出且
清理完成后，聊天才会出现在菜单中。在此之前在该聊天中发消息，会提示 Harness 会话已结束。

旧版 Harness 创建的 Claude 聊天没有项目记录。它们会出现在每个项目的菜单中，并标注“未记录项目”，
请只在原项目中继续。继续一次后会记录项目。旧版创建的 Codex 聊天无法继续：清理已删除了它们的对话。

## 在 Orca 和终端之间切换

同一项目的 Claude 对话可以在 Orca 聊天和终端启动（不加 `--ui`）之间双向切换：

- 终端启动会在同样的菜单中列出该项目已结束的 Orca Claude 聊天。所选聊天的对话在终端中继续，
  仍使用该聊天的挂载路径（`claude --resume <id>`），所以历史里的路径依然有效。该启动结束前，
  其他启动不会列出这个聊天，Orca 也无法运行它。之后的 Orca 启动会重新打开该聊天，Claude 也会
  带着终端里的对话继续，但 Orca 自己的聊天界面可能不显示终端里的那部分。
- Orca 启动的菜单还会列出该项目终端启动最近结束的对话（最多五个），标注“终端对话”。所选对话
  在新的 Orca 聊天中继续，并显示之前的历史。Orca 只恢复记录在该聊天自身目录下的对话，所以
  Harness 给新聊天一份副本：换用新的会话 ID，工作目录中终端挂载点的路径改为该聊天的挂载点；
  原终端对话保持不变。这份副本就是该项目的一个 Orca 聊天，之后的 Orca 和终端启动都按 Orca 聊天
  列出它。原终端对话要在终端里有了新的进展才会再次列出。只有没有任何启动在使用项目的终端挂载点时，
  才会列出终端对话，因为运行中的启动可能还在写入。

在 Orca 启动中，`RH_RESUME_CHAT` 也接受终端对话的 ID。终端启动把项目挂载在
`<RH_HOME>/mounts/<目录名>`，所以目录名相同的项目会共用这些对话。Codex 对话不能切换。

Orca 聊天还与该项目的终端启动共用 Claude 的自动记忆：Harness 把 `autoMemoryDirectory` 指向
终端挂载点的记忆目录 `~/.claude/projects/<终端挂载路径>/memory/`。你自己或托管的 Claude 设置中
已有 `autoMemoryDirectory` 时，以该设置为准。

## 冒烟测试

用一个临时项目，请 Orca 聊天里的 Claude 创建文件，并运行打印 `pwd` 和 `hostname` 的命令。
在聊天中批准 Bash 调用，再从项目主机确认文件和命令结果。关闭手机 App 后重新打开同一聊天发送下一条消息。
然后关闭聊天标签页，确认项目主机的启动器完成清理。可在另一个会话中测试归档工作区，
或在手机断开时按 Ctrl-C 结束会话。最后再次启动该项目，选择已结束的聊天，确认它带着历史继续，
并能运行经过路由的命令。
