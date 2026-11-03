#!/usr/bin/env python3
"""Run a routed project-host command while holding its SSH channel's stdin open.

The project host treats EOF on that channel as "the caller is gone" and stops the command's whole
process tree. Holding the pipe here (instead of passing the agent's own stdin, which is usually
already at EOF) makes EOF mean exactly that: this guard was cancelled, killed, or its SSH connection
dropped. stdout and stderr are inherited unchanged; the command's exit status is returned.

With `--warm SOCKET --warm-request LINE` it first sends LINE on a channel the session's warm pool
opened ahead of time (warm_pool.py), which saves the round trips of opening one. A request that was
not completely written cannot run, so it falls back to the command after `--`. A completely written
request with no acknowledgment has uncertain delivery and is never retried.

With `--slots-dir` the ordinary path holds a per-session slot: foreground fallbacks queue for up to
RH_CHANNEL_QUEUE_SECONDS (600) and keep trying the warm pool while they wait, so a saturated quota
waits for capacity instead of failing; explicit background commands (`--background`, standalone
connections) queue only RH_BACKGROUND_QUEUE_SECONDS (10), since their slots free up rarely.

With `--request-from-env` the cwd and command come in plain text from RH_REQUEST_CWD and
RH_REQUEST_COMMAND (rh-run's readable form) and are encoded here into the @cwd/@command placeholders.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys

child: subprocess.Popen | None = None
held = None  # the claimed warm channel, while one is in use
cancelled = 0
diagnostics = None


def diagnostic_helpers():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import diagnostics as helpers
    return helpers

B64 = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")


def forward(signum: int, _frame: object) -> None:
    global cancelled
    cancelled = signum
    if held is not None:
        held.close()  # closing the channel's stdin stops the command on the project host
    proc = child
    if proc is not None and proc.poll() is None:
        proc.terminate()
    # Never wait in a signal handler: it can interrupt Popen.wait while that call holds its wait
    # lock. The ordinary path below reaps the child, including cancellation during Popen startup.


def valid_request(line: str) -> bool:
    """`remote-harness-exec <root> <cwd> <command> watch`, each value base64, as rh-run writes it."""
    parts = line.split(" ")
    return (len(parts) == 5 and parts[0] == "remote-harness-exec" and parts[4] == "watch"
            and all(part and set(part) <= B64 for part in parts[1:4]))


def request_from_env(argv: list[str], options: dict[str, str]) -> list[str] | None:
    """Encode rh-run's readable request (RH_REQUEST_CWD/RH_REQUEST_COMMAND) into the @cwd/@command
    placeholders of the command and the warm request, or None when either value is missing."""
    import binascii

    values = {}
    for name, placeholder in (("RH_REQUEST_CWD", "@cwd"), ("RH_REQUEST_COMMAND", "@command")):
        value = os.environ.pop(name, None)  # the command's own environment never carries them
        if value is None:
            return None
        values[placeholder] = binascii.b2a_base64(os.fsencode(value), newline=False).decode("ascii")
    if "--warm-request" in options:
        options["--warm-request"] = " ".join(values.get(part, part) for part in options["--warm-request"].split(" "))
    return [values.get(arg, arg) for arg in argv]


def write_all(fd: int, data: bytes) -> None:
    while data:
        data = data[os.write(fd, data):]


def run_warm(socket_path: str, request: str, wait_seconds: float = 0.25) -> int | None:
    """The command's status through the warm pool, or None when the ordinary path must run it."""
    global held
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # warm_pool.py sits beside us
    import warm_pool

    held = warm_pool.claim(socket_path, wait_seconds=wait_seconds)
    if held is None:
        return None
    try:
        if cancelled:
            return 128 + cancelled
        return warm_pool.run(held, request, lambda data: write_all(1, data), lambda data: write_all(2, data),
                             diagnostics=diagnostics)
    except warm_pool.NotDelivered:
        return None
    except BrokenPipeError:
        return 141  # our reader went away; closing the channel below stops the command
    except OSError:
        if cancelled:
            return 128 + cancelled
        raise
    finally:
        held.close()
        held = None


def env_number(name: str, default: int, high: int, low: int = 0) -> int:
    try:
        return max(low, min(high, int(os.environ.get(name, str(default)))))
    except ValueError:
        return default


