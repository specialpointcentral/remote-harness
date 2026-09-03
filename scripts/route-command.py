#!/usr/bin/env python3
"""Rewrite a Bash tool call to the remote-harness project-host runner."""

from __future__ import annotations

import argparse
import base64
import json
import os
import shlex
import sys
from typing import Any


def encode(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def decision(kind: str, **values: Any) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": kind,
            **values,
        }
    }


def deny(reason: str) -> dict[str, Any]:
    return decision("deny", permissionDecisionReason=reason)


def route(args: argparse.Namespace) -> dict[str, Any]:
    try:
        event = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as error:
        return deny(f"remote-harness could not parse hook input: {error}")

    tool_input = event.get("tool_input")
    if event.get("tool_name") != "Bash" or not isinstance(tool_input, dict):
        return deny("remote-harness only routes Bash tool calls")

    command = tool_input.get("command")
    if not isinstance(command, str):
        return deny("remote-harness Bash input has no string command")

    runner = os.path.realpath(os.path.expanduser(args.runner))
    if not os.path.isfile(runner) or not os.access(runner, os.X_OK):
        return deny("remote-harness session runner is missing or not executable")

    mount_root = os.path.realpath(os.path.expanduser(args.mount_root))
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
    if relative_cwd == ".":
        relative_cwd = ""
    updated_input = dict(tool_input)
    updated_input["command"] = " ".join(
        shlex.quote(part) for part in (runner, encode(relative_cwd), encode(command))
    )
    return decision("allow", updatedInput=updated_input)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True)
    parser.add_argument("--mount-root", required=True)
    args = parser.parse_args()

    try:
        result = route(args)
    except Exception as error:  # Keep hook execution fail-closed after Python starts.
        result = deny(f"remote-harness command routing failed: {error}")
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
