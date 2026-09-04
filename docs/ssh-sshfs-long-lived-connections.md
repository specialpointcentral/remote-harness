# SSH / SSHFS Long-Lived Connection Server Tuning

Updated: 2026-06-27

This document is for shared remote development servers that run remote-harness. The remote server
runs every coding Agent and uses `ssh`, `sftp`, and `sshfs` to mount each user's local project through
a reverse tunnel. If one server hosts many users, many long-running Agent sessions, or many SSHFS
mounts, tune `sshd` and OS resource limits for capacity.

This is a generic operations template. It intentionally does not record concrete server IPs,
hostnames, or accounts.

## What remote-harness Already Does Client-Side

remote-harness already:

- keeps automatic SSH runtime files under `~/.remote-harness/.sessions/...`, never in
  `~/.ssh/config` or `~/.ssh/known_hosts`;
- disables OpenSSH multiplexing (`ControlMaster no`) in generated session configs to avoid
  macOS/FUSE-T `ControlPath` socket path limits and stuck reused connections;
- passes `reconnect`, `ServerAliveInterval`, and `ServerAliveCountMax` to `sshfs`;
- verifies that a mount actually becomes live instead of trusting only the `sshfs` exit code;
- cleans up reverse mounts, session rules, temporary SSH configs, and managed auth references on
  exit where possible.

Those choices improve session-level reliability. Server-side capacity still matters when many users
create many long-lived SSH/SFTP/SSHFS connections.

## When To Apply This

Use these settings when:

- many users share one remote development server;
- many agent sessions create SSH / SSHFS connections at the same time;
- SSHFS mounts are expected to live for hours or days;
- network blips should not immediately kill a mount, but dead sessions should be reclaimed;
- the server still has a low default `nofile` such as `1024`.

For single-user, short-lived sessions, default OpenSSH settings are often enough.

## Recommended sshd Config

Create:

```text
/etc/ssh/sshd_config.d/20-remote-harness-capacity.conf
```

Recommended content:

```text
MaxStartups 200:30:500
MaxSessions 100
ClientAliveInterval 60
ClientAliveCountMax 5
LoginGraceTime 60
TCPKeepAlive yes
UseDNS no
```

Validate before applying:

```bash
sudo /usr/sbin/sshd -t
```

Reload:

```bash
sudo systemctl reload ssh.service
```

### Parameter Notes

`MaxStartups 200:30:500`

Controls unauthenticated SSH connections, not the total number of logged-in users:

- up to `200` unauthenticated connections are accepted normally;
- above `200`, new unauthenticated connections are rejected probabilistically, starting at `30%`;
- at `500`, all new unauthenticated connections are rejected.

This protects the handshake/authentication phase during connection bursts, batch SSHFS mounts, or
automation fan-out.

`MaxSessions 100`

Controls how many session/channel objects can be opened inside one authenticated SSH TCP
connection. remote-harness generated configs disable multiplexing, so normal remote-harness traffic
does not pack many operations into one TCP connection. The setting still helps if a user's own Host
alias or another tool enables `ControlMaster`.

`ClientAliveInterval 60` and `ClientAliveCountMax 5`

The server sends an SSH protocol keepalive every 60 seconds and disconnects after 5 missed replies.
Dead clients are usually reclaimed after about 5 minutes, while short network blips are tolerated.

`LoginGraceTime 60`

The client must authenticate within 60 seconds after opening the TCP connection. This prevents stale
unauthenticated connections from occupying `MaxStartups` slots for too long.

`UseDNS no`

Disables reverse DNS lookups during login, avoiding slow or broken DNS delaying SSH logins.

## systemd File Descriptor Limit

Create:

```text
/etc/systemd/system/ssh.service.d/20-remote-harness-capacity.conf
```

Content:

```ini
[Service]
LimitNOFILE=65535:524288
```

