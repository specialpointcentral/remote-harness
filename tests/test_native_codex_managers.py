#!/usr/bin/env python3
"""Opt-in tests of the native manager RPCs with the pinned Codex and a loopback model."""
from contextlib import ExitStack, contextmanager, suppress
import hashlib
import importlib.util
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

from fixtures.codex_native_model import Model
from test_native_codex import CODEX
from test_paseo import ROOT, SCRIPTS

_spec = importlib.util.spec_from_file_location("orca_native", SCRIPTS / "orca_native.py")
orca_native = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(orca_native)

ORCA = os.environ.get("RH_TEST_ORCA_CLI")
PASEO = os.environ.get("RH_TEST_PASEO_NODE_MODULES")
PASEO_DRIVER = ROOT / "tests" / "fixtures" / "codex_native_paseo.mjs"
PROMPT = "RH_START_CHILD Start the fixture subagent."
COMMAND = "printf child-approved > subagent-marker"


def wait_for(predicate, seconds=25, detail=lambda: ""):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {predicate.__name__}. {detail()}")


@contextmanager
def process(command, env, cwd, log_path, **options):
    with log_path.open("w") as log, subprocess.Popen(
        command, env=env, cwd=cwd, stdin=subprocess.PIPE, stdout=options.get("stdout", log),
        stderr=log, start_new_session=True, text=True,
    ) as child:
        try:
            yield child
        finally:
            with suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                pass
            finally:
                with suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)


class Orca:
    def __init__(self, profile):
        self.profile = profile

    def call(self, method, params=None):
        meta = json.loads((self.profile / "orca-runtime.json").read_text())
        endpoint = next(transport["endpoint"] for transport in meta["transports"]
                        if transport["kind"] == "unix")
        identity = str(uuid.uuid4())
        request = {"id": identity, "authToken": meta["authToken"], "method": method}
        if params is not None:
            request["params"] = params
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(10)
            connection.connect(endpoint)
            connection.sendall((json.dumps(request) + "\n").encode())
            with connection.makefile("rb") as stream:
                for line in stream:
                    response = json.loads(line)
                    if response.get("id") == identity:
                        if not response["ok"]:
                            raise RuntimeError(response["error"])
                        return response["result"]
        raise RuntimeError("Orca closed the RPC socket before responding")

    def ready(self):
        try:
            status = self.call("status.get")
        except (OSError, ValueError, KeyError, RuntimeError):
            return False
        return "agent-session.structured.v1" in status.get("capabilities", [])


