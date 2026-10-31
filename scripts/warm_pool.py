#!/usr/bin/env python3
"""Warm channel pool for routed project-host requests.

A new SSH channel to the project host costs two to three round trips before its command can run.
The broker (`warm_pool.py serve`, one per agent session) keeps channels already open on the
gateway's `remote-harness-wait` verb: each has printed RH_WAIT_READY and is waiting for one request
line. A client (channel-guard.py for Bash, project-host-tool.py for git/rg) asks the broker's Unix
socket for one, receives the channel's stdin, stdout and stderr as file descriptors, writes its
request line and relays the output. The broker reports the exit status once the channel's ssh exits
and opens another channel, so a command pays about one round trip.

Each channel serves exactly one request, so every command keeps its own streams, exit status, and
"closing stdin stops the command" cancellation. Anything that fails before the request is written (no
broker, no ready channel, a failed handoff, a channel already gone) leaves the client on the ordinary
path. A complete request whose acknowledgment is lost has uncertain delivery and is never retried
for Bash. The ready reserve grows only to RH_WARM_READY_MAX (at most two), with at most two openings,
and the total inventory including handed/closing channels stays at or below RH_WARM_MAX (9 by default,
below the system sshd's MaxSessions 10; the launcher raises it to 16 for its user-mode sshd).
Each opening has a deadline; ready channels age individually and shrink back to RH_WARM_MIN after
RH_WARM_IDLE seconds. Shutdown drains handed commands before stopping their SSH master. The
connection's keepalive notices a dead tunnel within about 15 s, which bounds how long its stale ready
channels can be handed out (a request on one fails as uncertain instead of being retried).

The client half uses only small standard-library modules because it runs on every routed call.
"""

from __future__ import annotations

import os
import socket
import sys

READY = b"RH_WAIT_READY\n"
GOT = b"RH_WAIT_GOT\n"  # the gateway read the request line; nothing has run before this
CLAIM_TIMEOUT = 2.0  # the broker answers at once; a slower answer means use the ordinary path


class NotDelivered(Exception):
    """The request could not be written to the channel, so the project host never ran it."""


class Claim:
    """A ready channel handed to this process: the write end of its stdin, the read ends of its stdout
    and stderr, and the broker connection that reports its exit status."""

    def __init__(self, conn: socket.socket, fds: list[int]) -> None:
        self.conn = conn
        self.stdin, self.stdout, self.stderr = fds
        for fd in fds:
            os.set_inheritable(fd, False)

    def close(self) -> None:
        fds = self.stdin, self.stdout, self.stderr
        self.stdin = self.stdout = self.stderr = -1
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
        self.conn.close()


def claim(path: str, wait_seconds: float = 0.0) -> Claim | None:
    """Claim a ready channel, optionally waiting briefly for an empty pool to finish opening one.

    An absent/unresponsive broker returns None without additional retries. All retries share one
    deadline, so the wait cannot grow with the number of empty replies.
    """
    if not path:
        return None
    import array
    import time

    wait_seconds = max(0.0, min(1.0, wait_seconds))
    deadline = time.monotonic() + wait_seconds
    while True:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        fds = array.array("i")
        data = b""
        try:
            timeout = min(CLAIM_TIMEOUT, max(0.001, deadline - time.monotonic())) if wait_seconds else CLAIM_TIMEOUT
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall(b"GET\n")
            data, ancdata, _flags, _addr = conn.recvmsg(64, socket.CMSG_SPACE(3 * fds.itemsize))
            for level, kind, payload in ancdata:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds.frombytes(payload[: len(payload) - len(payload) % fds.itemsize])
            if data == b"OK\n" and len(fds) == 3:
                conn.settimeout(None)
                return Claim(conn, list(fds))
        except OSError:
            pass
        for fd in fds:
            os.close(fd)
        conn.close()
        remaining = deadline - time.monotonic()
        if data != b"NONE\n" or remaining <= 0:
            return None
        time.sleep(min(0.02, remaining))


