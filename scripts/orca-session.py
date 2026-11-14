#!/usr/bin/env python3
"""Run one native Orca chat while the reverse Harness owns its transport.

The launcher also uses `chats` to list a project's ended chats of one agent and `claim` to bind
one of them to a new launch, which then continues that chat instead of creating one. A terminal
launch of Claude can claim an ended Orca chat too and resume its conversation at the chat's mount;
`adopt` gives a new Orca launch a copy of an ended terminal conversation, which its new chat resumes.
"""
from contextlib import contextmanager
import fcntl
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time
import unicodedata
import uuid

from orca_native import (CODEX_CHATS, IDENTITIES, LEASE, MOUNTS, ORCA_VERSIONS, SESSION_NAME, UUID, OrcaError,
                         check_version, claude_command, config, private_dir, private_json, probe_claude,
                         process_identity, require_orca_version, reserve, unverified_warning, write_once)

# How long Orca Server may stay unreachable, for example while an automatic update restarts it.
RESTART_GRACE = 120
PERMISSION_MODES = {"normal": "ask", "auto": "auto", "yolo": "full-access"}
MAX_FRAME = 8 * 1024 * 1024
WARNED = set()
CLAUDE_CHAT = re.compile(r"claude_[0-9a-f]{32}")
CODEX_CHAT = re.compile(r"codex_[0-9a-f]{32}")
OWNED = "This mount belongs to an earlier Orca chat. Continue that chat from the launcher instead."
CODEX_GONE = "Orca no longer has this Codex chat, so it cannot continue. Start a new chat."
# How the bridge ended, for the launcher's record: 0 when the chat was closed or its workspace
# archived in Orca, 128 + the signal when stopped by one (130 for Ctrl-C in the launcher), LOST when
# Orca Server stayed unreachable, and 1 for any other failure.
LOST = 3
STOPPED_BY = []


class OrcaLost(OrcaError):
    """Orca Server stayed unreachable for longer than RESTART_GRACE."""


class OrcaClient:
    """Orca Server's same-user, local JSON-lines runtime transport."""

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


