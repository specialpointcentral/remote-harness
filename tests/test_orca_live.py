#!/usr/bin/env python3
"""Opt-in checks of a real Orca Server with the Harness Claude bridge and a recording Claude.

RH_TEST_ORCA_CLI names an Orca CLI that can `serve`; tests/verify-orca-version.sh builds one from
an orcad bundle. RH_TEST_ORCA_AFTER optionally names the build the restart test switches to, as
an automatic update does. No model, no real Claude and no network are involved.
"""
from contextlib import ExitStack, suppress
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

from test_native_codex_managers import Orca, process, wait_for
from test_paseo import SCRIPTS

ORCA = os.environ.get("RH_TEST_ORCA_CLI")
AFTER = os.environ.get("RH_TEST_ORCA_AFTER") or ORCA
# Every flag Orca 1.4.251 and 1.4.254 pass to a Claude chat. The wrapper forwards flags it does not
# know, so review any new one (an extra MCP config, for example) before verifying a new build.
KNOWN_FLAGS = {
    "--add-dir", "--include-partial-messages", "--input-format", "--output-format",
    "--permission-mode", "--permission-prompt-tool", "--plugin-dir", "--replay-user-messages",
    "--session-id", "--resume", "--setting-sources", "--settings", "--thinking-display", "--verbose",
}
RECORDER = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
if args in (["--version"], ["-v"]):
    print("2.1.319 (Claude Code)")
    sys.exit(0)
if args in (["--help"], ["-h"]):
    print('permissions: "auto"')
    sys.exit(0)
env = {key: value for key, value in os.environ.items() if key.startswith("ORCA_") or key == "PATH"}
with open(os.environ["RH_TEST_LAUNCHES"], "a") as log:
    log.write(json.dumps({"args": args, "cwd": os.getcwd(), "env": env, "at": time.time()}) + "\n")
if "--input-format" in args:
    for _ in sys.stdin:
        pass
