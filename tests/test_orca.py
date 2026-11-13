#!/usr/bin/env python3
"""Exercise the reverse launch, local Orca RPC boundary, and real Claude wrapper."""
import hashlib
import json
import os
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
            return {"ok": True, "page": {"sessionId": params["sessionId"]} if known else {}}
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

    def start_bridge(self, label, approval="normal"):
        reserved = subprocess.run(
            ["python3", "-I", "-S", str(self.scripts / "orca_native.py"), "reserve", str(self.rh), label],
            env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(reserved.returncode, 0, reserved.stderr)
        project = Path(reserved.stdout.strip())
        self.assertEqual(project, self.mounts / label)
        result = subprocess.run(
            ["bash", str(self.scripts / "inject-rule.sh"), "on", "claude", "/local/project",
             "testbox", str(project), approval, str(self.config), label, "orca"],
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
        self.assertEqual(second.wait(timeout=8), 0)
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

    def test_restart_into_an_unverified_build_releases_the_session(self):
        bridge, log, session, _ = self.start_bridge("unverified-update")
        self.ready(bridge, log)
        self.stop_runtime()
        self.version = "1.4.255"
        start = len(self.requests)
        self.start_runtime("unverified-runtime")
        self.assertNotEqual(bridge.wait(timeout=10), 0, log.read_text())
        self.assertIn("(this server runs 1.4.255).", log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        # The bridge only inspects the unverified build; it never drives its chats or workspaces.
        self.assertLessEqual({method for method, _ in self.requests[start:]}, {"status.get", "settings.get"})

    def test_registered_chat_refuses_a_launch_from_an_unverified_orca_build(self):
        bridge, log, _, project = self.start_bridge("launch-version")
        identity = provider_id(self.ready(bridge, log))
        for version in (None, "1.4.255"):
            with self.subTest(version=version):
                env = {key: value for key, value in self.env.items() if key != "ORCA_APP_VERSION"}
                if version:
                    env["ORCA_APP_VERSION"] = version
                result = self.wrapper_call(project, "--resume", identity, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("requires Orca Server 1.4.251 or 1.4.254", result.stderr)
        # Ordinary chats elsewhere do not depend on the Orca build.
        normal = self.wrapper_call(self.home, "--session-id", str(uuid.uuid4()), env=env)
        self.assertEqual(normal.returncode, 0, normal.stderr)

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
            self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
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
            self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())
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
        for label, version, running in (("newer-version", "1.4.252", "1.4.252"),
                                        ("odd-version", "1.4.254\nforged", "an unknown version"),
                                        ("missing-version", None, "an unknown version")):
            with self.subTest(version=version):
                self.version = version
                bridge, log, _, _ = self.start_bridge(label)
                self.assertNotEqual(bridge.wait(timeout=8), 0, log.read_text())
                self.assertIn("requires Orca Server 1.4.251 or 1.4.254 "
                              f"(this server runs {running}).", log.read_text())
                self.assertFalse(self.workspaces)
                self.assertFalse(self.sessions)

    def test_each_verified_runtime_version_starts_a_chat(self):
        for version in ("1.4.251", "1.4.254"):
            with self.subTest(version=version):
                self.version = version
                bridge, log, _, _ = self.start_bridge("verified-" + version.replace(".", "-"))
                self.ready(bridge, log)
                bridge.terminate()
                self.assertEqual(bridge.wait(timeout=8), 0, log.read_text())


if __name__ == "__main__":
    unittest.main()
