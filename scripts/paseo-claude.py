#!/usr/bin/env -S python3 -EsB
"""Paseo Claude provider command: only bound chats may use Harness workspaces."""
import json
import os
from pathlib import Path
import subprocess
import sys

from native_workspace import CHAT_REQUIRED, protected
from orca_native import (SESSION_NAME, OrcaError, SessionEnded, active_lease, check_version,
                         claude_command, live_session, private_json, session_presentation)

SESSION_ENV = "RH_CLAUDE_SESSION"
TOKEN_ENV = "RH_CLAUDE_TOKEN"


def main():
    wrapper = Path(os.path.abspath(__file__))
    home = wrapper.parent.parent.resolve()
    command = claude_command(private_json(home / "paseo" / "claude.json"), wrapper)
    args = sys.argv[1:]
    if args == ["check-harness-version"]:
        check_version(command)
        return
    if args in (["--version"], ["-v"], ["--help"], ["-h"]):
        os.execv(command, [str(command), *args])
    cwd = Path.cwd()
    directory = os.environ.get(SESSION_ENV)
    token = os.environ.get(TOKEN_ENV)
    if directory is None and token is None:
        if protected(home, cwd):
            raise OrcaError(CHAT_REQUIRED)
        os.execv(command, [str(command), *args])
    session = Path(directory or "")
    sessions = home / ".sessions"
    if (not session.is_absolute() or session.parent.resolve() != sessions
            or not SESSION_NAME.fullmatch(session.name) or not token):
        raise OrcaError("Invalid Paseo Harness session registration.")
    session = live_session(sessions / session.name)
    lease = active_lease(session / "paseo-lease.json", token)
    if lease.get("provider") != "claude" or lease["cwd"] != str(cwd):
        raise OrcaError(CHAT_REQUIRED)
    # The provider must preserve the guarded settings supplied for this particular chat.
    # Refuse a changed provider default instead of launching without its routing hooks.
    settings = private_json(session / "paseo-claude-settings.json")
    supplied = []
    arguments = iter(args)
    for arg in arguments:
        flag, sep, value = arg.partition("=")
        if flag == "--settings":
            supplied.append(json.loads(value if sep else next(arguments, "")))
        if flag == "--bare":
            raise OrcaError("Paseo's Claude arguments conflict with Harness hooks.")
    if supplied != [settings]:
        raise OrcaError("Paseo's Claude arguments must preserve the registered Harness settings.")
    check_version(command)
    env = os.environ.copy()
    env.update(lease["env"])
    presentation = session_presentation(session, lease)
    keys = (SESSION_ENV, TOKEN_ENV, "SSH_CONNECTION", "SSH_CLIENT")
    if presentation.version:
        keys += ("TZ", "TZDIR")
    for key in keys:
        if key not in lease["env"]:
            env.pop(key, None)
    presentation.environment(env)
    os.execve(command, [str(command), *args], env)


if __name__ == "__main__":
    try:
        main()
    except SessionEnded as error:
        sys.exit(f"remote-harness: {error} Start a new Harness session.")
    except OrcaError as error:
        sys.exit("remote-harness: " + str(error))
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        sys.exit("remote-harness: Paseo Claude launch or lease check failed. Start a new Harness chat.")