def run(held: Claim, request: str, on_stdout, on_stderr) -> int:
    """Send `request` (one line) on the claimed channel, pass its output to on_stdout/on_stderr until
    both streams end and the broker reports the exit status, and return that status.

    Raises NotDelivered only when the complete request line could not be written. After a complete
    write a lost acknowledgment leaves delivery uncertain, so return 255 without permitting a Bash
    retry. Output before the acknowledgment is held back. The channel's stdin stays open until the
    end; closing it (held.close(), or this process dying) stops the command on the project host.
    Exceptions from the callbacks (BrokenPipeError) propagate.
    """
    import select

    line = request.encode() + b"\n"
    try:
        while line:
            line = line[os.write(held.stdin, line):]
    except OSError as error:
        raise NotDelivered(str(error)) from error
    streams = {held.stdout: on_stdout, held.stderr: on_stderr}
    poller = select.poll()
    for fd in (held.stdout, held.stderr, held.conn.fileno()):
        poller.register(fd, select.POLLIN)
    head = b""  # stdout until the acknowledgment
    early_err: list[bytes] = []  # stderr until the acknowledgment
    acked = False
    status = None
    reply = b""

    def acknowledge(rest: bytes) -> None:
        nonlocal acked
        acked = True
        for chunk in early_err:
            on_stderr(chunk)
        if rest:
            on_stdout(rest)

    while streams or status is None:
        for fd, _event in poller.poll():
            if fd in streams:
                data = os.read(fd, 65536)
                if not data:
                    poller.unregister(fd)
                    del streams[fd]
                elif acked:
                    streams[fd](data)
                elif fd == held.stderr:
                    early_err.append(data)
                else:
                    head += data
                    if head.startswith(GOT):
                        acknowledge(head[len(GOT):])
                    elif not GOT.startswith(head):
                        acknowledge(head)  # not the protocol: treat it as delivered, never retry
                continue
            data = held.conn.recv(64)
            reply += data
            if not data or reply.endswith(b"\n"):
                poller.unregister(fd)
                parts = reply.split()
                status = int(parts[1]) if len(parts) == 2 and parts[0] == b"EXIT" and parts[1].isdigit() else 255
                if acked and not data and not reply:
                    on_stderr(b"remote-harness: the warm channel pool stopped before the command finished\n")
    if not acked:
        detail = b"".join(early_err).decode("utf-8", "replace").strip()[-200:]
        on_stderr(("remote-harness: warm request delivery is uncertain; the complete request was sent "
                   "but no acknowledgment arrived; not retrying Bash\n").encode())
        if detail:
            on_stderr((detail + "\n").encode())
        return 255
    return status


# --- broker ---------------------------------------------------------------------------------------

USAGE = ("usage: warm_pool.py serve --socket PATH --control-path PATH --ssh-config PATH --alias NAME "
         "--owner-pid PID --session-dir PATH --log PATH")


