#!/usr/bin/env python3
"""Run one native Orca chat while the reverse Harness owns its transport."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid

from orca_native import (CODEX_CHATS, IDENTITIES, LEASE, MOUNTS, OrcaError, check_version, claude_command,
                         config, private_dir, private_json, probe_claude, process_identity,
                         write_once)

ORCA_VERSION = "1.4.251"
PERMISSION_MODES = {"normal": "ask", "auto": "auto", "yolo": "full-access"}
MAX_FRAME = 8 * 1024 * 1024


class OrcaClient:
    """Orca 1.4.251's same-user, local JSON-lines runtime transport."""

    def __init__(self, configuration):
        default = (Path.home() / "Library" / "Application Support" if sys.platform == "darwin"
                   else Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")))
        profile = Path(configuration.get("profile", default / "orca"))
        if not profile.is_absolute():
            raise OrcaError("Orca profile must be an absolute path on the agent host.")
        info = profile.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise OrcaError("The Orca profile directory must be controlled by this user.")
        metadata = private_json(profile / "orca-runtime.json")
        transports = metadata.get("transports", [metadata.get("transport")])
        self.endpoint = next((transport["endpoint"] for transport in transports
                              if transport and transport["kind"] == "unix"), None)
        self.runtime_id = metadata["runtimeId"]
        self.token = metadata["authToken"]
        if (not self.endpoint or not Path(self.endpoint).is_absolute()
                or not isinstance(self.token, str) or not self.token
                or not isinstance(self.runtime_id, str) or not self.runtime_id):
            raise OrcaError("The Orca Server profile has no authenticated local Unix transport.")

    def call(self, method, params=None, timeout=5):
        request_id = str(uuid.uuid4())
        request = json.dumps({"id": request_id, "authToken": self.token,
                              "method": method, "params": params or {}}).encode() + b"\n"
        deadline = time.monotonic() + timeout
        pending = bytearray()
        try:
            info = os.lstat(self.endpoint)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise OrcaError("The Orca runtime socket is not owned by this user.")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(timeout)
                stream.connect(self.endpoint)
                stream.settimeout(max(0.001, deadline - time.monotonic()))
                stream.sendall(request)
                while time.monotonic() < deadline:
                    stream.settimeout(max(0.001, deadline - time.monotonic()))
                    data = stream.recv(65536)
                    if not data:
                        break
                    pending.extend(data)
                    if len(pending) > MAX_FRAME:
                        break
                    while (newline := pending.find(b"\n")) >= 0:
                        line = pending[:newline]
                        del pending[:newline + 1]
                        if not line.strip():
                            continue
                        frame = json.loads(line)
                        if frame.get("_keepalive") is True:
                            continue
                        if (frame.get("id") != request_id
                                or frame.get("_meta", {}).get("runtimeId") != self.runtime_id):
                            raise OrcaError("The Orca Server runtime identity changed.")
                        if frame.get("ok") is not True:
                            raise OrcaError(f"Orca Server refused {method}.")
                        return frame["result"]
        except (OSError, ValueError, KeyError, AttributeError, TypeError) as error:
            raise OrcaError(f"Orca Server did not complete {method}.") from error
        raise OrcaError(f"Orca Server did not complete {method}.")


def native_create(session_id, fields):
    digest = json.dumps({"method": "agentSession.create", "sessionId": session_id, "fields": fields},
                        ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    envelope = {"sessionId": session_id, "clientOperationId": f"{time.time_ns() // 1_000_000}-{uuid.uuid4().hex}",
                "expectedRuntimeFence": None,
                "payloadFingerprint": hashlib.sha256(digest.encode()).hexdigest()}
    return {"envelope": envelope, **fields}


def check_wrapper(settings, wrapper, agent):
    configured = Path(settings.get("agentCmdOverrides", {}).get(agent) or "")
    if (not configured.is_absolute() or configured.parent.parent.resolve() != wrapper.parent.parent
            or configured.resolve() != wrapper.resolve()):
        raise OrcaError(f"Set the Orca Server {agent.title()} Command to {wrapper} before using --ui orca.")


def project_group(client, home, configuration):
    group_id = configuration.get("projectGroupId")
    # Concurrent first launches must not create duplicate groups.
    lock = os.open(home / "orca" / "group.lock",
                   os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OrcaError("Invalid Orca Harness project-group lock.")
        deadline = time.monotonic() + 12
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise OrcaError("Another Orca Harness launch is preparing the project group.")
                time.sleep(0.1)
        groups = [group for group in client.call("projectGroup.list")["groups"]
                  if not group.get("connectionId")]
        if group_id is not None:
            configured = next((group for group in groups if group["id"] == group_id), None)
            if configured and configured.get("parentPath"):
                return group_id
            raise OrcaError("Configure the ID of a local, folder-backed Orca project group on the agent host.")
        # Orca 1.4.251 omits native folder workspaces from worktree.ps when their
        # group has no parentPath. Desktop clients use that catalog for servers.
        # Keep older pathless groups intact: they may still own a live chat.
        parent = str(home / MOUNTS)
        candidates = [group["id"] for group in groups
                      if group["name"] == "Remote Harness" and group.get("parentPath") == parent]
        if len(candidates) > 1:
            raise OrcaError("More than one Remote Harness group uses the reserved mount directory. Set projectGroupId in the Orca Harness configuration.")
        if candidates:
            return candidates[0]
        return client.call("projectGroup.create", {"name": "Remote Harness", "parentPath": parent})["group"]["id"]
    finally:
        os.close(lock)


def live_workspace(client, workspace, cwd):
    folders = client.call("folderWorkspace.list")["folderWorkspaces"]
    return any(folder["id"] == workspace and not folder.get("isArchived")
               and folder["folderPath"] == str(cwd) for folder in folders)


def visible_chat(client, selector, session_id):
    tabs = client.call("session.tabs.list", {"worktree": selector})["tabs"]
    return any(tab.get("type") == "agent-session" and tab.get("sessionId") == session_id
               for tab in tabs)


def published_workspace(client, workspace, cwd):
    catalog = client.call("worktree.ps", {"limit": 10000,
                                          "supportsWorktreeVisibilitySourceDefaults": True})
    return any(row.get("worktreeId") == f"folder:{workspace}"
               and row.get("path") == str(cwd) and not row.get("isArchived")
               for row in catalog["worktrees"])


def lease_environment(session, agent):
    shim, _, rest = os.environ.get("PATH", "").partition(os.pathsep)
    if not shim or Path(shim).resolve() != session / "bin":
        raise OrcaError("Orca cannot start without the Harness PATH shims.")
    keys = ["SSH_CONNECTION", "SSH_CLIENT"]
    if agent == "claude":
        keys.extend(("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "CLAUDE_CODE_BASH_EDIT_DIFF",
                     "USE_BUILTIN_RIPGREP"))
    env = {key: os.environ[key] for key in keys if key in os.environ}
    env["PATH"] = os.pathsep.join((str(session / "bin"), rest))
    return env


def main():
    approval, python, *args = sys.argv[1:]
    agent = args[0] if args else "claude"
    if agent not in ("claude", "codex"):
        raise OrcaError("Unsupported Orca Harness agent.")
    label = agent.title()
    session = Path(__file__).resolve().parent.parent
    project = (session / "orca-project-title").read_text(encoding="utf8")
    home = session.parent.parent
    cwd = Path.cwd()
    if cwd.parent != private_dir(home / MOUNTS):
        raise OrcaError("Orca Harness requires a reserved per-launch mount.")
    wrapper = home / "scripts" / ("native-codex.py" if agent == "codex" else "orca-claude.py")
    configuration = config(home, agent)
    if not wrapper.is_file() or not os.access(wrapper, os.X_OK):
        raise OrcaError("Install the Orca Harness command wrapper on the agent host.")
    client = OrcaClient(configuration)
    status = client.call("status.get")
    if status.get("appVersion") != ORCA_VERSION:
        raise OrcaError(f"Orca Harness requires Orca Server {ORCA_VERSION}.")
    if status.get("graphStatus") != "ready":
        raise OrcaError("Start Orca Server and wait for its workspace graph to become ready.")
    check_wrapper(client.call("settings.get")["settings"], wrapper, agent)
    launch_settings = {}
    session_id = f"{agent}_{uuid.uuid4().hex}"
    if agent == "claude":
        command = claude_command(configuration, wrapper)
        check_version(command)
        if approval == "auto" and '"auto"' not in probe_claude(command, "--help"):
            print("remote-harness: Claude does not advertise auto. Using normal approvals.", file=sys.stderr)
            approval = "normal"
        launch_settings["claude"] = str(command.resolve())
        provider_id = str(uuid.UUID(bytes=hashlib.sha256(
            f"orca-claude:{session_id}".encode()).digest()[:16], version=4))
    else:
        try:
            subprocess.run([python, "-EsB", str(wrapper), "check-harness-version"], check=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            raise OrcaError("Native Harness Codex requires Python 3.11+, codex-cli 0.167.0 and the private codex.json.") from error
        provider_id = session_id
    lease_path = session / LEASE
    token = str(uuid.uuid4())
    stopped = False
    leased = False
    workspace = None
    create_attempted = closed = False

    def revoke():
        nonlocal leased
        if leased:
            lease_path.unlink(missing_ok=True)
            leased = False

    def stop(_signum, _frame):
        nonlocal stopped
        stopped = True
        revoke()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)

    try:
        group_id = project_group(client, home, configuration)
        if stopped:
            return
        folder = client.call("folderWorkspace.create", {"projectGroupId": group_id,
                             "name": f"Remote Harness · {project}", "folderPath": str(cwd)}, timeout=15)
        folder = folder["folderWorkspace"]
        if (folder["folderPath"] != str(cwd) or folder.get("connectionId")
                or folder["projectGroupId"] != group_id):
            raise OrcaError("Orca returned a different workspace location.")
        workspace = folder["id"]
        if stopped:
            return
        selector = f"id:folder:{workspace}"
        fields = {"agent": agent, "worktree": selector}
        if client.call("agentSession.createSupport", fields).get("supported") is not True:
            raise OrcaError(f"Orca Server cannot create a native {label} chat in this folder.")
        check_wrapper(client.call("settings.get")["settings"], wrapper, agent)
        fields["options"] = {"permissionMode": PERMISSION_MODES[approval]}
        if model := configuration.get("model"):
            fields["options"]["model"] = model
        # Reserve this identity forever. Removing transport state cannot turn an old chat
        # into a normal Claude launch, including a resume from a different working directory.
        registry = private_dir(home / (CODEX_CHATS if agent == "codex" else IDENTITIES), create=True)
        write_once(registry / f"{provider_id}.json", {
            "cwd": str(cwd), "session": session.name, "token": token,
        })
        write_once(lease_path, {
            "token": token, "pid": os.getpid(), "identity": process_identity(os.getpid()),
            "python": python, "approval": approval, "cwd": str(cwd), **launch_settings,
            "env": lease_environment(session, agent),
        })
        leased = True
        if stopped:
            return
        create_attempted = True
        receipt = client.call("agentSession.create", native_create(session_id, fields), timeout=30)
        if receipt.get("ok") is not True or receipt.get("value", {}).get("sessionId") != session_id:
            raise OrcaError(f"Orca Server did not confirm the requested native {label} chat.")
        if stopped:
            return
        if not visible_chat(client, selector, session_id):
            raise OrcaError(f"Orca Server did not publish the native {label} chat.")
        if not published_workspace(client, workspace, cwd):
            raise OrcaError("Orca Server did not publish the Harness workspace in its remote workspace list.")
        print(f"remote-harness: Orca {label} chat {session_id} is ready. Open it in Orca.", flush=True)
        unavailable = None
        while not stopped:
            time.sleep(2)
            if stopped:
                break
            try:
                if not live_workspace(client, workspace, cwd):
                    break
                if not visible_chat(client, selector, session_id):
                    closed = True
                    break
                settings = client.call("settings.get")["settings"]
            except OrcaError:
                unavailable = time.monotonic() if unavailable is None else unavailable
                if time.monotonic() - unavailable >= 20:
                    raise OrcaError("Lost contact with Orca Server. Releasing the Harness session.")
            else:
                unavailable = None
                check_wrapper(settings, wrapper, agent)
    finally:
        revoke()
        if create_attempted and not closed:
            try:
                client.call("agentSession.close", {"sessionId": session_id})
            except OrcaError:
                print("remote-harness: could not confirm chat closure. Its tool lease has ended.", file=sys.stderr)
        if workspace:
            try:
                client.call("folderWorkspace.update", {"folderWorkspaceId": workspace,
                                                       "updates": {"isArchived": True}})
            except OrcaError:
                print("remote-harness: could not archive the Orca Harness workspace.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except OrcaError as error:
        print("remote-harness:", error, file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("remote-harness: Orca bridge setup failed. Check docs/orca.md and the agent host configuration.",
              file=sys.stderr)
    else:
        sys.exit(0)
    sys.exit(1)
