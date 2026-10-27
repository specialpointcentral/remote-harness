#!/usr/bin/env python3
"""Run a routed project-host command while holding its SSH channel's stdin open.

The project host treats EOF on that channel as "the caller is gone" and stops the command's whole
process tree. Holding the pipe here (instead of passing the agent's own stdin, which is usually
already at EOF) makes EOF mean exactly that: this guard was cancelled, killed, or its SSH connection
dropped. stdout and stderr are inherited unchanged; the command's exit status is returned.

With `--warm SOCKET --warm-request LINE` it first sends LINE on a channel the session's warm pool
opened ahead of time (warm_pool.py), which saves the round trips of opening one. A request that was
never acknowledged by the project host did not run, so it falls back to the command after `--`.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys

child: subprocess.Popen | None = None
held = None  # the claimed warm channel, while one is in use

B64 = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")


def forward(signum: int, _frame: object) -> None:
    if held is not None:
        held.close()  # closing the channel's stdin stops the command on the project host
    proc = child
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    os._exit(128 + signum)


def valid_request(line: str) -> bool:
    """`remote-harness-exec <root> <cwd> <command> watch`, each value base64, as rh-run writes it."""
    parts = line.split(" ")
    return (len(parts) == 5 and parts[0] == "remote-harness-exec" and parts[4] == "watch"
            and all(part and set(part) <= B64 for part in parts[1:4]))


def write_all(fd: int, data: bytes) -> None:
    while data:
        data = data[os.write(fd, data):]


def run_warm(socket_path: str, request: str) -> int | None:
    """The command's status through the warm pool, or None when the ordinary path must run it."""
    global held
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # warm_pool.py sits beside us
    import warm_pool

    held = warm_pool.claim(socket_path)
    if held is None:
        return None
    try:
        return warm_pool.run(held, request, lambda data: write_all(1, data), lambda data: write_all(2, data))
    except warm_pool.NotDelivered:
        return None
    except BrokenPipeError:
        return 141  # our reader went away; closing the channel below stops the command
    finally:
        held.close()
        held = None


def main() -> int:
    argv = sys.argv[1:]
    warm = {}
    while argv[:1] in (["--warm"], ["--warm-request"]) and len(argv) >= 2:
        warm[argv[0]] = argv[1]
        argv = argv[2:]
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        sys.stderr.write("usage: channel-guard.py [--warm SOCKET --warm-request LINE] -- <command> [args...]\n")
        return 2
    global child
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    if warm.get("--warm") and valid_request(warm.get("--warm-request", "")):
        status = run_warm(warm["--warm"], warm["--warm-request"])
        if status is not None:
            return status
    child = subprocess.Popen(argv, stdin=subprocess.PIPE)
    status = child.wait()
    if child.stdin is not None:
        try:
            child.stdin.close()
        except OSError:
            pass
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    raise SystemExit(main())
