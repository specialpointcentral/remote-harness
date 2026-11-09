#!/usr/bin/env python3
"""Persistent native-workspace reservations; ordinary projects remain unrestricted."""
import hashlib
from pathlib import Path
import sys

from orca_native import MOUNTS, OrcaError, private_dir, private_json, write_once

REGISTRY = ".paseo-workspaces"
CHAT_REQUIRED = (
    "This workspace only accepts its registered Harness chats. "
    "Open the existing Harness chat instead of creating a normal chat here. "
    "For another Harness chat, rerun the original launch command on the project host. "
    "Normal chats in other workspaces are unaffected."
)


def record_name(cwd):
    return hashlib.sha256(str(cwd).encode("utf8")).hexdigest() + ".json"


def reserve(home, cwd):
    registry = private_dir(home / REGISTRY, create=True)
    record = registry / record_name(cwd)
    expected = {"cwd": str(cwd)}
    try:
        write_once(record, expected)
    except FileExistsError:
        if private_json(record) != expected:
            raise OrcaError("Invalid Harness workspace reservation.")


def protected(home, cwd):
    mount_parent = home / MOUNTS
    if cwd == mount_parent or mount_parent in cwd.parents:
        return True
    try:
        registry = private_dir(home / REGISTRY)
    except FileNotFoundError:
        return False
    for directory in (cwd, *cwd.parents):
        try:
            record = private_json(registry / record_name(directory))
        except FileNotFoundError:
            continue
        if record != {"cwd": str(directory)}:
            raise OrcaError("Invalid Harness workspace reservation.")
        return True
    return False


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "reserve":
        sys.exit(2)
    try:
        reserve(Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
    except (OrcaError, OSError, ValueError, TypeError):
        sys.exit("remote-harness: could not reserve the native Harness workspace.")
