> 中文版。英文版见 [ssh-sshfs-long-lived-connections.md](ssh-sshfs-long-lived-connections.md)（以英文版为准）。

# SSH / SSHFS 长连接服务器优化建议

更新时间：2026-06-27

本文面向运行 remote-harness 的共享远程开发服务器。所有编码 Agent 都运行在远端服务器；服务器通过
反向隧道使用 `ssh`、`sftp` 和 `sshfs` 挂载每位用户的本机项目。若一台服务器服务多个用户、多个长期
Agent 会话或大量 SSHFS 挂载，建议对服务器 `sshd` 和系统资源上限做容量优化。

本文是通用运维模板，不记录具体服务器 IP、主机名或账号。

## remote-harness 已经做的客户端侧处理

remote-harness 的脚本已经内置以下行为：

- 所有自动 SSH runtime 文件放在 `~/.remote-harness/.sessions/...`，不写 `~/.ssh/config` 或
  `~/.ssh/known_hosts`。
- 生成的会话级 SSH config 关闭 OpenSSH multiplexing（`ControlMaster no`），避免 macOS/FUSE-T 下
  `ControlPath` socket 路径长度和复用连接卡死问题。
- `mount-project.sh` 使用 `sshfs` 的 `reconnect`、`ServerAliveInterval` 和 `ServerAliveCountMax`。
- `mount-project.sh` 不只相信 `sshfs` 退出码，还会确认挂载点真的 live；这能规避部分 FUSE-T
  “返回成功但实际未挂载”的场景。
- reverse 模式会在退出时清理远端挂载、会话规则、临时 SSH config 和本地托管授权引用。

这些处理解决的是会话级可靠性。服务器端仍需要能承受大量新连接、长期连接和文件描述符消耗。

## 适用场景

建议在以下场景使用本文配置：

- 多用户共用同一台远程开发服务器。
- 大量 Agent 会话同时建立 SSH / SSHFS 连接。
- SSHFS 挂载会保持数小时甚至数天。
- 偶发网络抖动后，希望服务端能及时回收半死 SSH 会话。
- 服务器默认 `nofile=1024`，在多用户 SSHFS/SFTP 场景下过低。

如果只是单用户、少量短连接，默认 OpenSSH 配置通常已经足够。

## 推荐 sshd 配置

建议创建 drop-in 文件：

```text
/etc/ssh/sshd_config.d/20-remote-harness-capacity.conf
```

推荐内容：

```text
MaxStartups 200:30:500
MaxSessions 100
ClientAliveInterval 60
ClientAliveCountMax 5
LoginGraceTime 60
TCPKeepAlive yes
UseDNS no
```

应用前检查语法：

```bash
sudo /usr/sbin/sshd -t
```

语法通过后 reload：

```bash
sudo systemctl reload ssh.service
```

### 参数含义

`MaxStartups 200:30:500`

控制尚未完成认证的 SSH 连接数量，不是已登录用户总数：

- 未认证连接数小于等于 `200` 时，不因 `MaxStartups` 主动丢弃新连接。
- 超过 `200` 后开始概率拒绝，起始拒绝概率 `30%`。
- 达到 `500` 后拒绝全部新的未认证连接。

这项配置主要保护握手和认证阶段，适合大量用户同时连接、批量 SSHFS 挂载或自动化任务并发登录。

`MaxSessions 100`

控制单条已认证 SSH TCP 连接中最多可打开多少个 session/channel。remote-harness 生成的会话级 config
默认关闭 multiplexing，所以通常不会把多个操作压进同一条 TCP 连接；但用户自己的 Host alias 或其他工具可能
启用 ControlMaster，这时该参数仍有价值。

`ClientAliveInterval 60` 与 `ClientAliveCountMax 5`

sshd 每 60 秒向客户端发送一次 SSH 协议层 keepalive；连续 5 次无响应后断开连接。实际效果是：

- 真正断线或客户端消失的会话约 5 分钟后被服务端回收。
- 对 1 到 2 分钟的短暂网络抖动更宽容。
- 长期 SSHFS 会话更不容易积累半死连接。

`LoginGraceTime 60`

客户端建立 TCP 连接后，需要在 60 秒内完成认证，否则服务端关闭连接。它可以避免大量未认证连接长期占用
`MaxStartups` 配额。

`UseDNS no`

关闭登录阶段反向 DNS 查询，避免 DNS 慢或异常拖慢 SSH 登录。

## systemd 文件描述符上限

建议创建：

```text
/etc/systemd/system/ssh.service.d/20-remote-harness-capacity.conf
```

内容：

```ini
[Service]
LimitNOFILE=65535:524288
```

应用：

```bash
sudo systemctl daemon-reload
sudo systemctl restart ssh.service
```

说明：

- 提高 sshd 主进程和子进程可用文件描述符数量。
- 避免多用户 SSH/SFTP/SSHFS 连接先撞到默认 soft `nofile=1024`。
- `restart ssh.service` 通常不会断开既有 SSH 连接，但仍建议保留一个独立的已登录管理员会话以防配置错误。

验证：

```bash
pid=$(systemctl show -p MainPID --value ssh.service)
sudo cat /proc/$pid/limits | egrep 'Max open files|Max processes'
```

## PAM 登录会话 nofile

建议创建：

```text
/etc/security/limits.d/20-remote-harness-capacity.conf
```

内容：

```text
* soft nofile 65535
* hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
```

说明：

- 提高通过 SSH 登录后的 shell、SFTP、SSHFS 相关进程可用文件描述符数量。
- 只对新登录会话生效；已有 SSH 会话不会自动继承，需要重新登录。

验证新登录会话：

```bash
ulimit -n
cat /proc/$$/limits | egrep 'Max open files'
```