def acquire_slot(directory: str, background: bool, warm_retry=None) -> tuple[int | None, int | None]:
    """Hold a per-session fallback/background quota until this guard and its command finish.

    Returns (slot fd, None), or (None, status) when `warm_retry` ran the command on a warm channel
    that freed up meanwhile, or (None, None) when the queue time ran out or the call was cancelled.
    """
    import fcntl
    import random
    import time

    if background:
        limit = env_number("RH_BACKGROUND_CONCURRENCY", 8, 64, 1)
        queue = env_number("RH_BACKGROUND_QUEUE_SECONDS", 10, 3600)
    else:
        limit = env_number("RH_FOREGROUND_CONCURRENCY", 6, 64, 1)
        queue = env_number("RH_CHANNEL_QUEUE_SECONDS", 600, 3600)
    directory = os.path.join(directory, "background" if background else "foreground")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    deadline = time.monotonic() + queue
    next_warm = time.monotonic() + 0.5
    order = list(range(limit))
    while True:
        if cancelled:
            return None, None
        random.shuffle(order)
        for index in order:
            fd = os.open(os.path.join(directory, f"slot.{index}"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd, None
            except BlockingIOError:
                os.close(fd)
        if warm_retry is not None and time.monotonic() >= next_warm:
            status = warm_retry()
            if status is not None:
                return None, status
            next_warm = time.monotonic() + 0.5
        if time.monotonic() >= deadline:
            return None, None
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def main() -> int:
    argv = sys.argv[1:]
    options = {}
    background = False
    from_env = False
    while argv:
        if argv[0] == "--background":
            background = True
            argv = argv[1:]
        elif argv[0] == "--request-from-env":
            from_env = True
            argv = argv[1:]
        elif argv[0] in ("--warm", "--warm-request", "--slots-dir", "--diagnostics-dir") and len(argv) >= 2:
            options[argv[0]] = argv[1]
            argv = argv[2:]
        else:
            break
    if argv[:1] == ["--"]:
        argv = argv[1:]
    if from_env:
        argv = request_from_env(argv, options) or []
    if not argv:
        sys.stderr.write("remote-harness: category=input exit=2 session=unknown\n")
        return 2
    global child, diagnostics
    helpers = diagnostic_helpers()
    if options.get("--diagnostics-dir"):
        try:
            diagnostics = helpers.Diagnostics(options["--diagnostics-dir"])
        except helpers.Unavailable:
            write_all(2, helpers.summary("diagnostics", 255))
            return 255
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)
    warm = not background and options.get("--warm") and valid_request(options.get("--warm-request", ""))
    if warm:
        status = run_warm(options["--warm"], options["--warm-request"])
        if status is not None:
            if cancelled:
                return 128 + cancelled
            return status
    slot = None
    try:
        if options.get("--slots-dir"):
            retry = (lambda: run_warm(options["--warm"], options["--warm-request"], 0.0)) if warm else None
            slot, status = acquire_slot(options["--slots-dir"], background, retry)
            if cancelled:
                return 128 + cancelled
            if status is not None:
                return status
            if slot is None:
                write_all(2, helpers.summary("capacity", 255, diagnostics.session if diagnostics else "unknown"))
                return 255
        if cancelled:
            return 128 + cancelled
        log = diagnostics.new_log() if diagnostics else None
        if log:
            argv += ["--diagnostic-log", log, "--diagnostic-id", diagnostics.session]
        child = subprocess.Popen(argv, stdin=subprocess.PIPE)
        while child.poll() is None:
            if cancelled:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                break
            try:
                child.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
        status = child.returncode
        if child.stdin is not None:
            child.stdin.close()
        normalized = 128 + cancelled if cancelled else (status if status >= 0 else 128 - status)
        if diagnostics and normalized == 255 and not cancelled and os.path.getsize(log):
            diagnostics.emit("ssh", normalized)
    finally:
        if slot is not None:
            os.close(slot)
    if cancelled:
        return 128 + cancelled
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    try:
        result = main()
    except Exception:
        helpers = diagnostic_helpers()
        if diagnostics:
            try:
                import traceback
                diagnostics.record(traceback.format_exc().encode())
            except helpers.Unavailable:
                pass
        write_all(2, helpers.summary("framework", 255, diagnostics.session if diagnostics else "unknown"))
        result = 255
    raise SystemExit(result)
