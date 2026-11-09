#!/usr/bin/env python3
"""Exercise the native Codex launcher and the provider's app-server boundary."""
import json
import os
import queue
import shlex
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

from fixtures.codex_native_model import CHILD_PATH, Model

from test_paseo import PaseoFixture, SCRIPTS



def prepare_proxy(fixture, cli, account_config):
    scripts = fixture.rh / "scripts"
    scripts.mkdir(parents=True)
    for name in ("native-codex.py", "orca_native.py", "native_workspace.py"):
        shutil.copy2(SCRIPTS / name, scripts / name)
    sys.path.insert(0, str(scripts))
    from orca_native import process_identity
    fixture.addCleanup(sys.path.remove, str(scripts))
    sessions = fixture.rh / ".sessions"
    sessions.mkdir(mode=0o700)
    session = sessions / "paseo-codex"
    session.mkdir(mode=0o700)
    (session / "bin").mkdir()
    impl = session / "impl"
    impl.mkdir()
    for name in ("codex-project-tools.py", "orca_native.py", "route-command.py",
                 "run-on-project-host.sh"):
        shutil.copy2(SCRIPTS / name, impl / name)
    (session / "rule.md").write_text("This is the private Harness routing rule.")
    mount = fixture.home / "mount"
    mount.mkdir()
    config = fixture.rh / "codex.json"
    config.write_text(json.dumps({"codex": str(cli)}))
    config.chmod(0o600)
    account = fixture.home / "account"
    account.mkdir()
    (account / "config.toml").write_text(account_config)
    fixture.env.update(CODEX_HOME=str(account), OPENAI_API_KEY="dummy",
                       RH_CODEX_SESSION=str(session), RH_CODEX_TOKEN="test")
    lease = session / "paseo-lease.json"
    lease.write_text(json.dumps({
        "token": "test", "pid": os.getpid(), "identity": process_identity(os.getpid()),
        "cwd": str(mount), "approval": "normal", "python": sys.executable,
        "env": {"PATH": str(session / "bin") + os.pathsep + fixture.env["PATH"]},
    }))
    lease.chmod(0o600)
    wrapper = scripts / "native-codex.py"
    return [sys.executable, "-EsB", str(wrapper), "app-server"], lease, mount


