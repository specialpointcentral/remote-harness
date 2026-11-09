#!/usr/bin/env python3
"""Block native Paseo Claude tools when their Harness lease is gone."""
import json
import os
import stat
import subprocess
import sys


def lease_live(path, token):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return False
        record = json.load(stream)
    pid = record["pid"]
    if record["token"] != token or type(pid) is not int or pid <= 1:
        return False
    # Bind to the bridge's start time and full, session-specific command line to reject PID reuse.
    observed = subprocess.check_output(
        ["/bin/ps", "-ww", "-p", str(pid), "-o", "stat=", "-o", "lstart=", "-o", "args="],
        text=True, timeout=2, stderr=subprocess.DEVNULL,
    )
    state, identity = observed.strip().split(maxsplit=1)
    return state[0] not in "XZ" and identity == record["identity"]


def main():
    try:
        tool = json.load(sys.stdin)["tool_name"]
        if not isinstance(tool, str) or not tool:
            raise ValueError("Missing tool name")
        if not lease_live(sys.argv[1], sys.argv[2]):
            raise ValueError("Expired lease")
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        print("Remote Harness transport has ended. Start a new Harness session.", file=sys.stderr)
        return 2
    if tool.startswith("mcp__paseo__"):
        print("Paseo management tools are disabled for this Harness session.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