def envelope(method, session_id, fields, fence=None):
    digest = json.dumps({"method": method, "sessionId": session_id, "fields": fields},
                        ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return {"sessionId": session_id, "clientOperationId": f"{time.time_ns() // 1_000_000}-{uuid.uuid4().hex}",
            "expectedRuntimeFence": fence, "payloadFingerprint": hashlib.sha256(digest.encode()).hexdigest()}


def native_create(session_id, fields):
    return {"envelope": envelope("agentSession.create", session_id, fields), **fields}


def claude_identity(session_id):
    """The Claude session ID Orca launches a native chat with."""
    return str(uuid.UUID(bytes=hashlib.sha256(f"orca-claude:{session_id}".encode()).digest()[:16], version=4))


def session_key(mountpoint):
    """The session directory key that inject-rule.sh derives from a mountpoint."""
    key = re.sub(rb"[^A-Za-z0-9._-]", b"_", os.fsencode(mountpoint)).decode("ascii")
    return "default" if key in ("", ".", "..") else key


@contextmanager
def private_lock(path, busy):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OrcaError("Invalid Orca Harness lock.")
        deadline = time.monotonic() + 12
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise OrcaError(busy)
                time.sleep(0.1)
        yield
    finally:
        os.close(fd)


def replace_record(path, data):
    temporary = path.with_name(f".{path.stem}.{uuid.uuid4().hex}.tmp")
    write_once(temporary, data)
    os.replace(temporary, path)


def check_wrapper(settings, wrapper, agent):
    configured = Path(settings.get("agentCmdOverrides", {}).get(agent) or "")
    if (not configured.is_absolute() or configured.parent.parent.resolve() != wrapper.parent.parent
            or configured.resolve() != wrapper.resolve()):
        raise OrcaError(f"Set the Orca Server {agent.title()} Command to {wrapper} before using --ui orca.")


def project_group(client, home, configuration):
    group_id = configuration.get("projectGroupId")
    # Concurrent first launches must not create duplicate groups.
    with private_lock(home / "orca" / "group.lock",
                      "Another Orca Harness launch is preparing the project group."):
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


def live_workspace(client, workspace, cwd):
    folders = client.call("folderWorkspace.list")["folderWorkspaces"]
    return any(folder["id"] == workspace and not folder.get("isArchived")
               and folder["folderPath"] == str(cwd) for folder in folders)


def visible_chat(client, selector, session_id):
    tabs = client.call("session.tabs.list", {"worktree": selector})["tabs"]
    return any(tab.get("type") == "agent-session" and tab.get("sessionId") == session_id
               for tab in tabs)


def known_chat(client, session_id):
    """Whether the runtime holds the chat. Orca keeps closed chats' history, so open is not implied."""
    result = client.call("agentSession.history", {"sessionId": session_id, "direction": "tail",
                                                  "limit": 1})
    page = result.get("page") if isinstance(result, dict) else None
    return isinstance(page, dict) and page.get("sessionId") == session_id


def published_workspace(client, workspace, cwd):
    catalog = client.call("worktree.ps", {"limit": 10000,
                                          "supportsWorktreeVisibilitySourceDefaults": True})
    return any(row.get("worktreeId") == f"folder:{workspace}"
               and row.get("path") == str(cwd) and not row.get("isArchived")
               for row in catalog["worktrees"])


def require_server_version(status):
    """Refuse an unsupported server build, and say once when an unverified patch build is accepted."""
    version = status.get("appVersion")
    if not require_orca_version(version) and version not in WARNED:
        WARNED.add(version)
        print(unverified_warning("Orca Server", version, ORCA_VERSIONS), file=sys.stderr, flush=True)


def reconnect(configuration, wrapper, agent):
    """Return a client for the runtime the profile now names, once it passes the launch checks."""
    # A restarted server publishes a new socket and runtime ID in its profile.
    try:
        client = OrcaClient(configuration)
        status = client.call("status.get")
        settings = client.call("settings.get")["settings"]
    except (OrcaError, OSError, ValueError, KeyError, TypeError):
        return None
    # An unsupported update or a changed command ends the session instead of waiting.
    require_server_version(status)
    check_wrapper(settings, wrapper, agent)
    return client if status.get("graphStatus") == "ready" else None


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


def chat_records(home, agent):
    """The readable registered chats of one agent as (path, record)."""
    try:
        registry = private_dir(home / (CODEX_CHATS if agent == "codex" else IDENTITIES))
    except FileNotFoundError:
        return []
    records = []
    for path in sorted(registry.glob("*.json")):
        try:
            records.append((path, private_json(path)))
        except (OrcaError, OSError, ValueError):
            continue
    return records


def claimed_chat(home, agent, cwd, session):
    """The earlier chat a launch claimed for this mount; None for a newly reserved mount.

    Reservations are unique, so only a claimed record, written by this user's launcher, names one.
    """
    for kind in ("claude", "codex"):
        for path, record in chat_records(home, kind):
            if record.get("cwd") != str(cwd):
                continue
            if kind != agent or record.get("session") != session.name or record.get("token") != "":
                raise OrcaError(OWNED)
            return path, record
    return None, None


def chat_workspace(folders, cwd):
    matches = [folder for folder in folders
               if folder.get("folderPath") == str(cwd) and not folder.get("connectionId")]
    return matches[0] if len(matches) == 1 else None


def registered_chat(client, path, record, workspace):
    chat = record.get("chat")
    if chat is None and workspace is not None:
        # Records from before chat IDs were kept: an open tab still names the chat.
        tabs = client.call("session.tabs.list", {"worktree": f"id:folder:{workspace['id']}"})["tabs"]
        chat = next((tab["sessionId"] for tab in tabs if tab.get("type") == "agent-session"
                     and isinstance(tab.get("sessionId"), str)
                     and claude_identity(tab["sessionId"]) == path.stem), None)
    return chat if isinstance(chat, str) and CLAUDE_CHAT.fullmatch(chat) else None


def claude_projects():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def claude_project_dir(directory):
    """Where Claude Code keeps the conversations of sessions started in `directory`.

    It names the folder after the sanitized path, cut to 200 characters plus a hash when longer.
    """
    projects = claude_projects()
    name = re.sub(r"[^A-Za-z0-9]", "-", str(directory))
    if len(name) <= 200:
        return projects / name
    found = glob.glob(os.path.join(glob.escape(str(projects)), glob.escape(name[:200]) + "-*"))
    return Path(found[0]) if len(found) == 1 else None


def claude_transcript(cwd, provider):
    """The conversation of the Claude session `provider` started in `cwd`, or None."""
    directory = claude_project_dir(cwd)
    path = directory / f"{provider}.jsonl" if directory is not None else None
    return path if path is not None and path.is_file() else None


def fork_conversation(source, cwd):
    """Copy a Claude conversation to a new session started in `cwd`; return the new session ID.

    Orca resumes only a conversation recorded in the chat's own folder (the cwd its transcript
    names), so a new chat continues a copy: the session ID and the working directories under the
    original one change, the rest is kept, and the original stays as it was.
    """
    directory = claude_project_dir(cwd)
    if directory is None:
        raise OrcaError("The Orca mount path is too long to continue a terminal conversation.")
    provider, original, root, lines = str(uuid.uuid4()), source.stem, None, []
    for line in source.read_bytes().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            entry = None
        if isinstance(entry, dict):
            if entry.get("sessionId") == original:
                entry["sessionId"] = provider
            here = entry.get("cwd")
            if isinstance(here, str):
                root = root or here
                if here == root or here.startswith(root.rstrip("/") + "/"):
                    entry["cwd"] = str(cwd) + here[len(root):]
            line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode()
        lines.append(line + b"\n")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = directory / f"{provider}.jsonl"
    with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as stream:
        stream.writelines(lines)
    info = source.stat()
    os.utime(target, (info.st_atime, info.st_mtime))
    return provider


def text_of(content):
    if isinstance(content, list):
        content = " ".join(block["text"] for block in content if isinstance(block, dict)
                           and block.get("type") == "text" and isinstance(block.get("text"), str))
    return content if isinstance(content, str) else ""


def last_message(items):
    for item in reversed(items):
        body = item.get("body") if isinstance(item, dict) else None
        if isinstance(body, dict) and body.get("kind") == "message" and body.get("role") == "user":
            if (text := text_of(body.get("blocks"))).strip():
                return text
    return ""


def transcript_message(path):
    """The last message the user typed, from the end of a Claude transcript."""
    with path.open("rb") as stream:
        stream.seek(max(0, stream.seek(0, os.SEEK_END) - 262144))
        lines = stream.read().splitlines()
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict) or entry.get("type") != "user" or entry.get("isMeta"):
            continue
        message = entry.get("message")
        text = text_of(message.get("content")) if isinstance(message, dict) else ""
        # Skip tool results, command output and other text Claude Code inserts as user turns.
        if text.strip() and not text.lstrip().startswith("<"):
            return text
    return ""