Apply:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ssh.service
```

Notes:

- Raises available file descriptors for the sshd master process and children.
- Avoids hitting a low default soft `nofile=1024` with many SSH/SFTP/SSHFS connections.
- Restarting `ssh.service` usually does not disconnect existing SSH sessions, but keep an
  independent admin session open before changing sshd configuration.

Verify:

```bash
pid=$(systemctl show -p MainPID --value ssh.service)
sudo cat /proc/$pid/limits | egrep 'Max open files|Max processes'
```

## PAM Login Session nofile

Create:

```text
/etc/security/limits.d/20-remote-harness-capacity.conf
```

Content:

```text
* soft nofile 65535
* hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
```

This raises file descriptor limits for new SSH login sessions, SFTP, and SSHFS-related processes.
Existing SSH sessions do not inherit it; log in again.

Verify in a new login:

```bash
ulimit -n
cat /proc/$$/limits | egrep 'Max open files'
```

## Kernel Queues and TCP keepalive

Create:

```text
/etc/sysctl.d/20-remote-harness-ssh.conf
```

Content:

```text
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
```

Apply:

```bash
sudo sysctl --system
```

Meaning:

- `net.core.somaxconn = 8192`: raises the listen socket queue ceiling.
- `net.ipv4.tcp_max_syn_backlog = 8192`: raises the half-open SYN backlog.
- `net.ipv4.tcp_keepalive_time = 600`: starts TCP keepalive after 10 idle minutes.
- `net.ipv4.tcp_keepalive_intvl = 60`: sends TCP keepalive probes every 60 seconds.
- `net.ipv4.tcp_keepalive_probes = 5`: declares the connection dead after 5 failed probes.

Verify:

```bash
sysctl net.core.somaxconn \
  net.ipv4.tcp_max_syn_backlog \
  net.ipv4.tcp_keepalive_time \
  net.ipv4.tcp_keepalive_intvl \
  net.ipv4.tcp_keepalive_probes
```

## ssh.socket Policy

Ubuntu releases may ship different `ssh.socket` models. Use this rule of thumb:

- If `ssh.socket` is already enabled with `Accept=no`, where systemd owns port 22 and activates a
  persistent `ssh.service`, keeping it is usually fine.
- If `ssh.socket` uses `Accept=yes` and `Conflicts=ssh.service`, enabling it may switch to a
  per-connection daemon model and conflict with persistent `ssh.service`. For multi-user,
  long-lived SSHFS workloads, the persistent sshd listener is usually simpler and safer.
- Do not enable `ssh.socket` just for remote-harness; inspect the unit and test during a maintenance
  window first.

Inspect:

```bash
systemctl is-enabled ssh.socket 2>/dev/null || true
systemctl is-active ssh.socket 2>/dev/null || true
systemctl cat ssh.socket 2>/dev/null || true
```

## Verification Checklist

Effective sshd config:

```bash
sudo /usr/sbin/sshd -T | egrep '^(maxsessions|maxstartups|logingracetime|clientaliveinterval|clientalivecountmax|tcpkeepalive|usedns)'
```

Service state:

```bash
systemctl is-active ssh.service
systemctl show ssh.service | egrep '^(ActiveState|SubState|MainPID|TasksCurrent|TasksMax|LimitNOFILE|LimitNOFILESoft)='
```

TCP listener and connection counts:

```bash
ss -ltn sport = :22
ss -tan state established sport = :22 | tail -n +2 | wc -l
ss -tan state syn-recv sport = :22 | tail -n +2 | wc -l
```

Small concurrency smoke test:

```bash
seq 1 30 | xargs -n1 -P30 -I{} ssh -o BatchMode=yes -o ConnectTimeout=5 user@host true
```

Replace `user@host` with a test account or Host alias. Avoid large production-hour load tests.

## Client Notes

remote-harness already passes reconnect and keepalive options to `sshfs`. For manual mounts:

```bash
sshfs user@host:/remote/path /local/mount \
  -o reconnect \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=5 \
  -o follow_symlinks
```

Do not enable `ControlMaster` in remote-harness generated session configs. It can reduce repeated
handshakes, but if the reused connection gets stuck, later requests get stuck too; on macOS/FUSE-T,
`ControlPath` sockets can also hit path-length limits.

Users may still set `ServerAliveInterval`, `ServerAliveCountMax`, and `TCPKeepAlive` in their own
normal SSH Host aliases. Complex SSH options should live in the user's `~/.ssh/config` Host alias;
pass that alias to remote-harness.

## Rollback

Disable or rename the drop-ins:

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

Validate and reload:

```bash
sudo /usr/sbin/sshd -t
sudo systemctl daemon-reload
sudo systemctl reload ssh.service
sudo sysctl --system
```

Common kernel defaults, if you need to restore them manually:

```text
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_keepalive_probes = 9
```

Actual defaults vary by distribution and kernel version.

## Operations Notes

- `MaxStartups` is not the logged-in user limit; it limits unauthenticated connections.
- `MaxSessions` is not the total SSH connection limit; it limits channels inside one SSH TCP
  connection.
- Existing SSH sessions do not inherit new PAM `nofile`; log in again.
- Long-running SSHFS mounts should still use reconnect and keepalive client options.
- If load grows, keep watching sshd process count, `ss -tan sport = :22`, memory, file descriptors,
  and authentication logs.
- Keep one admin session open and run `sshd -t` before changing sshd config.
