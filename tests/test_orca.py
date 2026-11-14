#!/usr/bin/env python3
"""Exercise the reverse launch, local Orca RPC boundary, and real Claude wrapper."""
import hashlib
import json
import fcntl
import os
import pty
import re
import select
import struct
import termios
from pathlib import Path
import shlex
import shutil
import socketserver
import subprocess
import threading
import time
import unittest
import uuid

from test_paseo import PaseoFixture, SCRIPTS

REFUSED = "requires Orca Server 1.4.251 or 1.4.254, or a newer 1.4 patch release"


class OrcaOptionTests(PaseoFixture):
    def test_public_bootstrap_passes_orca_to_reverse_launcher(self):
        local = self.home / "local"
        local.mkdir()
        for name in ("simple-bootstrap.sh", "simple-dispatch.sh", "simple-laptop-setup.sh", "_common.sh"):
            shutil.copy2(SCRIPTS / name, local)
        self.script("ssh", "printf 'PORT=27678\\nCONFIG=/remote/ssh_config\\n'\n")
        shutil.copy2(self.script("record", 'printf "%s\\n" "$@" > "$HOME/launch"\n'),
                     local / "laptop-setup.sh")
        self.env.update(RH_SIMPLE_CACHE=str(self.home / "cache"), RH_LOCAL_SSHD="system")
        result = subprocess.run(
            ["bash", str(local / "simple-bootstrap.sh"), "--mode", "reverse", "--via", "testbox",
             "--launch", "claude", "--ui", "orca", "--approval", "normal"],
            cwd=self.home, input="y\n", env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        launch = (self.home / "launch").read_text().splitlines()
        self.assertEqual(launch[launch.index("--ui") + 1], "orca")
        self.assertNotIn("--remote-mountpoint", launch)

    def test_public_bootstrap_rejects_other_providers(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "simple-bootstrap.sh"), "--mode", "reverse",
             "--launch", "opencode", "--ui", "orca"],
            env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--ui orca requires --launch claude or codex", result.stderr)

    def test_explicit_mount_is_refused_before_ssh(self):
        self.script("ssh", 'touch "$HOME/ssh-ran"\nexit 1\n')
        for name, args in (("simple-laptop-setup.sh", []), ("laptop-setup.sh", ["--port", "27678"])):
            with self.subTest(name=name):
                result = subprocess.run(
                    ["bash", str(SCRIPTS / name), *args, "--launch", "claude", "--ui", "orca",
                     "--remote-mountpoint", "/existing/project"], env=self.env,
                    input="", text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--remote-mountpoint", result.stderr)
                self.assertFalse((self.home / "ssh-ran").exists())

    def menu(self, *keys, options=("New chat", "rev.one · 1 h ago · first", "rev.two · 2 d ago · second"),
             columns=100):
        """Drive pick_menu in a pseudo-terminal, as the launcher does, and return the picked index."""
        script = '. "$1"; shift; pick=$(pick_menu "Continue?" "$@"); printf "\\nPICK=%s\\n" "$pick"'
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", "-c", script, "menu", str(SCRIPTS / "_common.sh"), *options],
                       {**self.env, "TERM": "xterm", "LC_ALL": "C.UTF-8"})
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
        output = bytearray()

        def read_until(pattern):
            deadline = time.monotonic() + 10
            while not re.search(pattern, output) and time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(fd, 4096))
                    except OSError:
                        break
            match = re.search(pattern, output)
            self.assertIsNotNone(match, output.decode(errors="replace"))
            return match
        read_until(re.escape(options[-1][:6].encode()))
        for key in keys:
            os.write(fd, key)
            time.sleep(0.2)
        pick = int(read_until(rb"PICK=(\d+)\r?\n").group(1))
        os.waitpid(pid, 0)
        os.close(fd)
        return pick, output.decode()

    def test_launcher_menu_picks_with_arrow_keys(self):
        self.assertEqual(self.menu(b"\r")[0], 0)
        self.assertEqual(self.menu(b"\x1b[B", b"\x1b[B", b"\x1b[A", b"\r")[0], 1)
        self.assertEqual(self.menu(b"\x1bOA", b"\r")[0], 2)  # wraps; application cursor keys
        self.assertEqual(self.menu(b"j", b"j", b"\r")[0], 2)
        self.assertEqual(self.menu(b"\x1b[B", b"\x1b")[0], 0)  # Esc keeps the first option
        self.assertEqual(self.menu(b"\x1b[B", b"q")[0], 0)
        pick, text = self.menu(b"\x1b[B", b"\r", options=("新建会话", "rev.one · 继续" + "很长的中文消息" * 8),
                               columns=40)
        self.assertEqual(pick, 1)
        line = next(line for line in text.splitlines() if "rev.one" in line)
        self.assertIn("…", line)
        self.assertLessEqual(len(line.split("rev.one")[1]), 17)


def provider_id(session_id):
    return str(uuid.UUID(bytes=hashlib.sha256(f"orca-claude:{session_id}".encode()).digest()[:16],
                         version=4))


class OrcaSocket(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline())
        if request["authToken"] != "local-fixture-token":
            return
        method, params = request["method"], request.get("params", {})
        fixture = self.server.fixture
        result = fixture.respond(method, params)
        frame = {"id": request["id"], "ok": True, "result": result,
                 "_meta": {"runtimeId": self.server.runtime_id}}
        self.wfile.write((json.dumps(frame) + "\n").encode())