def env_int(name: str, default: int, low: int, high: int) -> int:
    try:
        value = int(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return max(low, min(high, value))


def serve(argv: list[str]) -> int:
    import array
    import fcntl
    import selectors
    import signal
    import subprocess
    import time

    names = ("--socket", "--control-path", "--ssh-config", "--alias", "--owner-pid", "--session-dir", "--log")
    if len(argv) != 2 * len(names) or sorted(argv[::2]) != sorted(names):
        sys.stderr.write(USAGE + "\n")
        return 2
    opt = {flag[2:].replace("-", "_"): value for flag, value in zip(argv[::2], argv[1::2])}
    owner = int(opt["owner_pid"])
    sock_path, control = opt["socket"], opt["control_path"]
    pool_max = env_int("RH_WARM_MAX", 9, 0, 16)
    ready_max = env_int("RH_WARM_READY_MAX", 2, 0, min(2, pool_max))
    opening_max = env_int("RH_WARM_OPENING_MAX", 2, 1, 2)
    pool_min = env_int("RH_WARM_MIN", 1, 0, ready_max)
    open_timeout = env_int("RH_WARM_OPEN_TIMEOUT", 10, 1, 300)
    idle = env_int("RH_WARM_IDLE", 90, 5, 86400)
    max_age = env_int("RH_WARM_MAX_AGE", 600, 30, 86400)
    if pool_max == 0:
        return 0

    os.umask(0o077)
    log_file = open(opt["log"], "ab", buffering=0)

    def log(message: str) -> None:
        try:
            if log_file.tell() > 512 * 1024:
                log_file.truncate(0)
                log_file.seek(0)
            log_file.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n".encode())
        except OSError:
            pass

    lock = open(sock_path + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another broker serves this session
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(sock_path)
    listener.listen(16)
    listener.setblocking(False)
    owned: dict[str, tuple[int, int]] = {}  # path -> (dev, inode) of the sockets this broker made

    def remember(path: str) -> None:
        try:
            st = os.stat(path)
            owned[path] = (st.st_dev, st.st_ino)
        except OSError:
            pass

    def unlink_own(path: str) -> None:
        """Remove `path` only if it is still the socket this broker made, never a successor's."""
        try:
            st = os.stat(path)
        except OSError:
            return
        if owned.get(path) == (st.st_dev, st.st_ino):
            os.unlink(path)

    remember(sock_path)

    # A shorter keepalive than routed commands use: until the master notices a dead tunnel its ready
    # channels look healthy, and a request written on one is uncertain, so it is never retried. Not
    # shorter still, because these keepalives queue behind SSHFS traffic in the same reverse tunnel.
    ssh_base = ["ssh", "-F", opt["ssh_config"], "-T", "-o", "ClearAllForwardings=yes", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                "-o", f"ControlPath={control}"]

    class Channel:
        def __init__(self, proc: subprocess.Popen, now: float) -> None:
            self.proc, self.started, self.ready_at = proc, now, 0.0
            self.state = "new"  # -> opening -> ready -> handed, or -> closing
            self.number = state["sequence"]
            self.closing_at = 0.0
            self.out = b""
            self.err = b""
            self.conn: socket.socket | None = None

    sel = selectors.DefaultSelector()
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False)
    os.set_blocking(wake_w, False)
    signal.set_wakeup_fd(wake_w)
    stop = []
    signal.signal(signal.SIGCHLD, lambda *_: None)  # a child exit wakes the loop via wake_w
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, lambda *_: stop.append(1))
    sel.register(wake_r, selectors.EVENT_READ, ("wake", None))
    sel.register(listener, selectors.EVENT_READ, ("listen", None))

    channels: list[Channel] = []
    state = {"target": pool_min, "failures": 0, "next_spawn": 0.0, "disabled": False,
             "master": None, "master_failures": 0, "next_master": 0.0,
             "sequence": 0, "draining": False}

    def transition(ch: Channel, target: str, reason: str, now: float) -> None:
        log(f"channel={ch.number} {ch.state}->{target} age_ms={int(1000 * (now - ch.started))} "
            f"reason={reason}")
        ch.state = target

    def stop_old_master() -> None:
        if os.path.exists(control):
            # A predecessor may have handed out live channels before it died. Stop accepting new
            # ones on its master, preserving those commands while this broker creates its own.
            subprocess.run(["ssh", "-o", f"ControlPath={control}", "-O", "stop", "rh-warm"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=10, check=False)
            try:
                os.unlink(control)
            except FileNotFoundError:
                pass

    def start_master(now: float) -> None:
        owned.pop(control, None)
        stop_old_master()
        state["master"] = subprocess.Popen(
            ssh_base + ["-N", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "Compression=yes",
                        opt["alias"]],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log_file)
        state["master_started"] = now

    def master_up() -> bool:
        master = state["master"]
        if master is None or master.poll() is not None or not os.path.exists(control):
            return False
        if control not in owned:
            remember(control)
        return True

    def unwatch(ch: Channel) -> None:
        for stream in (ch.proc.stdout, ch.proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    sel.unregister(stream)
                except (KeyError, ValueError):
                    pass

    def close_pipes(ch: Channel) -> None:
        unwatch(ch)
        for stream in (ch.proc.stdin, ch.proc.stdout, ch.proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass

    def backoff(kind: str, now: float) -> float:
        state[kind] += 1
        return now + min(30.0, 0.5 * 2 ** min(state[kind], 6))

    def discard(ch: Channel, reason: str, now: float) -> None:
        if ch.state in ("closing", "handed", "exited"):
            return
        was = ch.state
        close_pipes(ch)
        transition(ch, "closing", reason, now)
        ch.closing_at = now
        if ch.proc.poll() is None:
            ch.proc.terminate()
        if was == "opening":
            detail = ch.err.decode("utf-8", "replace").strip().splitlines()
            detail_text = detail[-1] if detail else ""
            if "unsupported SSH command" in detail_text:
                state["disabled"] = True
                log("the project host's gateway has no remote-harness-wait; the pool stays off")
                return
            state["next_spawn"] = backoff("failures", now)
            capacity = "session open refused" in detail_text.lower() or "no more sessions" in detail_text.lower()
            log(f"channel={ch.number} opening failed capacity={int(capacity)} "
                f"backoff_ms={int(1000 * (state['next_spawn'] - now))} "
                f"({reason}){': ' + detail_text if detail_text else ''}")
        elif was == "ready" and reason != "idle":
            log(f"a ready channel closed ({reason})")

    def spawn(now: float) -> None:
        # OpenSSH otherwise silently falls back to a fresh TCP connection if the mux session is
        # refused. The existing master is tried first; false prevents only that new-connection path.
        proc = subprocess.Popen(ssh_base + ["-o", "ControlMaster=no", "-o", "ProxyCommand=false",
                                           opt["alias"], "remote-harness-wait"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        state["sequence"] += 1
        ch = Channel(proc, now)
        for stream, which in ((proc.stdout, "out"), (proc.stderr, "err")):
            os.set_blocking(stream.fileno(), False)
            sel.register(stream, selectors.EVENT_READ, (which, ch))
        channels.append(ch)
        transition(ch, "opening", "spawn", now)

    def on_output(ch: Channel, which: str, now: float) -> None:
        if ch.state not in ("opening", "ready"):
            return
        stream = ch.proc.stdout if which == "out" else ch.proc.stderr
        try:
            data = os.read(stream.fileno(), 4096)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if which == "err":
            ch.err = (ch.err + data)[-4096:]
            if not data:
                try:
                    sel.unregister(stream)
                except (KeyError, ValueError):
                    pass  # reap() drains a stream whose end the loop already handled
            return
        if not data:
            discard(ch, "its ssh ended", now)
            return
        ch.out += data
        if ch.state == "opening" and ch.out == READY:
            transition(ch, "ready", "gateway ready", now)
            ch.ready_at = now
            state["failures"] = 0
        elif ch.state != "opening" or not READY.startswith(ch.out):
            discard(ch, "unexpected output", now)

    def hand_out(conn: socket.socket, now: float) -> None:
        ready = [ch for ch in channels if ch.state == "ready" and ch.proc.poll() is None]
        if not ready:
            try:
                conn.sendall(b"NONE\n")
            except OSError:
                pass
            conn.close()
            if not state["disabled"] and state["target"] < ready_max:
                state["target"] += 1
            return
        ch = max(ready, key=lambda c: c.ready_at)  # newest: idle ones age out
        fds = array.array("i", [ch.proc.stdin.fileno(), ch.proc.stdout.fileno(), ch.proc.stderr.fileno()])
        try:
            conn.sendmsg([b"OK\n"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)])
        except OSError:
            conn.close()
            return
        # The client now holds the only copies: its exit, or its closing stdin, ends the channel.
        close_pipes(ch)
        transition(ch, "handed", "client claim", now)
        ch.conn = conn

    def on_client(conn: socket.socket, now: float) -> None:
        sel.unregister(conn)
        try:
            request = conn.recv(16)
        except OSError:
            request = b""
        if request == b"GET\n" and not state["disabled"] and not state["draining"]:
            hand_out(conn, now)
            return
        if request == b"STAT\n":
            counts = {s: sum(1 for ch in channels if ch.state == s) for s in ("opening", "ready", "handed", "closing")}
            text = " ".join(f"{k}={v}" for k, v in counts.items())
            try:
                conn.sendall(f"{text} target={state['target']} disabled={int(state['disabled'])} "
                             f"master={int(master_up())}\n".encode())
            except OSError:
                pass
        elif request == b"GET\n":
            try:
                conn.sendall(b"NONE\n")
            except OSError:
                pass
        conn.close()

    def reap(now: float) -> None:
        for ch in list(channels):
            code = ch.proc.poll()
            if code is None:
                continue
            if ch.state == "handed" and ch.conn is not None:
                try:
                    ch.conn.sendall(f"EXIT {code if 0 <= code <= 255 else 255}\n".encode())
                except OSError:
                    pass
                ch.conn.close()
            elif ch.state in ("opening", "ready"):
                # Drain what it said before it went (an old gateway's refusal arrives with the exit).
                for which in ("err", "out"):
                    stream = ch.proc.stderr if which == "err" else ch.proc.stdout
                    if stream is not None and not stream.closed:
                        on_output(ch, which, now)
                if ch.state != "closing":
                    discard(ch, f"its ssh exited with {code}", now)
            close_pipes(ch)
            transition(ch, "exited", f"status {code}", now)
            channels.remove(ch)
        master = state["master"]
        if master is not None and master.poll() is not None:
            log(f"the pool's SSH connection ended (status {master.returncode})")
            state["master"] = None
            state["next_master"] = backoff("master_failures", now)
            for ch in channels:
                if ch.state in ("opening", "ready"):
                    discard(ch, "its connection ended", now)

    def maintain(now: float) -> None:
        for ch in channels:
            if ch.state == "closing" and ch.proc.poll() is None and now - ch.closing_at >= 1:
                ch.proc.kill()
            elif ch.state == "opening" and now - ch.started >= open_timeout:
                discard(ch, "opening timeout", now)
        if state["disabled"] or state["draining"]:
            return
        if state["master"] is None:
            if now >= state["next_master"]:
                start_master(now)
            return
        if not master_up():
            if now - state.get("master_started", now) > 30:
                log("the pool's SSH connection did not come up within 30 s; restarting it")
                state["master"].terminate()
            return
        state["master_failures"] = 0
        ready = [ch for ch in channels if ch.state == "ready"]
        for ch in sorted(ready, key=lambda c: c.ready_at):
            if now - ch.started > max_age:
                discard(ch, "idle", now)  # replaced below by a fresh one
            elif now - ch.ready_at > idle and len(ready) > pool_min:
                discard(ch, "idle", now)
                ready.remove(ch)
                state["target"] = max(pool_min, state["target"] - 1)
        warm = sum(1 for ch in channels if ch.state in ("opening", "ready"))
        opening = sum(1 for ch in channels if ch.state == "opening")
        room = pool_max - len(channels)
        want = min(state["target"] - warm, room, opening_max - opening)
        if want > 0 and now >= state["next_spawn"]:
            for _ in range(want):
                spawn(now)

    def owner_alive() -> bool:
        try:
            os.kill(owner, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass
        try:  # an exited agent its parent has not reaped yet is a zombie, which kill(0) still finds
            with open(f"/proc/{owner}/stat", "rb") as stat:
                if stat.read().rsplit(b")", 1)[1].split()[0] == b"Z":
                    return False
        except (OSError, IndexError):
            pass
        return os.path.isdir(opt["session_dir"])

    log(f"warm pool started (min {pool_min}, max {pool_max}, ready_max {ready_max}, "
        f"opening_max {opening_max}, opening_timeout {open_timeout}s, idle {idle}s)")
    try:
        # A gateway without the wait verb turns the pool off: clients that find no socket use the
        # ordinary path.
        while True:
            now = time.monotonic()
            if not state["draining"] and (stop or state["disabled"] or not owner_alive()):
                state["draining"] = True
                log("warm pool draining handed channels")
                unlink_own(sock_path)
                sel.unregister(listener)
                listener.close()
                for ch in channels:
                    if ch.state in ("opening", "ready"):
                        discard(ch, "shutdown", now)
            if state["draining"] and not channels:
                break
            for key, _mask in sel.select(timeout=0.25):
                kind, ch = key.data
                if kind == "wake":
                    try:
                        while os.read(wake_r, 512):
                            pass
                    except BlockingIOError:
                        pass
                elif kind == "listen":
                    try:
                        conn, _ = listener.accept()
                    except BlockingIOError:
                        continue
                    conn.setblocking(False)
                    sel.register(conn, selectors.EVENT_READ, ("client", conn))
                elif kind == "client":
                    on_client(ch, now)
                else:
                    on_output(ch, kind, now)
            now = time.monotonic()
            reap(now)
            maintain(now)
    finally:
        log("warm pool stopping")
        unlink_own(sock_path)
        listener.close()
        for ch in channels:
            if ch.state != "handed":
                close_pipes(ch)
                if ch.proc.poll() is None:
                    ch.proc.terminate()
        if state["master"] is not None and state["master"].poll() is None:
            state["master"].terminate()
            try:
                state["master"].wait(timeout=5)
            except subprocess.TimeoutExpired:
                state["master"].kill()
        unlink_own(control)
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["serve"]:
        raise SystemExit(serve(sys.argv[2:]))
    sys.stderr.write(USAGE + "\n")
    raise SystemExit(2)