## 内核网络队列和 TCP keepalive

建议创建：

```text
/etc/sysctl.d/20-remote-harness-ssh.conf
```

内容：

```text
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
```

应用：

```bash
sudo sysctl --system
```

含义：

- `net.core.somaxconn = 8192`：提高监听 socket 队列上限。
- `net.ipv4.tcp_max_syn_backlog = 8192`：提高半连接队列容量，应对连接突发。
- `net.ipv4.tcp_keepalive_time = 600`：TCP 空闲 10 分钟后开始 keepalive 探测。
- `net.ipv4.tcp_keepalive_intvl = 60`：TCP keepalive 探测间隔 60 秒。
- `net.ipv4.tcp_keepalive_probes = 5`：连续 5 次探测失败后认为连接不可用。

验证：

```bash
sysctl net.core.somaxconn \
  net.ipv4.tcp_max_syn_backlog \
  net.ipv4.tcp_keepalive_time \
  net.ipv4.tcp_keepalive_intvl \
  net.ipv4.tcp_keepalive_probes
```

## ssh.socket 处理原则

不同 Ubuntu 版本的 `ssh.socket` 模式可能不同。处理原则：

- 如果 `ssh.socket` 已经启用且为 `Accept=no`，由 systemd 持有 22 端口并触发常驻 `ssh.service`，
  通常可以保持现状。
- 如果 `ssh.socket` 是 `Accept=yes` 并且 `Conflicts=ssh.service`，启用后可能切换为 per-connection daemon
  模型，并与常驻 `ssh.service` 冲突。对多用户、长时间 SSHFS 场景，通常更推荐常驻 sshd listener。
- 不要为了 remote-harness 盲目启用 `ssh.socket`；先阅读当前系统的 unit 文件并做维护窗口验证。

检查：

```bash
systemctl is-enabled ssh.socket 2>/dev/null || true
systemctl is-active ssh.socket 2>/dev/null || true
systemctl cat ssh.socket 2>/dev/null || true
```

## 推荐验证清单

查看 sshd 最终生效配置：

```bash
sudo /usr/sbin/sshd -T | egrep '^(maxsessions|maxstartups|logingracetime|clientaliveinterval|clientalivecountmax|tcpkeepalive|usedns)'
```

检查服务状态：

```bash
systemctl is-active ssh.service
systemctl show ssh.service | egrep '^(ActiveState|SubState|MainPID|TasksCurrent|TasksMax|LimitNOFILE|LimitNOFILESoft)='
```

查看 TCP 监听和连接数量：

```bash
ss -ltn sport = :22
ss -tan state established sport = :22 | tail -n +2 | wc -l
ss -tan state syn-recv sport = :22 | tail -n +2 | wc -l
```

并发 smoke test：

```bash
seq 1 30 | xargs -n1 -P30 -I{} ssh -o BatchMode=yes -o ConnectTimeout=5 user@host true
```

请把 `user@host` 换成测试账号或 Host alias。不要在生产高峰时做过大的并发压测。

## 客户端建议

remote-harness 自己会给 `sshfs` 加 `reconnect` 和 keepalive 参数。若用户手工挂载，可参考：

```bash
sshfs user@host:/remote/path /local/mount \
  -o reconnect \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=5 \
  -o follow_symlinks
```

不建议在 remote-harness 自动生成的会话 config 中启用 `ControlMaster`。它能减少重复握手，但在 macOS/FUSE-T
和长时间 SSHFS 会话里，一旦复用连接本身卡住，后续请求也会被拖住；`ControlPath` socket 还容易碰到路径长度限制。

用户自己的普通 SSH Host alias 可以按需设置 `ServerAliveInterval` / `ServerAliveCountMax` / `TCPKeepAlive`。
复杂 SSH 选项应写在用户自己的 `~/.ssh/config` Host alias 中，再把 alias 交给 remote-harness。

## 回滚方法

移除或改名 drop-in 文件：

```bash
sudo mv /etc/ssh/sshd_config.d/20-remote-harness-capacity.conf \
  /etc/ssh/sshd_config.d/20-remote-harness-capacity.conf.disabled
sudo mv /etc/systemd/system/ssh.service.d/20-remote-harness-capacity.conf \
  /etc/systemd/system/ssh.service.d/20-remote-harness-capacity.conf.disabled
sudo mv /etc/security/limits.d/20-remote-harness-capacity.conf \
  /etc/security/limits.d/20-remote-harness-capacity.conf.disabled
sudo mv /etc/sysctl.d/20-remote-harness-ssh.conf \
  /etc/sysctl.d/20-remote-harness-ssh.conf.disabled
```

检查并 reload：

```bash
sudo /usr/sbin/sshd -t
sudo systemctl daemon-reload
sudo systemctl reload ssh.service
sudo sysctl --system
```

若需要恢复常见内核默认值，可按发行版默认配置或手动设置，例如：

```text
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_keepalive_probes = 9
```

实际默认值以发行版和内核版本为准。

## 运维注意事项

- `MaxStartups` 不是总登录人数上限，它只限制未认证连接。
- `MaxSessions` 不是总 SSH 连接数上限，它限制单条 SSH TCP 连接内的 session/channel 数。
- 现有旧 SSH 会话不会继承新的 PAM `nofile`，需要重新登录。
- 长时间 SSHFS 挂载仍建议客户端使用 `reconnect` 和 keepalive。
- 如果未来连接数明显超过当前规模，应继续观察 `sshd` 进程数、`ss -tan sport = :22`、内存、文件描述符使用量和认证日志。
- 修改 sshd 配置前保留至少一个已登录管理会话，并先执行 `sshd -t`。
