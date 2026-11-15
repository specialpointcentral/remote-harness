#!/usr/bin/env python3
"""Private state shared by the Orca bridge and its Claude command."""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import hashlib

MOUNTS = ".orca-mounts"
IDENTITIES = ".orca-identities"
LEASE = "orca-lease.json"
CODEX_CHATS = ".orca-codex-chats"
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
SESSION_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
# All distinct released injectors from native Paseo support through the pre-policy release.
# Absence alone cannot establish legacy: the private read-only frozen injector must match.
LEGACY_INJECTORS = {
    "cb443bbdf71517a756725e597967deed1444b1cd1880499fcc708a42c99af640",  # 63812a7
    "b36c4866a7d82189d77921e8dc82009d3907b6396c0861338e8963aaba7c4762",  # fb9f647
    "b195f108a426286afeeffaaf84022b08e8f7792c7133638dc0f7d5cfa13d4d79",  # aa996d4
    "fa3a980d590d097ed17982bd9a1cb3ffcdbdf04ae953eb307f900aa5f905514f",  # cd0b002
    "110133d4c480adbdbb93046ad369d7b6700628cc4a206b2b6823ac55467fcab8",  # a4e700b
    "ddca14f9c727b2f6e49f5bf42d4eb4650e173d10a174406fad55d8a9467f6177",  # 46e1d99
    "64f441e5ca485fe18a098fa37f3e157fb854cebed0c71554a1d6eeaefc6db297",  # 512b730
    "d744b9def3de1a8e8f9d210717b3d3954254f5fca320c56240b85f75f0e5eef9",  # 65a8567
}
# Orca Server builds whose runtime RPCs and agent launches Harness has been verified against.
# tests/verify-orca-version.sh checks a new build before it is added here.
ORCA_VERSIONS = ("1.4.251", "1.4.254")
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


class OrcaError(Exception):
    pass


class SessionEnded(OrcaError):
    """The chat's Harness session ended; its launcher's cleanup removed the session and lease."""

    def __init__(self):
        super().__init__("This Harness session has ended.")


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


def process_identity(pid, utc=True):
    output = subprocess.check_output(
        ["/bin/ps", "-ww", "-p", str(pid), "-o", "stat=", "-o", "lstart=", "-o", "args="],
        text=True, timeout=2, stderr=subprocess.DEVNULL,
        env=dict(os.environ, TZ="UTC", TZDIR="/usr/share/zoneinfo", LC_ALL="C") if utc else None,
    )
    state, identity = output.strip().split(maxsplit=1)
    if state[0] in "XZ":
        raise SessionEnded()
    return "UTC:" + identity if utc else identity


def live_session(path):
    """The private directory of a running Harness session."""
    try:
        return private_dir(private_dir(path.parent) / path.name)
    except FileNotFoundError as error:
        raise SessionEnded() from error


def active_lease(path, token):
    try:
        lease = private_json(path)
        pid = lease["pid"]
        if (lease["token"] != token or type(pid) is not int or pid <= 1 or not isinstance(lease["identity"], str)
                or process_identity(pid, utc=lease["identity"].startswith("UTC:")) != lease["identity"]):
            raise SessionEnded()
    except FileNotFoundError as error:
        raise SessionEnded() from error
    except subprocess.CalledProcessError as error:  # ps found no such process
        raise SessionEnded() from error
    return lease


class LegacyPresentation:
    version = 0

    def environment(self, env):
        return env


def session_presentation(session, lease):
    """Require a policy, except for a positively identified pre-policy implementation snapshot."""
    marker = session / "presentation-policy.json"
    declared = lease.get("presentation_policy")
    if os.path.lexists(marker):
        manifest = private_json(marker)
        if set(manifest) != {"version", "presentation_policy"} or manifest["version"] != 1:
            raise OrcaError("Invalid Harness presentation policy registration.")
        expected = manifest["presentation_policy"]
        if declared is not None and declared != expected:
            raise OrcaError("Harness lease presentation policy changed.")
        declared = expected
    if declared is not None and (type(declared) is not int or declared not in (1, 2, 3)):
        raise OrcaError("Unsupported Harness presentation policy registration.")
    policy = session / "privacy.json"
    if (declared is not None or os.path.lexists(policy)
            or os.path.lexists(session / "impl" / "session_privacy.py")):
        from session_privacy import Policy
        result = Policy(policy)
        if declared is not None and result.version != declared:
            raise OrcaError("Harness presentation policy version changed.")
        return result
    # Do not downgrade an incomplete/damaged current session to legacy semantics.
    snapshot = private_dir(session / "impl") / "inject-rule.sh"
    fd = os.open(snapshot, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o500 or info.st_size > 256 * 1024
                or hashlib.sha256(stream.read()).hexdigest() not in LEGACY_INJECTORS):
            raise OrcaError("Unrecognized legacy Harness implementation. Start a new session.")
    return LegacyPresentation()


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
