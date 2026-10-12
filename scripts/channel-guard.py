#!/usr/bin/env python3
"""Run a routed project-host command while holding its SSH channel's stdin open.

The project host treats EOF on that channel as "the caller is gone" and stops the command's whole
process tree. Holding the pipe here (instead of passing the agent's own stdin, which is usually
already at EOF) makes EOF mean exactly that: this guard was cancelled, killed, or its SSH connection
dropped. stdout and stderr are inherited unchanged; the command's exit status is returned.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys

child: subprocess.Popen | None = None


def forward(signum: int, _frame: object) -> None:
    proc = child
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    os._exit(128 + signum)


def main() -> int:
    argv = sys.argv[1:]
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if not argv:
        sys.stderr.write("usage: channel-guard.py -- <command> [args...]\n")
        return 2
    global child
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
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
