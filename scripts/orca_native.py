#!/usr/bin/env python3
"""Private state shared by the Orca bridge and its Claude command."""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

MOUNTS = ".orca-mounts"
IDENTITIES = ".orca-identities"
LEASE = "orca-lease.json"
CODEX_CHATS = ".orca-codex-chats"
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
SESSION_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
# Orca Server builds whose runtime RPCs and agent launches Harness has been verified against.
# tests/verify-orca-version.sh checks a new build before it is added here.
ORCA_VERSIONS = ("1.4.251", "1.4.254")
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


class OrcaError(Exception):
    pass


def version_support(version, verified):
    """True for a verified build, False for a newer patch of a verified major.minor, else None."""
    if version in verified:
        return True
    match = VERSION.fullmatch(version) if isinstance(version, str) else None
    if match:
        found = tuple(map(int, match.groups()))
        for known in verified:
            known = tuple(map(int, known.split(".")))
            if found[:2] == known[:2] and found[2] > known[2]:
                return False
    return None


def describe_versions(verified):
    lines = dict.fromkeys(".".join(version.split(".")[:2]) for version in verified)
    return f"{' or '.join(verified)}, or a newer {' or '.join(lines)} patch release"


def shown_version(version):
    return version if isinstance(version, str) and VERSION.fullmatch(version) else "an unknown version"


def unverified_warning(product, version, verified):
    return (f"remote-harness: warning: {product} {version} has not been verified with Harness "
            f"(verified: {', '.join(verified)}). Continuing because it is a newer patch release.")


def require_orca_version(version):
    """Return whether the Orca Server build is verified; refuse builds outside the patch policy."""
    support = version_support(version, ORCA_VERSIONS)
    if support is None:
        raise OrcaError(f"Orca Harness requires Orca Server {describe_versions(ORCA_VERSIONS)} "
                        f"(this server runs {shown_version(version)}).")
    return support


def private_dir(path, create=False):
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OrcaError("Orca Harness requires a private, user-owned state directory.")
    return path


def private_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, encoding="utf8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OrcaError("Orca Harness requires a private, user-owned JSON file.")
        value = json.load(stream)
        if not isinstance(value, dict):
            raise OrcaError("Invalid Orca Harness configuration.")
        return value


def write_once(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf8") as stream:
        json.dump(data, stream)


def config(home, agent="claude"):
    path = private_dir(home / "orca") / f"{agent}.json"
    try:
        return private_json(path)
    except FileNotFoundError as error:
        raise OrcaError("Create the private Orca Harness configuration described in docs/orca.md.") from error


def claude_command(configuration, wrapper):
    path = Path(configuration["claude"])
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise OrcaError("Set claude to the absolute path to the executable Claude Code CLI.")
    if path.resolve() == wrapper.resolve():
        raise OrcaError("Set claude to the actual Claude Code CLI in the Orca Harness configuration.")
    return path


def probe_claude(command, flag):
    return subprocess.check_output([str(command), flag], stdin=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, text=True, timeout=8)


def check_version(command):
    version = re.search(r"^(\d+)\.(\d+)\.(\d+)\s+\(Claude Code\)", probe_claude(command, "--version"), re.M)
    if not version or tuple(map(int, version.groups())) < (2, 1, 295):
        raise OrcaError("Orca Harness requires Claude Code 2.1.295 or newer.")


def process_identity(pid):
    output = subprocess.check_output(
        ["/bin/ps", "-ww", "-p", str(pid), "-o", "stat=", "-o", "lstart=", "-o", "args="],
        text=True, timeout=2, stderr=subprocess.DEVNULL,
    )
    state, identity = output.strip().split(maxsplit=1)
    if state[0] in "XZ":
        raise OrcaError("The Orca Harness bridge has ended.")
    return identity


def active_lease(path, token):
    lease = private_json(path)
    pid = lease["pid"]
    if (lease["token"] != token or type(pid) is not int or pid <= 1
            or process_identity(pid) != lease["identity"]):
        raise OrcaError("The Orca Harness bridge has ended.")
    return lease


def reserve(home, label):
    if not SESSION_NAME.fullmatch(label):
        raise OrcaError("Invalid Orca mount reservation.")
    parent = private_dir(home / MOUNTS, create=True)
    path = parent / label
    path.mkdir(mode=0o700)
    return path


def guard():
    try:
        active_lease(Path(sys.argv[2]), sys.argv[3])
        tool = json.load(sys.stdin)["tool_name"]
        if not isinstance(tool, str) or not tool:
            raise ValueError("Missing tool name")
    except (OrcaError, OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        print("Remote Harness transport has ended. Start a new Harness session.", file=sys.stderr)
        return 2
    if tool.startswith("mcp__orca__"):
        print("Orca management tools are disabled for this Harness session.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "guard":
        sys.exit(guard())
    if len(sys.argv) == 4 and sys.argv[1] == "reserve":
        try:
            print(reserve(Path(sys.argv[2]).resolve(strict=True), sys.argv[3]))
        except (OrcaError, OSError):
            sys.exit("remote-harness: could not reserve a unique Orca mount.")
    else:
        sys.exit(2)