class OrcaBridgeTests(PaseoFixture):
    def setUp(self):
        super().setUp()
        self.rh.mkdir()
        # Install the real wrapper and bridge as manage.sh does.
        shutil.copytree(SCRIPTS, self.rh / "scripts")
        self.scripts = self.rh / "scripts"
        self.wrapper = self.scripts / "orca-claude.py"
        self.transport = self.rh / ".sessions" / "transport"
        self.transport.mkdir(parents=True)
        self.config = self.transport / "ssh_config"
        self.config.touch()
        self.script("ssh", "exit 1\n")
        cli = self.script("claude", """if [ "${1:-}" = --version ]; then
  echo '2.1.319 (Claude Code)'
elif [ "${1:-}" = --help ]; then
  echo 'permissions: "auto"'
else
  exec python3 -c 'import json, os, sys; print(json.dumps(dict(args=sys.argv[1:], env=dict(os.environ))))' "$@"
fi
""")
        self.profile = self.home / "profile"
        self.profile.mkdir()
        bridge_config = self.rh / "orca"
        bridge_config.mkdir(mode=0o700)
        (bridge_config / "claude.json").write_text(json.dumps({
            "claude": str(cli), "profile": str(self.profile), "projectGroupId": "group",
        }))
        (bridge_config / "claude.json").chmod(0o600)
        self.hide_tabs = self.forget_chats = False
        self.start_runtime("fixture-runtime")
        self.mounts = self.rh.resolve() / ".orca-mounts"
        self.mounts.mkdir(mode=0o700)
        self.groups = [{"id": "group", "name": "Remote Harness", "connectionId": None,
                        "parentPath": str(self.mounts)}]
        self.publish_workspaces = True
        self.workspaces = {}
        self.requests = []
        self.sessions = {}
        self.closed = set()
        self.modes = {}
        self.command = str(self.wrapper)
        self.version = "1.4.251"
        self.env.update(RH_WARM_MAX="0", RH_HEARTBEAT_TIMEOUT="0", ORCA_APP_VERSION="1.4.251",
                        ORCA_PAIRING_CODE="do-not-use", ORCA_ENVIRONMENT="do-not-use",
                        CLAUDE_CODE_BASH_EDIT_DIFF="1",
                        SSH_CONNECTION="192.0.2.12 12000 192.0.2.2 22")

    def respond(self, method, params):
        self.requests.append((method, params))
        if method == "status.get":
            return {"appVersion": self.version, "graphStatus": "ready",
                    "runtimeId": self.server.runtime_id}
        if method == "settings.get":
            return {"settings": {"agentCmdOverrides": {"claude": self.command}}}
        if method == "projectGroup.list":
            return {"groups": self.groups}
        if method == "projectGroup.create":
            group = {"id": "created-group", **params}
            self.groups.append(group)
            return {"group": group}
        if method == "folderWorkspace.create":
            identity = "folder-id-" + str(len(self.workspaces))
            folder = {"id": identity, **params, "isArchived": False, "connectionId": None}
            self.workspaces[identity] = folder
            return {"folderWorkspace": folder}
        if method == "folderWorkspace.list":
            return {"folderWorkspaces": list(self.workspaces.values())}
        if method == "worktree.ps":
            backed_groups = {group["id"] for group in self.groups if group.get("parentPath")}
            return {"worktrees": [
                {"worktreeId": "folder:" + folder["id"], "path": folder["folderPath"],
                 "isArchived": folder["isArchived"]}
                for folder in self.workspaces.values()
                if self.publish_workspaces and folder["projectGroupId"] in backed_groups
            ]}
        if method == "folderWorkspace.update":
            folder = self.workspaces[params["folderWorkspaceId"]]
            folder.update(params["updates"])
            return {"folderWorkspace": folder}
        if method == "agentSession.createSupport":
            return {"supported": True}
        if method == "agentSession.create":
            identity = params["envelope"]["sessionId"]
            self.sessions[params["worktree"]] = identity
            self.modes[identity] = params["options"]["permissionMode"]
            return {"ok": True, "value": {"sessionId": identity, "tabId": "agent-session:" + identity,
                                           "page": {"items": []}}}
        if method == "session.tabs.list":
            identity = self.sessions[params["worktree"]]
            tabs = [] if identity in self.closed or self.hide_tabs else [
                {"type": "agent-session", "sessionId": identity, "status": "idle"}]
            return {"tabs": tabs}
        if method == "agentSession.close":
            self.closed.add(params["sessionId"])
            return {"ok": True}
        if method == "agentSession.history":
            # Orca keeps a closed chat's history, so only a forgotten chat lacks a page.
            known = params["sessionId"] in self.sessions.values() and not self.forget_chats
            item = {"itemId": "orca:1", "observedAt": 1794500000000, "body": {
                "kind": "message", "role": "user",
                "blocks": [{"type": "text", "text": "where were we?\x1b[2J\u202e"}]}}
            page = {"sessionId": params["sessionId"], "fence": 1, "items": [item]}
            return {"ok": True, "page": page if known else {}}
        if method == "agentSession.reveal":
            worktree = next((key for key, value in self.sessions.items() if value == params["sessionId"]), None)
            if worktree is None or self.forget_chats:
                return {"ok": False, "refusal": {"code": "not_found"}}
            self.closed.discard(params["sessionId"])
            return {"ok": True, "sessionId": params["sessionId"], "agent": "claude", "readable": True,
                    "workspaceId": worktree.removeprefix("id:")}
        if method == "agentSession.options":
            return {"current": {"permissionMode": self.modes[params["sessionId"]]}}
        if method == "agentSession.setOption":
            self.modes[params["envelope"]["sessionId"]] = params["value"]
            return {"ok": True}
        return {}

    def start_runtime(self, runtime_id):
        """Serve a runtime on its own socket and publish it in the profile, as Orca's launch does."""
        server = socketserver.UnixStreamServer(str(self.home / (runtime_id + ".sock")), OrcaSocket)
        server.fixture = self
        server.runtime_id = runtime_id
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.server = server
        metadata = self.profile / "orca-runtime.json"
        metadata.write_text(json.dumps({
            "runtimeId": runtime_id, "authToken": "local-fixture-token",
            "transports": [{"kind": "unix", "endpoint": server.server_address}],
        }))
        metadata.chmod(0o600)

    def stop_runtime(self):
        self.server.shutdown()
        self.server.server_close()

    def wait_for_request(self, method, start, bridge, log, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if any(name == method for name, _ in self.requests[start:]):
                return
            self.assertIsNone(bridge.poll(), log.read_text())
            time.sleep(0.05)
        self.fail(f"No {method} reached the restarted runtime. {log.read_text()}")

    def start_bridge(self, label, approval="normal", launch=None):
        """Start a launch on a new reservation, or with `launch`, a new launch on the mount `label`."""
        if launch is None:
            reserved = subprocess.run(
                ["python3", "-I", "-S", str(self.scripts / "orca_native.py"), "reserve", str(self.rh), label],
                env=self.env, text=True, capture_output=True, timeout=5)
            self.assertEqual(reserved.returncode, 0, reserved.stderr)
            project = Path(reserved.stdout.strip())
            self.assertEqual(project, self.mounts / label)
        else:
            project = self.mounts / label
        result = subprocess.run(
            ["bash", str(self.scripts / "inject-rule.sh"), "on", "claude", "/local/project",
             "testbox", str(project), approval, str(self.config), launch or label, "orca"],
            env=self.env, text=True, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertIn("RH_ORCA_LAUNCH", values)
        session = Path(values["RH_SESSION_DIR"]).resolve()
        log = self.home / (label + ".log")
        command = ("export " + values["RH_LAUNCH_ENV"] + "; exec " + values["RH_LAUNCH_PREFIX"]
                   + " " + values["RH_ORCA_LAUNCH"])
        with log.open("w") as stream:
            bridge = subprocess.Popen(["bash", "-c", command], cwd=project, env=self.env,
                                      stdout=stream, stderr=stream)
        self.addCleanup(self.stop, bridge)
        return bridge, log, session, project

    @staticmethod
    def stop(bridge):
        if bridge.poll() is None:
            bridge.kill()
            bridge.wait(timeout=5)

    def ready(self, bridge, log):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            for line in log.read_text().splitlines():
                if line.startswith("remote-harness: Orca Claude chat "):
                    return line.split()[4]
            if bridge.poll() is not None:
                break
            time.sleep(0.025)
        self.fail(log.read_text())

    def wrapper_call(self, cwd, *args, env=None):
        return subprocess.run([str(self.wrapper), *args], cwd=cwd, env=env or self.env,
                              text=True, capture_output=True, timeout=5)

    def test_native_chat_close_revokes_settings_and_resume(self):
        bridge, log, session, project = self.start_bridge("session-one")
        identity = self.ready(bridge, log)
        self.assertIn(f"OWNER_PID={bridge.pid}\n", (session / "owner.env").read_text())
        created = next(params for method, params in self.requests if method == "agentSession.create")
        self.assertEqual(created["agent"], "claude")
        self.assertNotIn("firstMessage", created)
        self.assertEqual(created["options"]["permissionMode"], "ask")
        folder = next(iter(self.workspaces.values()))
        self.assertEqual(folder["folderPath"], str(project))
        self.assertEqual(folder["name"], "Remote Harness · project")
        self.assertIsNone(bridge.poll(), "an idle chat must keep its reverse transport")

        result = self.wrapper_call(project, "--session-id", provider_id(identity),
                                   "--input-format", "stream-json", "--output-format", "stream-json",
                                   "--setting-sources=user,project,local", "--replay-user-messages",
                                   "--settings", '{"fastMode":false}',
                                   "--dangerously-skip-permissions")
        self.assertEqual(result.returncode, 0, result.stderr)
        child = json.loads(result.stdout)
        args = child["args"]
        self.assertEqual(args[args.index("--output-format") + 1], "stream-json")
        self.assertNotIn("--dangerously-skip-permissions", args)
        self.assertEqual(args[args.index("--permission-mode") + 1], "default")
        self.assertTrue(child["env"]["PATH"].startswith(str(session / "bin") + ":"))
        self.assertEqual(child["env"]["CLAUDE_CODE_BASH_EDIT_DIFF"], "1")
        self.assertNotIn("192.0.2.12", child["env"].get("SSH_CONNECTION", ""))
        rule = args[args.index("--append-system-prompt") + 1]
        self.assertIn("every Bash command is routed", rule)
        self.assertEqual(args.count("--settings"), 1)
        settings = json.loads(args[args.index("--settings") + 1])
        self.assertIs(settings["fastMode"], False)
        guard = next(h["hooks"][0] for h in settings["hooks"]["PreToolUse"] if not h.get("matcher"))
        self.assertEqual(guard["onFailure"], "block")
        self.assertEqual(self.guard(guard, "Read").returncode, 0)
        self.assertNotEqual(self.guard(guard, "mcp__orca__agent_launch").returncode, 0)
        self.closed.add(identity)
        self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertNotEqual(self.guard(guard, "Bash").returncode, 0)
        self.assertNotEqual(self.wrapper_call(project, "--resume", provider_id(identity)).returncode, 0)
        shutil.rmtree(session)
        self.assertNotEqual(self.wrapper_call(self.home, "--resume=" + provider_id(identity)).returncode, 0)

    @staticmethod
    def guard(hook, tool):
        return subprocess.run(shlex.split(hook["command"]), input=json.dumps({"tool_name": tool}),
                              capture_output=True, text=True, timeout=5)

    def chats_listing(self, project="/local/project", ui=()):
        result = subprocess.run(["python3", "-EsB", str(self.scripts / "orca-session.py"), "chats",
                                 str(self.rh), "claude", project, *ui], env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def chats(self, project="/local/project", ui=()):
        return [line.removeprefix("RH_ORCA_CHAT=").split("\t") for line in self.chats_listing(project, ui)
                if line.startswith("RH_ORCA_CHAT=")]

    def claim(self, label, launch, project="/local/project", ui=()):
        return subprocess.run(["python3", "-EsB", str(self.scripts / "orca-session.py"), "claim",
                               str(self.rh), "claude", label, launch, project, *ui],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def adopt(self, conversation, launch, project="/local/project"):
        return subprocess.run(["python3", "-EsB", str(self.scripts / "orca-session.py"), "adopt",
                               str(self.rh), "claude", conversation, launch, project],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def end_launch(self, bridge, session):
        """The bridge exits on a signal, then the launcher's cleanup removes the session."""
        bridge.terminate()
        # 128 + SIGTERM: the launcher records that the bridge was stopped, not that the chat closed.
        self.assertEqual(bridge.wait(timeout=8), 143)
        shutil.rmtree(session)

    def test_ended_chat_continues_only_in_a_launch_that_claims_it(self):
        bridge, log, session, project = self.start_bridge("first", "yolo")
        identity = self.ready(bridge, log)
        record_path = self.rh / ".orca-identities" / (provider_id(identity) + ".json")
        record = json.loads(record_path.read_text())
        self.assertEqual((record["chat"], record["agent"], record["project"]),
                         (identity, "claude", "/local/project"))
        # A running launch's chat is not offered and cannot be claimed.
        self.assertEqual(self.chats(), [])
        self.assertNotEqual(self.claim("first", "second").returncode, 0)
        self.end_launch(bridge, session)
        self.assertIn(("folderWorkspace.update", {"folderWorkspaceId": "folder-id-0",
                                                  "updates": {"isArchived": True}}), self.requests)
        ended = self.wrapper_call(project, "--resume", provider_id(identity))
        self.assertNotEqual(ended.returncode, 0)
        self.assertIn("This Harness session has ended. To continue this chat", ended.stderr)

        # Only a launch of the same project offers it, with a terminal-safe last message.
        self.assertEqual(self.chats("/other/project"), [])
        self.assertEqual(self.chats(), [["first", "1794500000", "1", "where were we? [2J"]])
        # A new reservation never takes the chat over.
        refused, refused_log, _, _ = self.start_bridge("first", launch="unclaimed")
        self.assertEqual(refused.wait(timeout=8), 1)
        self.assertIn("belongs to an earlier Orca chat", refused_log.read_text())
        self.assertNotEqual(self.claim("first", "second", "/other/project").returncode, 0)
        self.assertNotEqual(self.claim("../first", "second").returncode, 0)
        self.assertNotEqual(self.claim("unknown", "second").returncode, 0)

        claimed = self.claim("first", "second")
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        self.assertEqual(claimed.stdout, f"MOUNTPOINT={project}\n")
        record = json.loads(record_path.read_text())
        self.assertEqual(record["session"], str(project).replace("/", "_") + ".second")
        self.assertEqual(record["token"], "")
        # Until its bridge grants a lease, the claimed chat has no tools.
        self.assertNotEqual(self.wrapper_call(project, "--resume", provider_id(identity)).returncode, 0)

        start = len(self.requests)
        bridge, log, session, _ = self.start_bridge("first", "normal", launch="second")
        self.assertEqual(self.ready(bridge, log), identity)
        self.assertIn("is ready again. Continue it in Orca.", log.read_text())
        requests = self.requests[start:]
        self.assertNotIn("agentSession.create", [method for method, _ in requests])
        self.assertIn(("folderWorkspace.update", {"folderWorkspaceId": "folder-id-0",
                                                  "updates": {"isArchived": False}}), requests)
        self.assertIn(("agentSession.reveal", {"sessionId": identity}), requests)
        # The chat takes this launch's approval mode, not the earlier yolo.
        self.assertEqual(self.modes[identity], "ask")
        result = self.wrapper_call(project, "--resume", provider_id(identity), "--dangerously-skip-permissions")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)["args"]
        self.assertEqual(args[args.index("--permission-mode") + 1], "default")
        self.assertNotIn("--dangerously-skip-permissions", args)
        self.assertNotEqual(self.claim("first", "third").returncode, 0)
        self.end_launch(bridge, session)
        self.assertIn(("agentSession.close", {"sessionId": identity}), self.requests[start:])

    def test_chat_whose_launcher_was_killed_continues_from_its_open_tab(self):
        bridge, log, session, project = self.start_bridge("killed")
        identity = self.ready(bridge, log)
        # A killed bridge neither closes the chat nor archives the workspace.
        bridge.kill()
        bridge.wait(timeout=5)
        shutil.rmtree(session)
        # Identity records written before chat and project records were kept.
        record_path = self.rh / ".orca-identities" / (provider_id(identity) + ".json")
        record = json.loads(record_path.read_text())
        record_path.unlink()
        record_path.write_text(json.dumps({key: record[key] for key in ("cwd", "session", "token")}))
        record_path.chmod(0o600)
        self.assertEqual(self.chats("/other/project"), [["killed", "1794500000", "0", "where were we? [2J"]])
        claimed = self.claim("killed", "next")
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        record = json.loads(record_path.read_text())
        self.assertEqual((record["chat"], record["project"]), (identity, "/local/project"))
        self.assertEqual(self.chats(), [["killed", "1794500000", "1", "where were we? [2J"]])
        bridge, log, session, _ = self.start_bridge("killed", launch="next")
        self.assertEqual(self.ready(bridge, log), identity)
        result = self.wrapper_call(project, "--session-id", provider_id(identity))
        self.assertEqual(result.returncode, 0, result.stderr)

    def transcript(self, project, provider, text, at):
        """A Claude transcript as Claude Code keeps it for a session started in `project`."""
        path = (self.home / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(project))
                / (provider + ".jsonl"))
        path.parent.mkdir(parents=True, exist_ok=True)
        entries = [{"type": "user", "message": {"role": "user", "content": text}},
                   {"type": "user", "message": {"role": "user", "content": [
                       {"type": "tool_result", "tool_use_id": "t", "content": "output"}]}},
                   {"type": "user", "isMeta": True, "message": {"role": "user", "content": "meta"}},
                   {"type": "assistant", "message": {"role": "assistant", "content": [
                       {"type": "text", "text": "answer"}]}}]
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        os.utime(path, (at, at))

    def continue_chat(self, label, launch):
        claimed = self.claim(label, launch)
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        start = len(self.requests)
        bridge, log, session, _ = self.start_bridge(label, launch=launch)
        chat = self.ready(bridge, log)
        self.assertIn("is ready again", log.read_text())
        return bridge, session, chat, self.requests[start:]

    def test_chat_gone_from_orca_continues_its_claude_conversation_in_a_new_chat(self):
        bridge, log, session, project = self.start_bridge("gone", "auto")
        identity = self.ready(bridge, log)
        provider = provider_id(identity)
        record_path = self.rh / ".orca-identities" / (provider + ".json")
        self.end_launch(bridge, session)
        self.forget_chats = True
        # Without the chat in Orca or its Claude conversation, nothing can continue.
        self.assertEqual(self.chats(), [])
        self.transcript(project, provider, "older\x07 question", 1794400000)
        self.assertEqual(self.chats(), [["gone", "1794400000", "1", "older question"]])

        # The workspace is still there: a new chat in it resumes the Claude conversation.
        bridge, session, chat, requests = self.continue_chat("gone", "second")
        self.assertNotEqual(chat, identity)
        created = next(params for method, params in requests if method == "agentSession.create")
        self.assertEqual(created["resumeFrom"], {"providerSessionId": provider})
        self.assertEqual(created["options"]["permissionMode"], "ask")
        self.assertNotIn("folderWorkspace.create", [method for method, _ in requests])
        self.assertIn(("folderWorkspace.update", {"folderWorkspaceId": "folder-id-0",
                                                  "updates": {"isArchived": False}}), requests)
        self.assertEqual(json.loads(record_path.read_text())["chat"], chat)
        result = self.wrapper_call(project, "--resume=" + provider)
        self.assertEqual(result.returncode, 0, result.stderr)
        # Only the Claude conversation is registered, not one derived from the new chat.
        self.assertNotEqual(self.wrapper_call(project, "--session-id", provider_id(chat)).returncode, 0)
        self.end_launch(bridge, session)

        # The workspace was deleted as well: the launch creates it again.
        self.workspaces.clear()
        bridge, session, chat, requests = self.continue_chat("gone", "third")
        self.assertIn("folderWorkspace.create", [method for method, _ in requests])
        self.assertEqual(next(params for method, params in requests
                              if method == "agentSession.create")["resumeFrom"], {"providerSessionId": provider})
        self.end_launch(bridge, session)

        # Once Orca has the new chat again, the next launch reopens that chat.
        self.forget_chats = False
        bridge, session, reopened, requests = self.continue_chat("gone", "fourth")
        self.assertEqual(reopened, chat)
        self.assertIn(("agentSession.reveal", {"sessionId": chat}), requests)
        self.assertNotIn("agentSession.create", [method for method, _ in requests])
        result = self.wrapper_call(project, "--resume=" + provider)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_terminal_launch_continues_an_orca_chat_that_orca_takes_back_later(self):
        bridge, log, session, project = self.start_bridge("from-orca")
        identity = self.ready(bridge, log)
        provider = provider_id(identity)
        record_path = self.rh / ".orca-identities" / (provider + ".json")
        self.end_launch(bridge, session)
        # A terminal launch needs Claude's own conversation, not Orca's chat.
        self.assertEqual(self.chats(ui=["terminal"]), [])
        self.transcript(project, provider, "asked in orca", 1794400000)
        self.assertEqual(self.chats(ui=["terminal"]), [["from-orca", "1794400000", "1", "asked in orca"]])
        self.assertEqual(self.chats("/other/project", ui=["terminal"]), [])

        claimed = self.claim("from-orca", "term", ui=["terminal"])
        self.assertEqual(claimed.returncode, 0, claimed.stderr)
        self.assertEqual(claimed.stdout, f"MOUNTPOINT={project}\nRESUME={provider}\n")
        record = json.loads(record_path.read_text())
        self.assertEqual((record["session"], record["token"], record["chat"]),
                         (str(project).replace("/", "_") + ".term", "", identity))
        # While the terminal launch runs, no launch offers the chat and Orca cannot run it.
        terminal = self.rh / ".sessions" / record["session"]
        terminal.mkdir(mode=0o700)
        self.assertEqual((self.chats(), self.chats(ui=["terminal"])), ([], []))
        self.assertNotEqual(self.claim("from-orca", "other", ui=["terminal"]).returncode, 0)
        self.assertNotEqual(self.wrapper_call(project, "--resume", provider).returncode, 0)
        terminal.rmdir()

        # Afterwards an Orca launch reopens the same chat, which resumes the same conversation.
        bridge, session, chat, requests = self.continue_chat("from-orca", "back")
        self.assertEqual(chat, identity)
        self.assertIn(("agentSession.reveal", {"sessionId": identity}), requests)
        self.assertEqual(self.wrapper_call(project, "--resume", provider).returncode, 0)
        self.end_launch(bridge, session)

    def test_orca_launch_continues_a_copy_of_a_terminal_conversation_in_a_new_chat(self):
        conversation = str(uuid.uuid4())
        default = self.rh.resolve() / "mounts" / "project"
        folder = self.home / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(default))
        folder.mkdir(parents=True)
        source = folder / (conversation + ".jsonl")
        entries = [
            {"type": "summary", "summary": "earlier work"},
            {"type": "user", "sessionId": conversation, "cwd": str(default),
             "message": {"role": "user", "content": "asked in the terminal"}},
            {"type": "assistant", "sessionId": conversation, "cwd": str(default / "src"),
             "message": {"role": "assistant", "content": [{"type": "text", "text": "回答"}]}},
            {"type": "user", "sessionId": conversation, "cwd": "/elsewhere", "message": {
                "role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "x"}]}},
        ]
        source.write_text("".join(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries)
                          + "not json\n")
        os.utime(source, (1794300000, 1794300000))
        original = source.read_bytes()
        # A conversation without a typed message, and any other project, are not offered.
        self.transcript(default, str(uuid.uuid4()), "<command-name>/clear</command-name>", 1794300100)
        self.assertEqual(self.chats_listing(),
                         [f"RH_TERMINAL_CHAT={conversation}\t1794300000\tasked in the terminal"])
        # Terminal launches key their mount by the project folder's name.
        self.assertEqual(self.chats_listing("/local/other"), [])
        self.assertEqual(self.chats_listing(ui=["terminal"]), [])
        self.assertNotEqual(self.adopt(conversation, "elsewhere", "/local/other").returncode, 0)
        self.assertNotEqual(self.adopt(str(uuid.uuid4()), "unknown").returncode, 0)
        self.assertNotEqual(self.adopt("../" + conversation, "invalid").returncode, 0)
        self.assertFalse(any(self.mounts.iterdir()))

        adopted = self.adopt(conversation, "to-orca")
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        project = self.mounts / "to-orca"
        self.assertEqual(adopted.stdout, f"MOUNTPOINT={project}\n")
        # Orca resumes only a conversation recorded in the chat's folder: the chat gets a copy under
        # a new session ID, with the terminal mount's directories moved to its own mount.
        registry = self.rh / ".orca-identities"
        (record_path,) = [path for path in registry.glob("*.json")
                          if json.loads(path.read_text()).get("from") == conversation]
        provider = record_path.stem
        self.assertNotEqual(provider, conversation)
        self.assertEqual(source.read_bytes(), original)
        copy = (self.home / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(project))
                / (provider + ".jsonl"))
        lines = copy.read_text().splitlines()
        self.assertEqual(lines[-1], "not json")
        copied = [json.loads(line) for line in lines[:-1]]
        self.assertEqual(copied[0], entries[0])
        self.assertEqual([entry.get("sessionId") for entry in copied[1:]], [provider] * 3)
        self.assertEqual([entry["cwd"] for entry in copied[1:]], [str(project), str(project / "src"), "/elsewhere"])
        self.assertEqual(copied[2]["message"], entries[2]["message"])
        self.assertEqual((copy.stat().st_mtime, copy.stat().st_mode & 0o777), (1794300000, 0o600))
        # It now continues as this launch's chat, also if this launch fails, and is not offered again.
        self.assertNotEqual(self.adopt(conversation, "again").returncode, 0)
        self.assertEqual(self.chats_listing(), ["RH_ORCA_CHAT=to-orca\t1794300000\t1\tasked in the terminal"])

        start = len(self.requests)
        bridge, log, session, _ = self.start_bridge("to-orca", launch="to-orca")
        chat = self.ready(bridge, log)
        created = next(params for method, params in self.requests[start:] if method == "agentSession.create")
        self.assertEqual(created["resumeFrom"], {"providerSessionId": provider})
        result = self.wrapper_call(project, "--resume", provider)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["args"][:2], ["--resume", provider])
        self.assertNotEqual(self.wrapper_call(project, "--resume", conversation).returncode, 0)
        self.end_launch(bridge, session)

        # From then on it continues as that Orca chat, in Orca or in a terminal launch.
        self.assertEqual(self.chats_listing(), [f"RH_ORCA_CHAT=to-orca\t1794500000\t1\twhere were we? [2J"])
        self.assertEqual(self.chats(ui=["terminal"]), [["to-orca", "1794300000", "1", "asked in the terminal"]])
        claimed = self.claim("to-orca", "term", ui=["terminal"])
        self.assertEqual(claimed.stdout, f"MOUNTPOINT={project}\nRESUME={provider}\n")
        self.assertEqual(json.loads(record_path.read_text())["chat"], chat)
        # Once the terminal conversation changes again, it is offered again.
        later = json.loads(record_path.read_text())["created"] + 60
        os.utime(source, (later, later))
        self.assertIn(f"RH_TERMINAL_CHAT={conversation}\t{later}\tasked in the terminal", self.chats_listing())

    def test_concurrent_same_project_cannot_use_other_or_unknown_identity(self):
        first, first_log, _, first_project = self.start_bridge("first", "auto")
        first_id = self.ready(first, first_log)
        second, second_log, _, second_project = self.start_bridge("second", "yolo")
        second_id = self.ready(second, second_log)
        self.assertNotEqual(first_id, second_id)
        self.assertNotEqual(self.wrapper_call(second_project, "--resume", provider_id(first_id)).returncode, 0)
        unknown = self.wrapper_call(first_project, "--session-id", str(uuid.uuid4()))
        self.assertNotEqual(unknown.returncode, 0)
        self.assertEqual(unknown.stdout, "")
        self.assertIn("Open the existing Harness chat", unknown.stderr)
        self.assertNotEqual(self.wrapper_call(first_project, "--continue").returncode, 0)
        # Orca 1.4.254 can fork a chat; a fork of the registered identity must not inherit its lease.
        self.assertNotEqual(self.wrapper_call(first_project, "--resume", provider_id(first_id),
                                              "--fork-session").returncode, 0)
        for settings in ("{}", '{"fastMode":false,"disableAllHooks":true}', "settings.json"):
            self.assertNotEqual(self.wrapper_call(first_project, "--session-id", provider_id(first_id),
                                                  "--settings", settings).returncode, 0)
        normal = self.wrapper_call(self.home, "--session-id", str(uuid.uuid4()), "--settings", "{}")
        self.assertEqual(normal.returncode, 0, normal.stderr)
        self.assertEqual(json.loads(normal.stdout)["args"][-2:], ["--settings", "{}"])
        self.assertIn("Claude Code", self.wrapper_call(first_project, "--version").stdout)
        self.stop(first)
        self.assertNotEqual(self.wrapper_call(first_project, "--resume", provider_id(first_id)).returncode, 0)
        result = self.wrapper_call(second_project, "--resume", provider_id(second_id))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--dangerously-skip-permissions", json.loads(result.stdout)["args"])
        second.terminate()
        self.assertEqual(second.wait(timeout=8), 143)
        self.assertIn(("agentSession.close", {"sessionId": second_id}), self.requests)

    def test_archived_workspace_revokes_lease_and_closes_chat(self):
        bridge, log, session, _ = self.start_bridge("archived-workspace")
        identity = self.ready(bridge, log)
        self.assertTrue((session / "orca-lease.json").exists())
        next(iter(self.workspaces.values()))["isArchived"] = True
        self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        self.assertIn(("agentSession.close", {"sessionId": identity}), self.requests)

    def test_claude_self_update_keeps_the_session_but_a_new_command_does_not(self):
        # Claude's installer repoints a stable symlink at each new version.
        versions = self.home / "claude-versions"
        versions.mkdir()
        current = Path(json.loads((self.rh / "orca" / "claude.json").read_text())["claude"])
        for version in ("2.1.400", "2.1.401"):
            shutil.copy2(current, versions / version)
        link = self.home / "claude-link"
        link.symlink_to(versions / "2.1.400")
        configuration = self.rh / "orca" / "claude.json"
        data = json.loads(configuration.read_text())
        configuration.write_text(json.dumps({**data, "claude": str(link)}))
        bridge, log, session, project = self.start_bridge("self-update")
        identity = provider_id(self.ready(bridge, log))
        lease = session / "orca-lease.json"
        self.assertEqual(json.loads(lease.read_text())["claude"], str(link))
        replacement = self.home / "claude-link.new"
        replacement.symlink_to(versions / "2.1.401")
        os.replace(replacement, link)
        updated = self.wrapper_call(project, "--resume", identity)
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertIn("--append-system-prompt", json.loads(updated.stdout)["args"])
        # A lease from a bridge that recorded the resolved target still works until an update.
        recorded = json.loads(lease.read_text())
        lease.write_text(json.dumps({**recorded, "claude": str(versions / "2.1.401")}))
        self.assertEqual(self.wrapper_call(project, "--resume", identity).returncode, 0)
        lease.write_text(json.dumps(recorded))
        # Pointing the configuration at another executable is a different command.
        configuration.write_text(json.dumps({**data, "claude": str(versions / "2.1.401")}))
        changed = self.wrapper_call(project, "--resume", identity)
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("configured Claude command changed", changed.stderr)

    def test_restarted_runtime_keeps_the_chat_and_its_lease(self):
        # An automatic update stops Orca Server, starts the new build on another socket with a new
        # runtime ID, and restores its chats a little later. The Harness session survives all of it.
        bridge, log, session, project = self.start_bridge("restarted-runtime")
        identity = self.ready(bridge, log)
        lease = session / "orca-lease.json"
        self.stop_runtime()
        time.sleep(3)
        self.assertIsNone(bridge.poll(), log.read_text())
        self.assertTrue(lease.exists())
        self.version, self.hide_tabs = "1.4.254", True
        self.start_runtime("updated-runtime")
        self.wait_for_request("session.tabs.list", len(self.requests), bridge, log)
        # A restarted runtime that has not restored the chat yet has not closed it.
        time.sleep(2.5)
        self.assertIsNone(bridge.poll(), log.read_text())
        self.hide_tabs = False
        start = len(self.requests)
        self.wait_for_request("session.tabs.list", start, bridge, log)
        self.wait_for_request("settings.get", start, bridge, log)
        env = {**self.env, "ORCA_APP_VERSION": "1.4.254"}
        resumed = self.wrapper_call(project, "--resume", provider_id(identity), env=env)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertIn("--append-system-prompt", json.loads(resumed.stdout)["args"])
        # The adopted runtime now owns the chat: closing its tab ends the session promptly.
        self.closed.add(identity)
        self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertFalse(lease.exists())
        self.assertNotIn("Lost contact", log.read_text())
        self.assertNotIn(("agentSession.close", {"sessionId": identity}), self.requests)

    def test_restarted_runtime_that_never_relists_the_chat_keeps_the_session(self):
        # Without a reconciling client, a restarted headless runtime may never list the chat tab
        # again although the chat itself still works. Archiving its workspace still ends it.
        bridge, log, session, _ = self.start_bridge("unlisted-after-restart")
        identity = self.ready(bridge, log)
        self.stop_runtime()
        self.hide_tabs = True
        start = len(self.requests)
        self.start_runtime("unlisting-runtime")
        self.wait_for_request("agentSession.history", start, bridge, log)
        time.sleep(4.5)
        self.assertIsNone(bridge.poll(), log.read_text())
        self.assertTrue((session / "orca-lease.json").exists())
        next(iter(self.workspaces.values()))["isArchived"] = True
        self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        self.assertIn(("agentSession.close", {"sessionId": identity}), self.requests)

    def test_restarted_runtime_without_the_chat_ends_the_session(self):
        bridge, log, session, _ = self.start_bridge("forgotten-after-restart")
        self.ready(bridge, log)
        self.stop_runtime()
        self.hide_tabs = self.forget_chats = True
        self.start_runtime("forgetting-runtime")
        self.assertEqual(bridge.wait(timeout=10), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())

    def test_restart_into_an_unsupported_build_releases_the_session(self):
        bridge, log, session, _ = self.start_bridge("unsupported-update")
        self.ready(bridge, log)
        self.stop_runtime()
        self.version = "1.5.0"
        start = len(self.requests)
        self.start_runtime("unsupported-runtime")
        self.assertNotEqual(bridge.wait(timeout=10), 0, log.read_text())
        self.assertIn(f"{REFUSED} (this server runs 1.5.0).", log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        # The bridge only inspects the unsupported build; it never drives its chats or workspaces.
        self.assertLessEqual({method for method, _ in self.requests[start:]}, {"status.get", "settings.get"})

    def test_restart_into_a_newer_patch_build_keeps_the_session_with_a_warning(self):
        bridge, log, session, _ = self.start_bridge("patch-update")
        identity = self.ready(bridge, log)
        self.assertNotIn("warning", log.read_text())
        self.stop_runtime()
        self.version = "1.4.255"
        start = len(self.requests)
        self.start_runtime("patch-runtime")
        self.wait_for_request("session.tabs.list", start, bridge, log)
        self.assertTrue((session / "orca-lease.json").exists())
        self.closed.add(identity)
        self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertEqual(log.read_text().count("Orca Server 1.4.255 has not been verified"), 1)

    def test_registered_chat_refuses_a_launch_from_an_unverified_orca_build(self):
        bridge, log, _, project = self.start_bridge("launch-version")
        identity = provider_id(self.ready(bridge, log))
        for version in (None, "1.5.0", "1.4.250"):
            with self.subTest(version=version):
                env = {key: value for key, value in self.env.items() if key != "ORCA_APP_VERSION"}
                if version:
                    env["ORCA_APP_VERSION"] = version
                result = self.wrapper_call(project, "--resume", identity, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn(REFUSED, result.stderr)
        # Ordinary chats elsewhere do not depend on the Orca build.
        normal = self.wrapper_call(self.home, "--session-id", str(uuid.uuid4()), env=env)
        self.assertEqual(normal.returncode, 0, normal.stderr)
        # A newer patch build may resume the chat; the bridge already warned about it.
        patched = self.wrapper_call(project, "--resume", identity,
                                    env={**self.env, "ORCA_APP_VERSION": "1.4.255"})
        self.assertEqual(patched.returncode, 0, patched.stderr)

    def test_orca_management_bash_is_blocked_before_routing_to_project_host(self):
        bridge, log, session, project = self.start_bridge("manager")
        self.ready(bridge, log)
        settings = json.loads((session / "claude-settings.json").read_text())
        hook = settings["hooks"]["PreToolUse"][0]["hooks"][0]
        for command in ("orca agent launch --agent claude",
                        "echo $(env /opt/bin/orca-ide terminal create)",
                        "printf '%s' 'orca agent launch'"):
            with self.subTest(command=command):
                event = {"tool_name": "Bash", "permission_mode": "default", "cwd": str(project),
                         "tool_input": {"command": command}}
                result = subprocess.run(shlex.split(hook["command"]), input=json.dumps(event),
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                response = json.loads(result.stdout)["hookSpecificOutput"]
                if command.startswith("printf"):
                    self.assertIn("updatedInput", response)
                else:
                    self.assertEqual(response.get("permissionDecision"), "deny")
                    self.assertNotIn("updatedInput", response)

    def test_crash_revokes_tool_access_even_if_lease_file_survives(self):
        bridge, log, session, project = self.start_bridge("crash")
        identity = self.ready(bridge, log)
        result = self.wrapper_call(project, "--session-id", provider_id(identity))
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)["args"]
        settings = json.loads(args[args.index("--settings") + 1])
        guard = next(h["hooks"][0] for h in settings["hooks"]["PreToolUse"] if not h.get("matcher"))
        self.assertEqual(self.guard(guard, "Bash").returncode, 0)
        self.stop(bridge)
        self.assertTrue((session / "orca-lease.json").exists())
        self.assertNotEqual(self.guard(guard, "Bash").returncode, 0)

    def test_insecure_or_malformed_identity_fails_closed_outside_the_mount(self):
        bridge, log, _, _ = self.start_bridge("invalid-state")
        identity = provider_id(self.ready(bridge, log))
        record = self.rh / ".orca-identities" / (identity + ".json")
        record.chmod(0o644)
        self.assertNotEqual(self.wrapper_call(self.home, "--resume", identity).returncode, 0)
        record.chmod(0o600)
        record.write_text("{}\u0000")
        self.assertNotEqual(self.wrapper_call(self.home, "--resume", identity).returncode, 0)

    def test_creates_and_reuses_a_local_harness_group_by_default(self):
        configuration = self.rh / "orca" / "claude.json"
        data = json.loads(configuration.read_text())
        del data["projectGroupId"]
        configuration.write_text(json.dumps(data))
        self.groups.clear()
        for label in ("first-workspace", "second-workspace"):
            bridge, log, _, _ = self.start_bridge(label)
            self.ready(bridge, log)
            bridge.terminate()
            self.assertEqual(bridge.wait(timeout=8), 143, log.read_text())
        self.assertEqual(len(self.groups), 1)
        self.assertEqual(self.groups[0]["name"], "Remote Harness")
        self.assertEqual(self.groups[0]["parentPath"], str(self.mounts))
        self.assertTrue(all(workspace["projectGroupId"] == self.groups[0]["id"]
                            for workspace in self.workspaces.values()))

    def test_legacy_pathless_group_is_preserved_and_not_reused(self):
        configuration = self.rh / "orca" / "claude.json"
        data = json.loads(configuration.read_text())
        del data["projectGroupId"]
        configuration.write_text(json.dumps(data))
        del self.groups[0]["parentPath"]
        legacy = dict(self.groups[0])
        for label in ("visible-first", "visible-second"):
            bridge, log, _, _ = self.start_bridge(label)
            self.ready(bridge, log)
            bridge.terminate()
            self.assertEqual(bridge.wait(timeout=8), 143, log.read_text())
        self.assertEqual(self.groups, [legacy, {
            "id": "created-group", "name": "Remote Harness", "parentPath": str(self.mounts),
        }])
        self.assertTrue(all(folder["projectGroupId"] == "created-group"
                            for folder in self.workspaces.values()))

    def test_configured_pathless_group_refuses_before_workspace_or_chat(self):
        del self.groups[0]["parentPath"]
        bridge, log, _, _ = self.start_bridge("pathless-configured-group")
        self.assertNotEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertIn("folder-backed", log.read_text())
        self.assertFalse(self.workspaces)
        self.assertFalse(self.sessions)

    def test_missing_remote_workspace_does_not_report_ready(self):
        self.publish_workspaces = False
        bridge, log, session, _ = self.start_bridge("unpublished-workspace")
        self.assertNotEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertIn("remote workspace list", log.read_text())
        self.assertNotIn("is ready", log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        self.assertEqual(self.closed, set(self.sessions.values()))
        self.assertTrue(all(folder["isArchived"] for folder in self.workspaces.values()))

    def test_wrong_configured_command_refuses_before_workspace_or_chat(self):
        self.command = "/usr/bin/claude"
        bridge, log, _, _ = self.start_bridge("wrong-command")
        self.assertNotEqual(bridge.wait(timeout=8), 0, log.read_text())
        self.assertIn("Claude Command", log.read_text())
        self.assertFalse(self.workspaces)
        self.assertFalse(self.sessions)

    def test_unverified_runtime_version_refuses_before_workspace_or_chat(self):
        for label, version, running in (("older-patch", "1.4.250", "1.4.250"),
                                        ("next-minor", "1.5.0", "1.5.0"),
                                        ("odd-version", "1.4.254\nforged", "an unknown version"),
                                        ("missing-version", None, "an unknown version")):
            with self.subTest(version=version):
                self.version = version
                bridge, log, _, _ = self.start_bridge(label)
                self.assertNotEqual(bridge.wait(timeout=8), 0, log.read_text())
                self.assertIn(f"{REFUSED} (this server runs {running}).", log.read_text())
                self.assertFalse(self.workspaces)
                self.assertFalse(self.sessions)

    def test_supported_runtime_versions_start_a_chat(self):
        for version, warned in (("1.4.251", False), ("1.4.254", False), ("1.4.255", True)):
            with self.subTest(version=version):
                self.version = version
                bridge, log, _, _ = self.start_bridge("supported-" + version.replace(".", "-"))
                self.ready(bridge, log)
                bridge.terminate()
                self.assertEqual(bridge.wait(timeout=8), 143, log.read_text())
                self.assertEqual("has not been verified" in log.read_text(), warned, log.read_text())


if __name__ == "__main__":
    unittest.main()