class NativeCodexTests(PaseoFixture):
    def test_reverse_injector_prepares_paseo_native_codex_bridge(self):
        self.script("ssh", "exit 1\n")
        self.script("node", "exit 1\n")
        self.env.update(RH_WARM_MAX="0", RH_HEARTBEAT_TIMEOUT="0")
        mount = self.home / "mount with spaces"
        mount.mkdir()
        transport = self.rh / ".sessions" / "transport"
        transport.mkdir(parents=True)
        config = transport / "ssh_config"
        config.touch()
        for manager in ("paseo",):
            with self.subTest(manager=manager):
                result = subprocess.run(
                    ["bash", str(SCRIPTS / "inject-rule.sh"), "on", "codex", "/project", "testbox",
                     str(mount), "normal", str(config), "codex-" + manager, manager],
                    env=self.env, text=True, capture_output=True, timeout=12,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                values = dict(line.split("=", 1) for line in result.stdout.splitlines())
                self.assertIn("RH_" + manager.upper() + "_LAUNCH", values)
                self.assertEqual(values["RH_LAUNCH_FLAGS"], "")
                self.assertEqual(values["RH_RESUME_AVAILABLE"], "")

    def test_mcp_runner_routes_relative_cwd_and_blocks_after_revocation(self):
        sys.path.insert(0, str(SCRIPTS))
        from orca_native import process_identity
        self.addCleanup(sys.path.remove, str(SCRIPTS))
        session = self.home / "session"
        impl = session / "impl"
        impl.mkdir(parents=True)
        for name in ("codex-project-tools.py", "orca_native.py", "route-command.py",
                     "run-on-project-host.sh"):
            source = SCRIPTS / name
            if source.exists():
                shutil.copy2(source, impl / name)
        mount = self.home / "mount"
        (mount / "sub").mkdir(parents=True)
        runner = session / "bin"
        runner.mkdir()
        stub = self.script("record", 'printf "gateway args: %s\\n" "$@"\n')
        shutil.copy2(stub, runner / "rh-run")
        lease = session / "paseo-lease.json"
        lease.write_text(json.dumps({"token": "test", "pid": os.getpid(),
                                    "identity": process_identity(os.getpid()), "cwd": str(mount), "approval": "normal"}))
        lease.chmod(0o600)
        account = self.home / "account"
        rules = account / "rules"
        rules.mkdir(parents=True)
        (rules / "default.rules").write_text('prefix_rule(pattern=["forbidden"], decision="forbidden")')
        fake = self.script("codex", """
for arg in "$@"; do
    if [ "$arg" = forbidden ]; then
        printf '{"decision":"forbidden"}\n'
        exit 0
    fi
done
printf '{"matchedRules":[]}\n'
""")
        target = session / "codex-home"
        target.mkdir()
        manifest = target / "harness-account.json"
        manifest.write_text(json.dumps({"account": str(account), "command": str(fake)}))
        manifest.chmod(0o600)
        self.assertTrue((impl / "codex-project-tools.py").is_file(),
                        "the native app-server has no guarded project tool")
        with subprocess.Popen(
            [sys.executable, "-EsB", str(impl / "codex-project-tools.py"), lease.name, "test"],
            env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        ) as child:
            def tool(id_, name, **arguments):
                frame = {"jsonrpc": "2.0", "id": id_, "method": "tools/call", "params": {
                    "name": name, "arguments": arguments}}
                child.stdin.write(json.dumps(frame) + "\n")
                child.stdin.flush()
                return json.loads(child.stdout.readline())["result"]

            try:
                allowed = tool(1, "run", command="printf original", cwd="sub")
                self.assertFalse(allowed.get("isError"), allowed)
                self.assertIn("gateway args: --cwd\ngateway args: sub", allowed["content"][0]["text"])
                self.assertIn("gateway args: printf original", allowed["content"][0]["text"])
                for command, cwd in (("codex exec test", "."), ("printf no", "../"),
                                     ("echo okay && forbidden command", ".")):
                    result = tool(2, "run", command=command, cwd=cwd)
                    self.assertTrue(result.get("isError"), result)
                    self.assertNotIn("gateway args", result["content"][0]["text"])
                wrote = tool(3, "write_file", path="sub/edited", content="routed file edit")
                self.assertFalse(wrote["isError"], wrote)
                self.assertEqual((mount / "sub" / "edited").read_text(), "routed file edit")
                self.assertEqual(tool(4, "read_file", path="sub/edited")["content"][0]["text"],
                                 "routed file edit")
                (mount / "link").symlink_to(self.home, target_is_directory=True)
                self.assertTrue(tool(5, "write_file", path="link/outside", content="no")["isError"])
                self.assertFalse((self.home / "outside").exists())
                lease.unlink()
                self.assertTrue(tool(6, "write_file", path="sub/edited", content="no")["isError"])
                self.assertEqual((mount / "sub" / "edited").read_text(), "routed file edit")
                result = tool(7, "run", command="printf no", cwd=".")
                self.assertTrue(result.get("isError"), result)
                self.assertNotIn("gateway args", result["content"][0]["text"])
            finally:
                child.stdin.close()
                child.wait(timeout=5)


    @unittest.skipUnless(sys.version_info >= (3, 11), "requires Python 3.11+")
    def test_app_server_pins_policy_and_exits_when_the_live_lease_is_revoked(self):
        fake = self.home / "app-server.py"
        fake.write_text("""
import json, os, sys
for line in sys.stdin:
    frame = json.loads(line)
    response = {"frame": frame, "codexHome": os.environ["CODEX_HOME"], "pid": os.getpid()}
    if frame.get("method") == "thread/start":
        response["thread"] = {"id": "private-thread"}
    print(json.dumps({"id": frame["id"], "result": response}), flush=True)
""")
        cli = self.script("codex", f"""
if [ "$1" = "--version" ]; then echo 'codex-cli 0.167.0'; exit; fi
if [ "$1" = debug ]; then echo '{{"models":[{{"slug":"fixture","tool_mode":"code_mode_only","multi_agent_version":"v2"}}]}}'; exit; fi
exec {sys.executable!r} {str(fake)!r}
""")
        launch, lease, mount = prepare_proxy(
            self, cli, 'model = "fixture"\nmodel_provider = "fixture-provider"\n'
                       '[features]\ncode_mode = true\n'
                       '[mcp_servers.unsafe]\ncommand = "/bin/sh"\n')
        original = self.home / "account" / "config.toml"
        with subprocess.Popen(
            launch, env=self.env,
            text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) as child:
            def call(id_, method, params):
                child.stdin.write(json.dumps({"id": id_, "method": method, "params": params}) + "\n")
                child.stdin.flush()
                line = child.stdout.readline()
                self.assertTrue(line, child.stderr.read() if not line else "")
                return json.loads(line)

            try:
                started = call(1, "thread/start", {
                    "cwd": str(self.home), "sandbox": "danger-full-access", "approvalPolicy": "never",
                    "config": {"features.shell_tool": True, "mcp_servers": {"unsafe": {}}},
                })["result"]
                backend = started["pid"]
                settings = Path(started["codexHome"]) / "config.toml"
                self.assertNotEqual(settings, original)
                self.assertNotIn("unsafe", settings.read_text())
                import tomllib
                config = tomllib.loads(settings.read_text())
                self.assertFalse(config["features"]["code_mode"]["enabled"])
                self.assertTrue(config["features"]["multi_agent_v2"])
                self.assertEqual((config["model"], config["model_provider"]),
                                 ("fixture", "fixture-provider"))
                catalog = json.loads(Path(config["model_catalog_json"]).read_text())
                self.assertEqual(catalog["models"][0], {
                    "slug": "fixture", "tool_mode": "direct", "multi_agent_version": "v2",
                })
                params = started["frame"]["params"]
                self.assertEqual(params["cwd"], str(mount.resolve()))
                self.assertEqual(params["sandbox"], "workspace-write")
                self.assertEqual(params["approvalsReviewer"], "user")
                self.assertTrue(params["approvalPolicy"]["granular"]["mcp_elicitations"])
                self.assertFalse(params["approvalPolicy"]["granular"]["sandbox_approval"])
                self.assertNotIn("config", params)
                self.assertIn("error", call(2, "command/exec", {"command": ["/bin/sh"]}))
                self.assertIn("error", call(3, "thread/resume", {"threadId": "other-thread"}))
                self.assertIn("error", call(4, "thread/fork", {"threadId": "private-thread"}))
                lease.unlink()
                status = child.wait(timeout=5)
                self.assertEqual(status, 0, child.stderr.read())
                with self.assertRaises(ProcessLookupError):
                    os.kill(backend, 0)
            finally:
                child.stdin.close()
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
        stale = subprocess.run(launch,
                               env=self.env, input="", capture_output=True, text=True, timeout=5)
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(stale.stdout, "")


CODEX = os.environ.get("RH_TEST_CODEX_CLI")


@unittest.skipUnless(CODEX and sys.version_info >= (3, 11) and shutil.which("zstd"),
                     "set RH_TEST_CODEX_CLI with Python 3.11+ and zstd for real Codex tests")
class NativeCodexRuntimeTests(PaseoFixture):
    def test_v2_default_history_fork_uses_the_project_route(self):
        self.exercise_v2_subagent({})

    def test_v2_fresh_context_uses_the_project_route(self):
        self.exercise_v2_subagent({"fork_turns": "none"})

    def test_v2_followup_messages_wait_and_interrupt(self):
        self.exercise_v2_subagent({}, exercise_collaboration=True)

    def exercise_v2_subagent(self, fork_arguments, exercise_collaboration=False):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        server.requests = []
        server.tool_names = {True: set(), False: set()}
        server.blocked_outputs = {}
        server.fork_arguments = fork_arguments
        if exercise_collaboration:
            server.interrupt_approval = threading.Event()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env = {"HOME": str(self.home), "PATH": self.env["PATH"], "RH_FIXTURE_API_KEY": "dummy",
                    "TMPDIR": "/tmp", "RUST_LOG": "error"}
        cli = Path(CODEX).resolve(strict=True)
        launch, lease, mount = prepare_proxy(self, cli, f"""
model = "gpt-6.1-sol"
model_provider = "rh_fixture"
[model_providers.rh_fixture]
name = "fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
env_key = "RH_FIXTURE_API_KEY"
wire_api = "responses"
supports_websockets = false
""")
        server.mount = str(mount.resolve())
        (mount / "sub").mkdir()
        project = self.home / "project-host"
        (project / "sub").mkdir(parents=True)
        script = self.script("runner", f'cd {shlex.quote(str(project))}/"$2" || exit 2\nexec sh -c "$4"\n')
        shutil.copy2(script, lease.parent / "bin" / "rh-run")
        marker = project / "sub" / "subagent-marker"
        followup = project / "sub" / "followup-marker"
        interrupted = project / "sub" / "interrupted-marker"
        log = self.home / "codex.log"
        with log.open("w") as stderr, subprocess.Popen(
            launch, env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr,
        ) as child:
            frames = queue.Queue()

            def read():
                for line in child.stdout:
                    frames.put(json.loads(line))
                frames.put(None)

            threading.Thread(target=read, daemon=True).start()

            def send(frame):
                child.stdin.write(json.dumps(frame) + "\n")
                child.stdin.flush()

            try:
                send({"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "rh_test", "version": "1"},
                    "capabilities": {"experimentalApi": True},
                }})
                approval_threads = {}
                spawned_thread = None
                deadline = time.monotonic() + 35
                while time.monotonic() < deadline:
                    try:
                        frame = frames.get(timeout=0.2)
                    except queue.Empty:
                        continue
                    self.assertIsNotNone(frame, log.read_text())
                    self.assertNotIn("error", frame, frame)
                    if frame.get("id") == 1 and "result" in frame:
                        send({"method": "initialized"})
                        send({"id": 2, "method": "thread/start", "params": {"cwd": str(mount)}})
                    if frame.get("id") == 2 and "result" in frame:
                        thread = frame["result"]["thread"]["id"]
                        send({"id": 3, "method": "turn/start", "params": {"threadId": thread,
                              "input": [{"type": "text", "text": "RH_START_CHILD Start the fixture subagent.",
                                         "text_elements": []}]}})
                    if frame.get("method") == "mcpServer/elicitation/request":
                        params = frame["params"]
                        self.assertNotEqual(params["threadId"], thread)
                        self.assertIn("Project directory: sub", params["message"])
                        command = params["_meta"]["tool_params"]["command"]
                        approval_threads[command] = params["threadId"]
                        self.assertIn(command, params["message"])
                        if command == "printf interrupted > interrupted-marker":
                            self.assertTrue(exercise_collaboration)
                            server.interrupt_approval.set()
                        else:
                            expected_file = followup if "followup-approved" in command else marker
                            self.assertFalse(expected_file.exists())
                            send({"id": frame["id"], "result": {"action": "accept", "content": None,
                                                               "_meta": None}})
                    if frame.get("method") == "item/completed":
                        item = frame["params"]["item"]
                        if item.get("type") == "subAgentActivity" and item.get("kind") == "started":
                            self.assertEqual(item.get("agentPath"), CHILD_PATH)
                            spawned_thread = item["agentThreadId"]
                    if frame.get("method") == "turn/completed" and frame["params"]["threadId"] == thread:
                        self.assertIn(("collaboration", "spawn_agent"), server.tool_names[False])
                        break
                self.assertIsNotNone(spawned_thread, log.read_text() + repr(server.tool_names))
                self.assertEqual(approval_threads["printf child-approved > subagent-marker"], spawned_thread)
                self.assertEqual(set(approval_threads.values()), {spawned_thread})
                self.assertTrue(any(
                    item.get("type") == "function_call_output"
                    and item["call_id"].startswith("main_")
                    and item["output"] == json.dumps({"task_name": CHILD_PATH}, separators=(",", ":"))
                    for request in server.requests for item in request["input"]
                ), "Spawn did not return the V2 child task name")
                self.assertTrue(marker.exists(), log.read_text())
                self.assertEqual(marker.read_text(), "child-approved")
                self.assertFalse((mount / "sub" / "subagent-marker").exists())
                self.assertIn(("collaboration", "spawn_agent"), server.tool_names[False])
                self.assertNotIn(("multi_agent_v1", "spawn_agent"), server.tool_names[False])
                self.assertIn(("mcp__remote_harness", "run"), server.tool_names[True])
                self.assertIn(("functions", "apply_patch"), server.tool_names[False])
                self.assertFalse((mount / "unguarded-shell").exists())
                self.assertEqual(set(server.blocked_outputs), {"shell_", "code_", "patch_"},
                                 (server.blocked_outputs, log.read_text()))
                self.assertIn("unsupported call: exec_command", server.blocked_outputs["shell_"])
                self.assertIn("unsupported custom tool call: exec", server.blocked_outputs["code_"])
                self.assertEqual((mount / "native-patch-marker").read_text(), "mounted file change\n")
                blocked = {"exec_command", "shell", "shell_command", "python", "node_repl", "exec", "wait"}
                for names in server.tool_names.values():
                    self.assertTrue({name for _, name in names}.isdisjoint(blocked), names)
                if exercise_collaboration:
                    self.assertEqual(followup.read_text(), "followup-approved")
                    self.assertFalse(interrupted.exists())
                    self.assertFalse((mount / "sub" / "followup-marker").exists())
                    self.assertIn("printf interrupted > interrupted-marker", approval_threads)
                    self.assertTrue(any(
                        item.get("type") == "agent_message"
                        and item.get("recipient") == CHILD_PATH
                        and "RH_CHILD_QUEUED" in json.dumps(item["content"])
                        for request in server.requests for item in request["input"]
                    ), "Queued V2 message was not delivered")
                    outputs = {item["call_id"].split("_", 1)[0]: item["output"]
                               for item in server.requests[-1]["input"]
                               if item.get("type") == "function_call_output"}
                    self.assertEqual(outputs["send"], "")
                    self.assertEqual(outputs["followup"], "")
                    self.assertFalse(json.loads(outputs["waitagain"])["timed_out"])
                    self.assertIn(CHILD_PATH, outputs["list"])
                    self.assertEqual(json.loads(outputs["interrupt"])["previous_status"], "running")
            finally:
                child.stdin.close()
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