@unittest.skipUnless(CODEX and shutil.which("zstd"), "set RH_TEST_CODEX_CLI and install zstd")
class NativeCodexManagerTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory(prefix="rh-v2-", dir="/tmp")
        self.addCleanup(home.cleanup)
        self.home = Path(home.name).resolve()
        self.rh = self.home / "rh"
        self.rh.mkdir(mode=0o700)
        self.scripts = self.rh / "scripts"
        shutil.copytree(SCRIPTS, self.scripts, ignore=shutil.ignore_patterns("__pycache__"))
        self.project = self.home / "project"
        (self.project / "sub").mkdir(parents=True)
        self.marker = self.project / "sub/subagent-marker"
        self.ssh = self.home / "ssh_config"
        self.ssh.touch()
        self.env = {
            "HOME": str(self.home), "PATH": os.environ["PATH"], "RH_HOME": str(self.rh),
            "RH_WARM_MAX": "0", "RH_HEARTBEAT_TIMEOUT": "0", "RH_FIXTURE_API_KEY": "dummy",
            "RUST_LOG": "error",
        }
        codex = self.rh / "codex.json"
        codex.write_text(json.dumps({"codex": str(Path(CODEX).resolve(strict=True))}))
        codex.chmod(0o600)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        server.requests = []
        server.tool_names = {True: set(), False: set()}
        server.blocked_outputs = {}
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.server = server
        account = self.home / ".codex"
        account.mkdir()
        (account / "config.toml").write_text(f"""
model = "gpt-6.1-sol"
model_provider = "rh_fixture"
[model_providers.rh_fixture]
name = "fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
env_key = "RH_FIXTURE_API_KEY"
wire_api = "responses"
supports_websockets = false
""")

    @contextmanager
    def bridge(self, manager, launch="native-v2"):
        (self.mount / "sub").mkdir(parents=True, exist_ok=True)
        self.server.mount = str(self.mount)
        started = subprocess.run(
            ["bash", str(self.scripts / "inject-rule.sh"), "on", "codex", str(self.project),
             "fixture", str(self.mount), "normal", str(self.ssh), launch, manager],
            env=self.env, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(started.returncode, 0, started.stderr)
        values = dict(line.split("=", 1) for line in started.stdout.splitlines())
        self.session = Path(values["RH_SESSION_DIR"])
        # Substitute a runner for SSH. Distinct project and mount directories reveal wrong-host
        # execution while keeping the test independent of external hosts and credentials.
        (self.session / "bin/rh-run").write_text(
            f'#!/bin/sh\ncd {shlex.quote(str(self.project))}/"$2" || exit 2\nexec sh -c "$4"\n')
        log = self.home / "bridge.log"
        command = ("export " + values["RH_LAUNCH_ENV"] + "; exec " + values["RH_LAUNCH_PREFIX"]
                   + " " + values[f"RH_{manager.upper()}_LAUNCH"])
        with process(["bash", "-c", command], self.env, self.mount, log) as child:
            def ready():
                self.assertIsNone(child.poll(), log.read_text())
                match = re.search(r" (?:chat|agent) ([\w-]+) is ready", log.read_text())
                return match[1] if match else None

            yield child, wait_for(ready, detail=log.read_text)
            self.assertEqual(child.wait(timeout=12), 0, log.read_text())
            self.assertFalse((self.session / f"{manager}-lease.json").exists())

    def root_thread(self):
        return json.loads((self.session / "codex-thread.json").read_text())["thread"]

    def verify_approval(self, thread, description):
        self.assertTrue(thread)
        self.assertNotEqual(thread, self.root_thread())
        self.assertIn(f"Project directory: sub\n{COMMAND}", description)
        self.assertFalse(self.marker.exists(), "Project command ran before approval")

    def verify_effects(self, approved):
        patch = self.mount / "native-patch-marker"
        if approved:
            wait_for(patch.is_file)
            self.assertEqual(self.marker.read_text(), "child-approved")
            self.assertEqual(patch.read_text(), "mounted file change\n")
            self.assertIn("unsupported call: exec_command", self.server.blocked_outputs["shell_"])
            self.assertIn("unsupported custom tool call: exec", self.server.blocked_outputs["code_"])
        else:
            self.assertFalse(self.marker.exists())
            self.assertFalse(patch.exists())
        self.assertFalse((self.mount / "sub/subagent-marker").exists())
        self.assertFalse((self.mount / "unguarded-shell").exists())
        self.assertEqual({request["model"] for request in self.server.requests}, {"gpt-6.1-sol"})
        self.assertIn(("collaboration", "spawn_agent"), self.server.tool_names[False])
        self.assertIn(("mcp__remote_harness", "run"), self.server.tool_names[True])

    def backend_pid(self):
        listing = subprocess.check_output(["/bin/ps", "-wwaxo", "pid=,command="], text=True,
                                          timeout=5)
        matches = [int(line.split()[0]) for line in listing.splitlines()
                   if "app-server --listen stdio://" in line and str(self.mount) in line]
        self.assertLessEqual(len(matches), 1, matches)
        return matches[0] if matches else None

    def revoke_pending(self, bridge, late_approval):
        self.assertIsNotNone(self.backend_pid(), "Expected a live private app server")
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=12), 0)
        wait_for(lambda: self.backend_pid() is None)
        model_requests = len(self.server.requests)
        late_approval()
        self.assertIsNone(self.backend_pid())
        self.assertEqual(len(self.server.requests), model_requests, "Late approval reached Codex")
        self.verify_effects(approved=False)

    @unittest.skipUnless(ORCA, "set RH_TEST_ORCA_CLI to a supported Orca CLI")
    def test_orca_approves_child_command_and_applies_child_edit(self):
        self.exercise_orca(approve=True)

    @unittest.skipUnless(ORCA, "set RH_TEST_ORCA_CLI to a supported Orca CLI")
    def test_orca_revokes_lease_with_child_approval_pending(self):
        self.exercise_orca(approve=False)

    def prepare_orca(self, *clis):
        for cli in clis:
            version = subprocess.check_output([cli, "--version"], text=True, timeout=10).strip()
            self.assertIsNotNone(orca_native.version_support(version, orca_native.ORCA_VERSIONS), version)
        profile = self.home / "profile"
        profile.mkdir(mode=0o700)
        self.env.update(ORCA_USER_DATA_PATH=str(profile), ORCA_SERVE_RUNTIME="electron",
                        TMPDIR=str(self.home), LANG="en_US.UTF-8")
        (self.rh / ".orca-mounts").mkdir(mode=0o700)
        self.mount = self.rh / ".orca-mounts/native-v2"
        (self.rh / "orca").mkdir(mode=0o700)
        config = self.rh / "orca/codex.json"
        config.write_text(json.dumps({"profile": str(profile), "model": "gpt-6.1-sol"}))
        config.chmod(0o600)
        with socket.socket() as temporary_port:
            temporary_port.bind(("127.0.0.1", 0))
            return Orca(profile), temporary_port.getsockname()[1]

    def serve_orca(self, servers, cli, orca, port, name):
        log = self.home / f"orca-{name}.log"
        servers.enter_context(process([cli, "serve", "--no-pairing", "--port", str(port)],
                                      self.env, self.home, log))
        wait_for(orca.ready, 90, detail=log.read_text)
        return orca.call("status.get")

    def orca_chat(self, orca, session_id):
        """The page, envelope and send helpers the native chat RPCs need."""
        def page():
            return orca.call("agentSession.history", {
                "sessionId": session_id, "direction": "tail", "limit": 80,
            })["page"]

        def envelope(method, fields):
            data = {"method": method, "sessionId": session_id, "fields": fields}
            return {"sessionId": session_id,
                    "clientOperationId": f"{int(time.time()*1000)}-{uuid.uuid4().hex}",
                    "expectedRuntimeFence": page()["fence"],
                    "payloadFingerprint": hashlib.sha256(json.dumps(
                        data, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                    ).encode()).hexdigest()}

        def send(text):
            body = {"kind": "message", "role": "user", "blocks": [{"type": "text", "text": text}]}
            sent = orca.call("agentSession.send", {
                "envelope": envelope("agentSession.send", {"body": body}), "body": body,
            })
            self.assertTrue(sent["ok"], sent)

        def pending():
            return next((item for item in page()["items"]
                         if item["body"].get("kind") == "approval"
                         and item["body"]["resolution"]["state"] == "pending"), None)

        def respond(approval):
            fields = {"itemId": approval["itemId"], "expectedRevision": approval["revision"],
                      "optionId": next(o["id"] for o in approval["body"]["options"]
                                       if o["label"] == "Allow")}
            return orca.call("agentSession.respondToApproval", {
                "envelope": envelope("agentSession.respondTo:approval", fields), **fields,
            })
        return page, send, pending, respond

    @unittest.skipUnless(ORCA, "set RH_TEST_ORCA_CLI to a supported Orca CLI")
    def test_orca_codex_chat_survives_server_restart(self):
        # RH_TEST_ORCA_AFTER switches builds across the restart, as an automatic update does.
        after = os.environ.get("RH_TEST_ORCA_AFTER") or ORCA
        orca, port = self.prepare_orca(ORCA, after)
        with ExitStack() as servers:
            first = self.serve_orca(servers, ORCA, orca, port, "before")
            orca.call("settings.mutateAgentLaunch", {
                "type": "command", "agent": "codex", "value": str(self.scripts / "native-codex.py"),
            })
            with self.bridge("orca") as (bridge, session_id):
                page, send, pending, respond = self.orca_chat(orca, session_id)
                # One ordinary turn, so the private app server and the Codex thread exist.
                send("hello before the restart")
                wait_for(self.backend_pid, 40, detail=lambda: json.dumps(page())[-3000:])
                wait_for(lambda: not page()["working"], 40)
                thread = self.root_thread()
                servers.close()
                wait_for(lambda: self.backend_pid() is None, 20)
                second = self.serve_orca(servers, after, orca, port, "after")
                self.assertNotEqual(first["runtimeId"], second["runtimeId"])
                send(PROMPT)
                approval = wait_for(pending, 40, detail=lambda: json.dumps(page())[-4000:])
                self.verify_approval(approval["agentId"], approval["body"]["title"])
                self.assertEqual(self.root_thread(), thread, "The chat must resume its Codex thread")
                responded = respond(approval)
                self.assertTrue(responded["ok"], responded)
                self.verify_effects(True)
                wait_for(lambda: not page()["working"])
                # A restarted runtime may not list the chat tab again, so end like Ctrl-C.
                time.sleep(5)
                self.assertIsNone(bridge.poll(), (self.home / "bridge.log").read_text())
                bridge.terminate()
            self.verify_effects(True)
            self.assertNotIn("Lost contact", (self.home / "bridge.log").read_text())

    @unittest.skipUnless(ORCA, "set RH_TEST_ORCA_CLI to a supported Orca CLI")
    def test_orca_codex_chat_continues_in_a_new_launch(self):
        orca, port = self.prepare_orca(ORCA)
        self.mount.mkdir(mode=0o700)  # as orca_native.py reserves it
        with ExitStack() as servers:
            self.serve_orca(servers, ORCA, orca, port, "server")
            orca.call("settings.mutateAgentLaunch", {
                "type": "command", "agent": "codex", "value": str(self.scripts / "native-codex.py"),
            })
            with self.bridge("orca") as (bridge, session_id):
                page, send, pending, respond = self.orca_chat(orca, session_id)
                send("remember the word heliotrope")
                wait_for(self.backend_pid, 40, detail=lambda: json.dumps(page())[-3000:])
                wait_for(lambda: not page()["working"], 40)
                thread = self.root_thread()
                bridge.terminate()
            # The launcher's cleanup unmounts the project and removes the session.
            shutil.rmtree(self.session)
            for child in self.mount.iterdir():
                shutil.rmtree(child)
            tool = [sys.executable, "-EsB", str(self.scripts / "orca-session.py")]
            listed = subprocess.run([*tool, "chats", str(self.rh), "codex", str(self.project)],
                                    env=self.env, text=True, capture_output=True, timeout=20)
            self.assertEqual(listed.returncode, 0, listed.stderr)
            self.assertEqual([line.split("\t")[::3] for line in listed.stdout.splitlines()],
                             [["RH_ORCA_CHAT=native-v2", "remember the word heliotrope"]])
            claimed = subprocess.run([*tool, "claim", str(self.rh), "codex", "native-v2", "next",
                                      str(self.project)], env=self.env, text=True, capture_output=True,
                                     timeout=20)
            self.assertEqual(claimed.stdout, f"MOUNTPOINT={self.mount}\n", claimed.stderr)
            before = len(self.server.requests)
            with self.bridge("orca", "next") as (bridge, resumed):
                self.assertEqual(resumed, session_id)
                send("which word?")
                wait_for(lambda: len(self.server.requests) > before, 40,
                         detail=lambda: json.dumps(page())[-3000:])
                wait_for(lambda: not page()["working"], 40)
                self.assertEqual(self.root_thread(), thread, "The chat must resume its Codex thread")
                self.assertIn("remember the word heliotrope", json.dumps(self.server.requests[before]))
                bridge.terminate()

    def exercise_orca(self, approve):
        orca, port = self.prepare_orca(ORCA)
        with ExitStack() as servers:
            self.serve_orca(servers, ORCA, orca, port, "server")
            orca.call("settings.mutateAgentLaunch", {
                "type": "command", "agent": "codex", "value": str(self.scripts / "native-codex.py"),
            })
            with self.bridge("orca") as (bridge, session_id):
                catalog = orca.call("worktree.ps", {"limit": 10000,
                                                    "supportsWorktreeVisibilitySourceDefaults": True})
                visible = [row for row in catalog["worktrees"] if row["path"] == str(self.mount)]
                self.assertEqual(len(visible), 1, "The desktop client must discover the Harness workspace")
                self.assertEqual(visible[0]["workspaceKind"], "folder-workspace")
                page, send, pending, respond = self.orca_chat(orca, session_id)
                send(PROMPT)
                approval = wait_for(pending, detail=lambda: json.dumps(page())[-5000:])
                self.verify_approval(approval["agentId"], approval["body"]["title"])
                if approve:
                    responded = respond(approval)
                    self.assertTrue(responded["ok"], responded)
                    self.verify_effects(approve)
                    wait_for(lambda: not page()["working"])
                    orca.call("agentSession.close", {"sessionId": session_id})
                else:
                    def late_approval():
                        with suppress(RuntimeError):
                            respond(approval)

                    self.revoke_pending(bridge, late_approval)
            self.verify_effects(approve)

    @unittest.skipUnless(PASEO and shutil.which("node"), "set RH_TEST_PASEO_NODE_MODULES and install Node")
    def test_paseo_approves_child_command_and_applies_child_edit(self):
        self.exercise_paseo(approve=True)

    @unittest.skipUnless(PASEO and shutil.which("node"), "set RH_TEST_PASEO_NODE_MODULES and install Node")
    def test_paseo_revokes_lease_with_child_approval_pending(self):
        self.exercise_paseo(approve=False)

    def exercise_paseo(self, approve):
        modules = Path(PASEO).resolve(strict=True)
        for name in ("client", "server"):
            manifest = json.loads((modules / f"@getpaseo/{name}/package.json").read_text())
            self.assertEqual(manifest["version"], "0.15.3")
        self.mount = self.home / "mount"
        (self.rh / "paseo").mkdir()
        (self.rh / "paseo/node_modules").symlink_to(modules, target_is_directory=True)
        home = self.home / "paseo-home"
        home.mkdir()
        self.env.update(PASEO_HOME=str(home), RH_PASEO_MODEL="gpt-6.1-sol")
        (home / "config.json").write_text(json.dumps({
            "version": 1, "daemon": {"listen": "127.0.0.1:0", "relay": {"enabled": False},
                                     "mcp": {"enabled": False, "injectIntoAgents": False}},
            "agents": {"metadataGeneration": {"providers": []}, "providers": {
                "codex": {"command": [str(self.scripts / "native-codex.py")]},
                **{name: {"enabled": False} for name in ("claude", "copilot", "opencode", "pi", "omp")},
            }},
        }))
        log = self.home / "paseo.log"
        with process(["node", str(PASEO_DRIVER), "serve", str(modules)], self.env, self.home, log) as daemon:
            def listening():
                self.assertIsNone(daemon.poll(), log.read_text())
                for line in log.read_text().splitlines():
                    if line.startswith('{"port":'):
                        return json.loads(line)["port"]

            self.env["RH_PASEO_URL"] = f"ws://127.0.0.1:{wait_for(listening, detail=log.read_text)}/ws"
            with self.bridge("paseo") as (bridge, agent_id):
                driver = ["node", str(PASEO_DRIVER), "approve", str(modules),
                          self.env["RH_PASEO_URL"], agent_id]
                driver_log = self.home / "paseo-driver.log"
                with process(driver, self.env, self.home, driver_log, stdout=subprocess.PIPE) as client:
                    ready, _, _ = select.select([client.stdout], [], [], 35)
                    self.assertTrue(ready, driver_log.read_text())
                    approval = client.stdout.readline()
                    self.assertTrue(approval, driver_log.read_text())
                    request = json.loads(approval)
                    self.verify_approval(request["metadata"]["threadId"], request["description"])
                    def respond():
                        client.stdin.write("allow\n")
                        client.stdin.flush()
                        return client.wait(timeout=12)

                    if approve:
                        self.assertEqual(respond(), 0, driver_log.read_text())
                        self.verify_effects(approve)
                        bridge.terminate()
                    else:
                        self.revoke_pending(bridge, respond)
            self.verify_effects(approve)


if __name__ == "__main__":
    unittest.main()
