#!/usr/bin/env python3
"""Rewrite a Bash tool call to the remote-harness project-host runner.

It runs before every Bash and Agent call, so it imports only what it uses (no argparse or typing).
"""

from __future__ import annotations

import base64
import json
import os
import shlex
import subprocess
import sys


def encode(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decision(kind: str, **values: object) -> dict[str, object]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": kind,
            **values,
        }
    }


def deny(reason: str) -> dict[str, object]:
    return decision("deny", permissionDecisionReason=reason)


def launches_agent(command: str) -> bool:
    # The project host has no required Python runtime. Its portable lexical check is also used
    # here, so quoting and here-documents receive the same policy on both sides of the tunnel.
    checker = os.path.join(os.path.dirname(os.path.realpath(__file__)), "run-on-project-host.sh")
    result = subprocess.run(["sh", checker, "--check-command"], input=command,
                            text=True, capture_output=True, timeout=10)
    if result.returncode not in (0, 1):
        raise ValueError("incomplete shell quoting or here-document, or unavailable command policy")
    return result.returncode == 1


def route(runner_arg: str, mount_root_arg: str) -> dict[str, object]:
    try:
        event = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as error:
        return deny(f"remote-harness could not parse hook input: {error}")

    tool_name = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return deny("remote-harness tool input is not an object")
    if tool_name == "Agent":
        if tool_input.get("isolation") == "worktree":
            return deny(
                "remote-harness does not support Claude subagent worktree isolation; "
                "use an ordinary subagent or a separate harness session"
            )
        return {}
    if tool_name != "Bash":
        return deny("remote-harness only routes Bash and validates Agent tool calls")

    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        return deny("remote-harness Bash input has no string command")
    try:
        if launches_agent(command):
            return deny(
                "Agent processes must run on the remote agent host; "
                "use the Agent tool or another remote-harness session"
            )
    except ValueError as error:
        return deny(f"remote-harness could not safely parse the Bash command: {error}")

    runner = os.path.realpath(os.path.expanduser(runner_arg))
    if not os.path.isfile(runner) or not os.access(runner, os.X_OK):
        return deny("remote-harness session runner is missing or not executable")

    mount_root = os.path.realpath(os.path.expanduser(mount_root_arg))
    requested_cwd = tool_input.get("workdir") or event.get("cwd")
    if not isinstance(requested_cwd, str) or not requested_cwd:
        return deny("remote-harness hook input has no working directory")
    cwd = os.path.realpath(os.path.expanduser(requested_cwd))
    try:
        inside_mount = os.path.commonpath([mount_root, cwd]) == mount_root
    except ValueError:
        inside_mount = False
    if not inside_mount:
        return deny("remote-harness denied a Bash command outside the SSHFS mount")

    relative_cwd = os.path.relpath(cwd, mount_root)
    updated_input = dict(tool_input)
    runner_args = [runner]
    if tool_input.get("run_in_background") is True:
        runner_args.append("--background")
    runner_args.extend((encode(relative_cwd), encode(command)))
    updated_input["command"] = " ".join(
        shlex.quote(part) for part in runner_args
    )
    return decision("allow", updatedInput=updated_input)


def parse_args(argv: list[str]) -> dict[str, str]:
    """The fixed `--runner PATH --mount-root PATH` pair that inject-rule.sh writes."""
    if len(argv) % 2:
        raise ValueError("options need values")
    values = dict(zip(argv[::2], argv[1::2]))
    if sorted(values) != ["--mount-root", "--runner"] or len(argv) != 4:
        raise ValueError("expected --runner PATH --mount-root PATH")
    return values


def main() -> int:
    try:
        args = parse_args(sys.argv[1:])
        result = route(args["--runner"], args["--mount-root"])
    except Exception as error:  # Keep hook execution fail-closed after Python starts.
        result = deny(f"remote-harness command routing failed: {error}")
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