def shown(text, limit=60):
    """One terminal-safe line: no control, format or unassigned characters."""
    text = " ".join("".join(" " if unicodedata.category(ch).startswith("C") else ch for ch in text).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def codex_state(path):
    """The private state, kept beyond the session, that holds an Orca Codex chat's conversation."""
    return path.with_name(path.stem + ".state")


def codex_conversation(path):
    state = codex_state(path)
    private_dir(state)
    return (state / "thread.json").is_file() and any((state / "sessions").rglob("rollout-*.jsonl"))


def resumable_chats(home, client, project, agent="claude"):
    """Ended chats of one agent that a new launch of this project may continue, newest first.

    A chat continues in its Orca chat when Orca still has it. Otherwise a Claude chat continues in
    a new Orca chat that resumes its Claude conversation; a Codex chat cannot. Without a client
    (a terminal launch) only Claude chats whose conversation Claude Code still has are listed.
    """
    if client is None and agent != "claude":
        return []
    try:
        mounts = private_dir(home / MOUNTS)
    except FileNotFoundError:
        return []
    folders = client.call("folderWorkspace.list")["folderWorkspaces"] if client else []
    named = UUID if agent == "claude" else CODEX_CHAT
    chats = []
    for path, record in chat_records(home, agent):
        try:
            cwd = Path(record["cwd"])
            # A record without a project predates project records; the user identifies it.
            if (not named.fullmatch(path.stem) or cwd.parent != mounts or not SESSION_NAME.fullmatch(cwd.name)
                    or not SESSION_NAME.fullmatch(record["session"])
                    or record.get("project", project) != project):
                continue
            # The earlier session still runs, or its cleanup has not finished yet.
            if os.path.lexists(home / ".sessions" / record["session"]):
                continue
            private_dir(cwd)
            if os.path.ismount(cwd) or any(cwd.iterdir()):
                continue
            workspace = chat_workspace(folders, cwd)
            # A Codex chat's record is named after the chat itself.
            chat = registered_chat(client, path, record, workspace) if agent == "claude" else path.stem
            page = chat and client and client.call("agentSession.history", {
                "sessionId": chat, "direction": "tail", "limit": 20})["page"]
            items = [item for item in page.get("items", []) if isinstance(item, dict)] if page else []
            seen = [item["observedAt"] for item in items if type(item.get("observedAt")) in (int, float)]
            known = bool(workspace and page and page.get("sessionId") == chat)
            transcript = claude_transcript(cwd, path.stem)
            if agent == "codex":
                # Chats from before Codex conversations were kept beyond the session cannot continue.
                if not known or not codex_conversation(path):
                    continue
                last = max(seen) / 1000 if seen else (codex_state(path) / "thread.json").stat().st_mtime
                said = last_message(items)
            elif known and seen:
                last, said = max(seen) / 1000, last_message(items)
            elif transcript is not None:
                last, said = transcript.stat().st_mtime, transcript_message(transcript)
            else:
                continue
            chats.append({"label": cwd.name, "chat": chat, "path": path, "record": record,
                          "last": int(last), "said": shown(said), "recorded": "project" in record})
        except (OrcaError, OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
    return sorted(chats, key=lambda chat: chat["last"], reverse=True)


def terminal_conversations(home, project):
    """Ended Claude conversations of the project's terminal launches, newest first.

    Terminal launches mount the project at <RH_HOME>/mounts/<name>, so Claude Code keeps their
    conversations together. None is listed while that mount is in use, since a running launch may
    still write one. A conversation an Orca chat continues as a copy is listed again only once it
    changed in the terminal after that copy.
    """
    name = project.rstrip("/").rpartition("/")[2]
    if name in ("", ".", ".."):
        return []
    default = home / "mounts" / name
    directory = claude_project_dir(os.path.realpath(default))
    if directory is None or os.path.ismount(default) or not directory.is_dir():
        return []
    copied = {}
    for _, record in chat_records(home, "claude"):
        if isinstance(record.get("from"), str) and type(record.get("created")) is int:
            copied[record["from"]] = max(copied.get(record["from"], 0), record["created"])
    found = []
    for path in directory.glob("*.jsonl"):
        try:
            last = path.stat().st_mtime
            if UUID.fullmatch(path.stem) and copied.get(path.stem, -1) < int(last):
                found.append((last, path))
        except OSError:
            continue
    conversations = []
    for last, path in sorted(found, reverse=True):
        try:
            said = transcript_message(path)
        except OSError:
            continue
        if said.strip():
            conversations.append({"id": path.stem, "last": int(last), "said": shown(said)})
            if len(conversations) == 5:
                break
    return conversations


def list_chats(home, agent, project, ui="orca"):
    if agent not in ("claude", "codex") or ui not in ("orca", "terminal"):
        raise OrcaError("Unsupported Orca Harness agent.")
    client = OrcaClient(config(home, agent)) if ui == "orca" else None
    for chat in resumable_chats(home, client, project, agent)[:9]:
        print(f"RH_ORCA_CHAT={chat['label']}\t{chat['last']}\t{int(chat['recorded'])}\t{chat['said']}")
    if ui == "orca" and agent == "claude":
        for conversation in terminal_conversations(home, project):
            print(f"RH_TERMINAL_CHAT={conversation['id']}\t{conversation['last']}\t{conversation['said']}")


def claim_chat(home, agent, label, sid, project, ui="orca"):
    """Bind an ended chat to the launch `sid`, whose bridge then continues it.

    A terminal launch of Claude resumes the chat's conversation itself, at the chat's mount. Its
    claim names the terminal session, so no Orca chat can run with it until that launch ends.
    """
    if agent not in ("claude", "codex") or ui not in ("orca", "terminal") or (ui, agent) == ("terminal", "codex"):
        raise OrcaError("Unsupported Orca Harness agent.")
    if not SESSION_NAME.fullmatch(label) or not SESSION_NAME.fullmatch(sid):
        raise OrcaError("Invalid Orca chat or launch name.")
    client = OrcaClient(config(home, agent)) if ui == "orca" else None
    with private_lock(home / "orca" / "resume.lock", "Another launch is continuing an Orca chat."):
        chat = next((chat for chat in resumable_chats(home, client, project, agent)
                     if chat["label"] == label), None)
        if chat is None:
            raise OrcaError(f"Orca chat {label} cannot be continued here. It may belong to another "
                            "project, its earlier launch may still be running, or Orca no longer has it.")
        cwd = Path(chat["record"]["cwd"])
        # The launch's bridge sets a new token; until then the chat has no tool lease.
        record = {**chat["record"], "session": f"{session_key(cwd)}.{sid}", "token": "",
                  "agent": agent, "project": project}
        if chat["chat"]:
            record["chat"] = chat["chat"]
        replace_record(chat["path"], record)
    return cwd, chat["path"].stem


def adopt_conversation(home, agent, conversation, sid, project):
    """Reserve the Orca mount of launch `sid` for a copy of an ended terminal conversation.

    The identity record names the copy, so the bridge resumes it in a new chat, and from then on it
    continues as that Orca chat, from Orca or from a terminal launch.
    """
    if agent != "claude":
        raise OrcaError("Only a Claude conversation from a terminal launch can continue in Orca.")
    if not UUID.fullmatch(conversation) or not SESSION_NAME.fullmatch(sid):
        raise OrcaError("Invalid conversation or launch name.")
    with private_lock(home / "orca" / "resume.lock", "Another launch is continuing an Orca chat."):
        if not any(item["id"] == conversation for item in terminal_conversations(home, project)):
            raise OrcaError(f"Conversation {conversation} cannot continue in Orca. It may belong to another "
                            "project, a terminal launch may still use the project, or an Orca chat "
                            "already continues it.")
        source = claude_project_dir(os.path.realpath(home / "mounts" / project.rstrip("/").rpartition("/")[2]))
        cwd = reserve(home, sid)
        provider = fork_conversation(source / f"{conversation}.jsonl", cwd)
        registry = private_dir(home / IDENTITIES, create=True)
        write_once(registry / f"{provider}.json", {
            "cwd": str(cwd), "session": f"{session_key(cwd)}.{sid}", "token": "", "agent": agent,
            "project": project, "created": int(time.time()), "from": conversation,
        })
    return cwd


def set_permission_mode(client, session_id, mode):
    """Make the chat's own approval mode match this launch, as for a new chat."""
    if client.call("agentSession.options", {"sessionId": session_id})["current"].get("permissionMode") == mode:
        return
    fence = client.call("agentSession.history", {"sessionId": session_id, "direction": "tail",
                                                 "limit": 1})["page"].get("fence")
    fields = {"key": "permissionMode", "value": mode}
    client.call("agentSession.setOption",
                {"envelope": envelope("agentSession.setOption", session_id, fields, fence), **fields}, timeout=15)
    if client.call("agentSession.options", {"sessionId": session_id})["current"].get("permissionMode") != mode:
        raise OrcaError("Orca did not apply this launch's approval mode to the chat.")


def main():
    approval, python, *args = sys.argv[1:]
    agent = args[0] if args else "claude"
    if agent not in ("claude", "codex"):
        raise OrcaError("Unsupported Orca Harness agent.")
    label = agent.title()
    session = Path(__file__).resolve().parent.parent
    title = (session / "orca-project-title").read_text(encoding="utf8")
    try:
        project = (session / "orca-project").read_text(encoding="utf8")
    except FileNotFoundError:
        project = None
    home = session.parent.parent
    cwd = Path.cwd()
    if cwd.parent != private_dir(home / MOUNTS):
        raise OrcaError("Orca Harness requires a reserved per-launch mount.")
    wrapper = home / "scripts" / ("native-codex.py" if agent == "codex" else "orca-claude.py")
    configuration = config(home, agent)
    if not wrapper.is_file() or not os.access(wrapper, os.X_OK):
        raise OrcaError("Install the Orca Harness command wrapper on the agent host.")
    # A launch either continues the chat it claimed for this mount or creates a new chat.
    record_path, resumed = claimed_chat(home, agent, cwd, session)
    client = OrcaClient(configuration)
    status = client.call("status.get")
    require_server_version(status)
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
        # Record the configured path, not its target: Claude's self-update repoints the symlink.
        launch_settings["claude"] = str(command)
        provider_id = claude_identity(session_id)
    else:
        try:
            subprocess.run([python, "-EsB", str(wrapper), "check-harness-version"], check=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            raise OrcaError("Native Harness Codex requires Python 3.11+, a supported codex-cli and the private codex.json.") from error
        provider_id = session_id
    if resumed:
        # The Claude conversation keeps its session; the Orca chat may be a new one. A Codex
        # chat's record is named after the chat, which must still exist in Orca.
        provider_id = record_path.stem
        if not (UUID if agent == "claude" else CODEX_CHAT).fullmatch(provider_id):
            raise OrcaError("Invalid registration of the Orca chat to continue.")
    lease_path = session / LEASE
    token = str(uuid.uuid4())
    stopped = False
    leased = False
    workspace = None
    create_attempted = closed = False

    def grant():
        nonlocal leased
        write_once(lease_path, {
            "token": token, "pid": os.getpid(), "identity": process_identity(os.getpid()),
            "python": python, "approval": approval, "cwd": str(cwd), **launch_settings,
            "env": lease_environment(session, agent),
        })
        leased = True

    def revoke():
        nonlocal leased
        if leased:
            lease_path.unlink(missing_ok=True)
            leased = False

    def stop(signum, _frame):
        nonlocal stopped
        stopped = True
        STOPPED_BY.append(signum)
        revoke()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)

    try:
        group_id = project_group(client, home, configuration)
        if stopped:
            return
        folder = resumed and chat_workspace(client.call("folderWorkspace.list")["folderWorkspaces"], cwd)
        if resumed and not folder and agent == "codex":
            raise OrcaError(CODEX_GONE)
        if not folder:
            folder = client.call("folderWorkspace.create", {"projectGroupId": group_id,
                                 "name": f"Remote Harness · {title}", "folderPath": str(cwd)}, timeout=15)
            folder = folder["folderWorkspace"]
            if (folder["folderPath"] != str(cwd) or folder.get("connectionId")
                    or folder["projectGroupId"] != group_id):
                raise OrcaError("Orca returned a different workspace location.")
        workspace = folder["id"]
        if stopped:
            return
        selector = f"id:folder:{workspace}"
        revealed = None
        if resumed:
            if folder.get("isArchived"):
                client.call("folderWorkspace.update", {"folderWorkspaceId": workspace,
                                                       "updates": {"isArchived": False}})
            chat = resumed.get("chat") if agent == "claude" else provider_id
            if isinstance(chat, str) and (CLAUDE_CHAT if agent == "claude" else CODEX_CHAT).fullmatch(chat):
                try:
                    revealed = client.call("agentSession.reveal", {"sessionId": chat}, timeout=15)
                except OrcaError:
                    revealed = None
        if revealed and revealed.get("ok") is True:
            # Orca still has the chat: reopen it with this launch's approval mode.
            session_id = chat
            create_attempted = True
            if revealed.get("workspaceId") != f"folder:{workspace}" or revealed.get("agent") != agent:
                raise OrcaError(f"Orca Server reopened the native {label} chat somewhere else.")
            set_permission_mode(client, session_id, PERMISSION_MODES[approval])
            check_wrapper(client.call("settings.get")["settings"], wrapper, agent)
            grant()
            replace_record(record_path, {**resumed, "token": token})
        else:
            if resumed and agent == "codex":
                raise OrcaError(CODEX_GONE)
            fields = {"agent": agent, "worktree": selector}
            if resumed:
                # Orca no longer has the chat here: continue its Claude conversation in a new chat.
                fields["resumeFrom"] = {"providerSessionId": provider_id}
            if client.call("agentSession.createSupport", fields).get("supported") is not True:
                raise OrcaError(f"Orca Server cannot create a native {label} chat in this folder.")
            check_wrapper(client.call("settings.get")["settings"], wrapper, agent)
            fields["options"] = {"permissionMode": PERMISSION_MODES[approval]}
            if model := configuration.get("model"):
                fields["options"]["model"] = model
            if resumed:
                replace_record(record_path, {**resumed, "token": token, "chat": session_id})
            else:
                # Reserve this identity forever. Removing transport state cannot turn an old chat
                # into a normal Claude launch, including a resume from a different working directory.
                # Only a later launch that claims the chat in the local terminal continues it.
                registry = private_dir(home / (CODEX_CHATS if agent == "codex" else IDENTITIES), create=True)
                write_once(registry / f"{provider_id}.json", {
                    "cwd": str(cwd), "session": session.name, "token": token, "chat": session_id,
                    "agent": agent, "project": project, "created": int(time.time()),
                })
            grant()
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
        if resumed:
            print(f"remote-harness: Orca {label} chat {session_id} is ready again. Continue it in Orca.", flush=True)
        else:
            print(f"remote-harness: Orca {label} chat {session_id} is ready. Open it in Orca.", flush=True)
        unavailable = None
        confirmed = client.runtime_id  # the runtime that last listed this chat
        while not stopped:
            time.sleep(2)
            if stopped:
                break
            try:
                live = live_workspace(client, workspace, cwd)
                visible = live and visible_chat(client, selector, session_id)
                # A restarted runtime publishes chat tabs again only as clients reconcile, so until it
                # lists this chat, a live workspace that still holds the chat keeps the session.
                restoring = (live and not visible and client.runtime_id != confirmed
                             and known_chat(client, session_id))
                settings = client.call("settings.get")["settings"]
            except OrcaError:
                client = reconnect(configuration, wrapper, agent) or client
            else:
                check_wrapper(settings, wrapper, agent)
                if visible:
                    confirmed = client.runtime_id
                if visible or restoring:
                    unavailable = None
                    continue
                # The chat tab was closed, or the workspace was archived.
                closed = live
                break
            unavailable = time.monotonic() if unavailable is None else unavailable
            if time.monotonic() - unavailable >= RESTART_GRACE:
                raise OrcaLost("Lost contact with Orca Server. Releasing the Harness session.")
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
        if sys.argv[1:2] == ["chats"] and len(sys.argv) in (5, 6):
            list_chats(Path(sys.argv[2]).resolve(strict=True), *sys.argv[3:])
        elif sys.argv[1:2] == ["claim"] and len(sys.argv) in (7, 8):
            mountpoint, conversation = claim_chat(Path(sys.argv[2]).resolve(strict=True), *sys.argv[3:])
            print(f"MOUNTPOINT={mountpoint}")
            if sys.argv[7:] == ["terminal"]:
                print(f"RESUME={conversation}")
        elif sys.argv[1:2] == ["adopt"] and len(sys.argv) == 7:
            print(f"MOUNTPOINT={adopt_conversation(Path(sys.argv[2]).resolve(strict=True), *sys.argv[3:])}")
        else:
            main()
    except OrcaLost as error:
        print("remote-harness:", error, file=sys.stderr)
        sys.exit(LOST)
    except OrcaError as error:
        print("remote-harness:", error, file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("remote-harness: Orca bridge setup failed. Check docs/orca.md and the agent host configuration.",
              file=sys.stderr)
    else:
        sys.exit(128 + STOPPED_BY[0] if STOPPED_BY else 0)
    sys.exit(1)
