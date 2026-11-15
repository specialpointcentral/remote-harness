#!/usr/bin/env -S python3 -EsB
"""The saved Orca Claude Command. Inject Harness settings only for a bound native chat."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

from native_workspace import CHAT_REQUIRED, protected
from orca_native import (IDENTITIES, LEASE, MOUNTS, SESSION_NAME, UUID, OrcaError, SessionEnded,
                         active_lease, check_version, claude_command, config, live_session, private_dir,
                         private_json, require_orca_version)

# These conflict with the Harness route or change the transcript identity. Orca's stream-json
# flags and account environment pass through. Only the selected Harness chat is subject to this.
CONFLICTS = {
    "--append-system-prompt", "--append-system-prompt-file", "--system-prompt", "--system-prompt-file",
    "--bare", "--sdk-url", "--fork-session", "--resume-session-at", "--continue", "-c",
    "--worktree", "-w", "--agent", "--agents", "--teammate-mode",
}
MODE_FLAGS = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"}
MODES = {"normal": ["--permission-mode", "default"], "auto": ["--permission-mode", "auto"],
         "yolo": ["--dangerously-skip-permissions"]}
IDENTITY_FLAGS = {"--session-id", "--resume", "-r"}


def identities(args):
    result = []
    for index, arg in enumerate(args):
        if arg == "--":
            break
        flag, separator, value = arg.partition("=")
        if flag in IDENTITY_FLAGS:
            result.append(value if separator else (args[index + 1] if index + 1 < len(args) else ""))
    return result


def bound_identity(home, args):
    directory = home / IDENTITIES
    for candidate in args:
        # Check uppercase UUID spellings as well, since Claude accepts them at its CLI boundary.
        candidate = candidate.lower()
        if UUID.fullmatch(candidate):
            try:
                private_dir(directory)
                return candidate, private_json(directory / (candidate + ".json"))
            except FileNotFoundError:
                continue
    return None, None


def protected_args(args, approval):
    result = []
    settings = {}
    arguments = iter(args)
    for arg in arguments:
        flag, sep, value = arg.partition("=")
        if flag == "--permission-mode":
            value = value if sep else next(arguments, "")
            if not value or value.startswith("-"):
                raise OrcaError("Invalid Orca permission mode argument.")
        elif flag == "--settings":
            # Orca 1.4.251 and 1.4.254 emit a native per-chat fastMode setting even when it is false.
            value = value if sep else next(arguments, "")
            try:
                extra = json.loads(value)
            except ValueError as error:
                raise OrcaError("Orca's Claude Arguments contain conflicting --settings.") from error
            if (settings or not isinstance(extra, dict) or set(extra) != {"fastMode"}
                    or type(extra["fastMode"]) is not bool):
                raise OrcaError("Orca's Claude Arguments contain conflicting --settings.")
            settings = extra
        elif flag in CONFLICTS or flag == "--":
            raise OrcaError("Orca's Claude Arguments conflict with the Harness routing or identity.")
        elif flag == "--setting-sources":
            value = value if sep else next(arguments, "")
            if value != "user,project,local":
                raise OrcaError("Orca's Claude settings sources conflict with the Harness launch.")
            result.append(f"--setting-sources={value}")
        elif flag not in MODE_FLAGS:
            result.append(arg)
    return result + MODES[approval], settings


def main():
    wrapper = Path(os.path.abspath(__file__))
    home = wrapper.parent.parent.resolve()
    command = claude_command(config(home), wrapper)
    args = sys.argv[1:]
    cwd = Path.cwd()
    mount_parent = home / MOUNTS
    if args in (["--version"], ["-v"], ["--help"], ["-h"]):
        os.execv(command, [str(command), *args])
    ids = identities(args)
    identity, record = bound_identity(home, ids)
    if cwd != mount_parent and mount_parent not in cwd.parents and record is None:
        if protected(home, cwd):
            raise OrcaError(CHAT_REQUIRED)
        os.execv(command, [str(command), *args])
    if record is None or ids != [identity] or record["cwd"] != str(cwd) or cwd.parent != mount_parent:
        raise OrcaError(CHAT_REQUIRED)
    # A restarted Orca Server can resume this chat before the bridge has checked the new build.
    require_orca_version(os.environ.get("ORCA_APP_VERSION"))
    private_dir(mount_parent)
    session_name = record["session"]
    if not SESSION_NAME.fullmatch(session_name):
        raise OrcaError("Invalid Orca Harness session registration.")
    session = live_session(home / ".sessions" / session_name)
    lease_path = session / LEASE
    token = record["token"]
    lease = active_lease(lease_path, token)
    # A self-update repoints the configured path, which stays valid; check_version still applies.
    # Bridges before this change recorded the resolved target instead.
    if Path(lease["claude"]) not in (command, command.resolve()):
        raise OrcaError("The configured Claude command changed. Start a new Harness session.")
    check_version(command)

    settings = private_json(session / "claude-settings.json")
    guard = shlex.join([lease["python"], "-I", "-S", str(session / "impl" / "orca_native.py"),
                        "guard", str(lease_path), token])
    settings["hooks"]["PreToolUse"].insert(0, {
        "hooks": [{"type": "command", "command": guard, "timeout": 5, "onFailure": "block"}],
    })
    protected_paths = [home / name for name in ("orca", IDENTITIES, ".paseo-workspaces", "scripts")]
    settings["permissions"]["deny"].extend(
        f"{tool}(/{path}/**)" for path in protected_paths for tool in ("Read", "Edit"))
    argv, orca_settings = protected_args(args, lease["approval"])
    settings.update(orca_settings)
    settings_json = json.dumps(settings, separators=(",", ":"))
    rule = (session / "rule.md").read_text(encoding="utf8")
    env = os.environ.copy()
    env.update(lease["env"])
    from orca_native import session_presentation
    presentation = session_presentation(session, lease)
    keys = ("SSH_CONNECTION", "SSH_CLIENT") + (("TZ", "TZDIR") if presentation.version else ())
    for key in keys:
        if key not in lease["env"]:
            env.pop(key, None)
    presentation.environment(env)
    os.execve(command, [str(command), *argv, "--settings", settings_json,
                        "--append-system-prompt", rule], env)


if __name__ == "__main__":
    try:
        main()
    except SessionEnded as error:
        print("remote-harness:", error, "To continue this chat, start a new Orca Harness launch for "
              "the project and choose the chat when the launcher offers it.", file=sys.stderr)
    except OrcaError as error:
        print("remote-harness:", error, file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("remote-harness: Orca Claude launch refused. Check the configuration and start a new Harness session.",
              file=sys.stderr)
    sys.exit(1)