'''


@unittest.skipUnless(ORCA, "set RH_TEST_ORCA_CLI to an Orca CLI that can serve; see tests/verify-orca-version.sh")
class OrcaLiveTests(unittest.TestCase):
    def setUp(self):
        # Orca's Unix socket lives in the profile, so keep the path short.
        raw = tempfile.TemporaryDirectory(prefix="rh-live-", dir="/tmp")
        self.addCleanup(raw.cleanup)
        self.home = Path(raw.name).resolve()
        self.rh = self.home / "rh"
        self.rh.mkdir(mode=0o700)
        self.scripts = self.rh / "scripts"
        shutil.copytree(SCRIPTS, self.scripts, ignore=shutil.ignore_patterns("__pycache__"))
        claude = self.home / "claude"
        claude.write_text(RECORDER)
        claude.chmod(0o755)
        self.launch_log = self.home / "launches.jsonl"
        self.launch_log.touch()
        profile = self.home / "profile"
        profile.mkdir(mode=0o700)
        (self.rh / "orca").mkdir(mode=0o700)
        config = self.rh / "orca" / "claude.json"
        config.write_text(json.dumps({"claude": str(claude), "profile": str(profile)}))
        config.chmod(0o600)
        self.env = {"HOME": str(self.home), "PATH": os.environ["PATH"], "RH_HOME": str(self.rh),
                    "RH_WARM_MAX": "0", "RH_HEARTBEAT_TIMEOUT": "0", "LANG": "en_US.UTF-8",
                    "TMPDIR": str(self.home), "ORCA_USER_DATA_PATH": str(profile),
                    "ORCA_SERVE_RUNTIME": "electron", "RH_TEST_LAUNCHES": str(self.launch_log)}
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.orca = Orca(profile)
        self.servers = ExitStack()
        self.addCleanup(self.servers.close)
        self.status = self.serve(ORCA, "first")
        self.orca.call("settings.mutateAgentLaunch", {
            "type": "command", "agent": "claude", "value": str(self.scripts / "orca-claude.py")})

    def serve(self, cli, name):
        log = self.home / f"orca-{name}.log"
        self.servers.enter_context(process([cli, "serve", "--no-pairing", "--port", str(self.port)],
                                           self.env, self.home, log))
        wait_for(self.orca.ready, 90, detail=log.read_text)
        return self.orca.call("status.get")

    def launch_in(self, cwd, after=0.0):
        def launched():
            for line in self.launch_log.read_text().splitlines():
                item = json.loads(line)
                if item["cwd"] == str(cwd) and item["at"] > after:
                    return item
        return wait_for(launched, 60, detail=lambda: self.launch_log.read_text()[-3000:])

    def send(self, session_id, text):
        body = {"kind": "message", "role": "user", "blocks": [{"type": "text", "text": text}]}

        def sent():
            fence = self.orca.call("agentSession.history", {
                "sessionId": session_id, "direction": "tail", "limit": 1})["page"]["fence"]
            data = {"method": "agentSession.send", "sessionId": session_id, "fields": {"body": body}}
            envelope = {"sessionId": session_id,
                        "clientOperationId": f"{int(time.time() * 1000)}-{uuid.uuid4().hex}",
                        "expectedRuntimeFence": fence,
                        "payloadFingerprint": hashlib.sha256(json.dumps(
                            data, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                        ).encode()).hexdigest()}
            try:
                return self.orca.call("agentSession.send", {"envelope": envelope, "body": body})["ok"]
            except RuntimeError:
                return False  # a restarted server may still be restoring the chat
        wait_for(sent, 30)

    def create_plain_chat(self, folder):
        group = self.orca.call("projectGroup.create", {"name": "Plain", "parentPath": str(folder.parent)})
        workspace = self.orca.call("folderWorkspace.create", {
            "projectGroupId": group["group"]["id"], "name": "plain", "folderPath": str(folder)})
        session_id = f"claude_{uuid.uuid4().hex}"
        fields = {"agent": "claude", "worktree": f"id:folder:{workspace['folderWorkspace']['id']}",
                  "options": {"permissionMode": "ask"}}
        digest = json.dumps({"method": "agentSession.create", "sessionId": session_id, "fields": fields},
                            ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        created = self.orca.call("agentSession.create", {"envelope": {
            "sessionId": session_id, "clientOperationId": f"{time.time_ns() // 1_000_000}-{uuid.uuid4().hex}",
            "expectedRuntimeFence": None, "payloadFingerprint": hashlib.sha256(digest.encode()).hexdigest(),
        }, **fields})
        self.assertTrue(created["ok"], created)
        return session_id

    def start_bridge(self, label, launch=None):
        """Start a launch on a new reservation, or with `launch`, one that continues the chat at `label`."""
        if launch is None:
            mount = Path(subprocess.check_output(
                ["python3", "-I", "-S", str(self.scripts / "orca_native.py"), "reserve", str(self.rh), label],
                env=self.env, text=True, timeout=10).strip())
        else:
            mount = Path(subprocess.check_output(
                ["python3", "-EsB", str(self.scripts / "orca-session.py"), "claim", str(self.rh), "claude",
                 label, launch, "/local/project"], env=self.env, text=True, timeout=20).strip().removeprefix("MOUNTPOINT="))
        transport = self.rh / ".sessions" / "transport"
        transport.mkdir(parents=True, exist_ok=True)
        (transport / "ssh_config").touch()
        started = subprocess.run(
            ["bash", str(self.scripts / "inject-rule.sh"), "on", "claude", "/local/project", "testbox",
             str(mount), "normal", str(transport / "ssh_config"), launch or label, "orca"],
            env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(started.returncode, 0, started.stderr)
        values = dict(line.split("=", 1) for line in started.stdout.splitlines())
        command = ("export " + values["RH_LAUNCH_ENV"] + "; exec " + values["RH_LAUNCH_PREFIX"]
                   + " " + values["RH_ORCA_LAUNCH"])
        log = self.home / f"bridge-{label}.log"
        with log.open("w") as stream:
            bridge = subprocess.Popen(["bash", "-c", command], cwd=mount, env=self.env,
                                      stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                      start_new_session=True)
        self.addCleanup(self.stop, bridge)

        def ready():
            self.assertIsNone(bridge.poll(), log.read_text())
            for line in log.read_text().splitlines():
                if line.endswith(("is ready. Open it in Orca.", "is ready again. Continue it in Orca.")):
                    return line.split()[4]
        session_id = wait_for(ready, 40, detail=log.read_text)
        return bridge, log, Path(values["RH_SESSION_DIR"]), mount, session_id

    @staticmethod
    def stop(child):
        if child.poll() is None:
            with suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)

    def test_orca_launches_claude_through_the_harness_wrapper(self):
        version = self.status["appVersion"]
        plain = self.home / "plain" / "project"
        plain.mkdir(parents=True)
        plain_id = self.create_plain_chat(plain)
        self.send(plain_id, "hello")
        raw = self.launch_in(plain)
        flags = {arg.split("=", 1)[0] for arg in raw["args"] if arg.startswith("--")}
        self.assertLessEqual(flags, KNOWN_FLAGS,
                             f"Orca {version} passes Claude flags Harness has not reviewed: {raw['args']}")
        self.assertEqual(raw["env"].get("ORCA_APP_VERSION"), version)

        bridge, log, session, mount, session_id = self.start_bridge("launch")
        self.send(session_id, "hello")
        launch = self.launch_in(mount)
        args = launch["args"]
        self.assertEqual(args.count("--settings"), 1, args)
        settings = json.loads(args[args.index("--settings") + 1])
        guard = settings["hooks"]["PreToolUse"][0]["hooks"][0]
        self.assertEqual(guard["onFailure"], "block")
        self.assertIn("orca_native.py", guard["command"])
        self.assertEqual(args[args.index("--permission-mode") + 1], "default")
        self.assertIn("--append-system-prompt", args)
        self.assertNotIn("--dangerously-skip-permissions", args)
        self.assertTrue(launch["env"]["PATH"].startswith(str(session / "bin") + os.pathsep))
        self.orca.call("agentSession.close", {"sessionId": session_id})
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())

    def test_orca_claude_chat_survives_server_restart(self):
        bridge, log, session, mount, session_id = self.start_bridge("restart")
        self.send(session_id, "before the restart")
        self.launch_in(mount)
        stopped = time.time()
        self.servers.close()
        restarted = self.serve(AFTER, "after")
        self.assertNotEqual(self.status["runtimeId"], restarted["runtimeId"])
        self.send(session_id, "after the restart")
        resumed = self.launch_in(mount, after=stopped)
        self.assertIn("--append-system-prompt", resumed["args"])
        self.assertEqual(resumed["env"].get("ORCA_APP_VERSION"), restarted["appVersion"])
        # Several bridge polls on the new runtime, then the launcher's Ctrl-C.
        time.sleep(5)
        self.assertIsNone(bridge.poll(), log.read_text())
        self.assertTrue((session / "orca-lease.json").exists())
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())
        self.assertNotIn("Lost contact", log.read_text())

    def test_orca_claude_chat_continues_in_a_new_launch(self):
        bridge, log, session, mount, session_id = self.start_bridge("continue")
        self.send(session_id, "before the launcher exits")
        first = self.launch_in(mount)
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())
        shutil.rmtree(session)  # the launcher's cleanup
        listed = subprocess.run(["python3", "-EsB", str(self.scripts / "orca-session.py"), "chats",
                                 str(self.rh), "claude", "/local/project"], env=self.env, text=True,
                                capture_output=True, timeout=20)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual([line.split("\t")[::3] for line in listed.stdout.splitlines()],
                         [["RH_ORCA_CHAT=continue", "before the launcher exits"]])

        stopped = time.time()
        bridge, log, session, mount, resumed = self.start_bridge("continue", "next")
        self.assertEqual(resumed, session_id)
        self.send(session_id, "after the new launch")
        launch = self.launch_in(mount, after=stopped)
        identity = [arg for arg in launch["args"] if arg.startswith(("--session-id", "--resume"))]
        self.assertEqual(identity, [arg for arg in first["args"] if arg.startswith(("--session-id", "--resume"))])
        self.assertIn("--append-system-prompt", launch["args"])
        self.assertEqual(launch["args"][launch["args"].index("--permission-mode") + 1], "default")
        self.assertTrue(launch["env"]["PATH"].startswith(str(session / "bin") + os.pathsep))
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())
        self.assertFalse((session / "orca-lease.json").exists())

    def test_orca_claude_conversation_continues_after_its_workspace_was_deleted(self):
        bridge, log, session, mount, session_id = self.start_bridge("deleted")
        self.send(session_id, "before the workspace is deleted")
        first = self.launch_in(mount)
        provider = next(arg.split("=", 1)[1] for arg in first["args"] if arg.startswith("--session-id="))
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())
        shutil.rmtree(session)
        folder = next(folder for folder in self.orca.call("folderWorkspace.list")["folderWorkspaces"]
                      if folder["folderPath"] == str(mount))
        self.orca.call("folderWorkspace.delete", {"folderWorkspaceId": folder["id"]})
        # The recording Claude keeps no conversation, so write the one a real Claude would have.
        key = "".join(char if char.isalnum() else "-" for char in str(mount))
        transcript = self.home / ".claude" / "projects" / key / f"{provider}.jsonl"
        transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps({
            "type": "user", "sessionId": provider, "cwd": str(mount), "uuid": str(uuid.uuid4()),
            "timestamp": "2026-11-13T00:00:00Z",
            "message": {"role": "user", "content": "before the workspace is deleted"}}) + "\n")

        stopped = time.time()
        bridge, log, session, mount, chat = self.start_bridge("deleted", "next")
        self.assertNotEqual(chat, session_id)
        self.send(chat, "in the new chat")
        launch = self.launch_in(mount, after=stopped)
        self.assertIn(f"--resume={provider}", launch["args"])
        self.assertIn("--append-system-prompt", launch["args"])
        self.assertTrue(launch["env"]["PATH"].startswith(str(session / "bin") + os.pathsep))
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=20), 0, log.read_text())


if __name__ == "__main__":
    unittest.main()
