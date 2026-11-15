#!/usr/bin/env python3
"""Private stdio MCP server for commands and UTF-8 files in one native Harness chat."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import threading
import time
import uuid

from orca_native import LEASE, OrcaError, active_lease, private_json, session_presentation

MAX_CONTENT = 512 * 1024
MAX_OUTPUT = 128 * 1024
MAX_FRAME = 8 * 1024 * 1024
WORKERS = 8
TOOL_ARGS = {
    "run": ("command", "cwd"),
    "read_file": ("path",),
    "write_file": ("path", "content"),
}
DESCRIPTIONS = {
    "run": "Run a shell command on the project host. Use project-relative paths in the command. "
           "cwd is optional and relative to the project root. No stdin or interactive terminal.",
    "read_file": "Read a UTF-8 file on the mounted project. path is relative to the project root.",
    "write_file": "Create or replace a UTF-8 file on the mounted project. "
                  "path is relative to the project root and its parent must exist.",
}


def tools():
    return [{
        "name": name, "description": DESCRIPTIONS[name],
        "annotations": {"readOnlyHint": name == "read_file", "openWorldHint": name == "run"},
        "inputSchema": {"type": "object", "additionalProperties": False,
                        "required": [arg for arg in args if arg != "cwd"],
                        "properties": {arg: {"type": "string"} for arg in args}},
    } for name, args in TOOL_ARGS.items()]


def result(text, failed=False):
    return {"content": [{"type": "text", "text": text}], "isError": failed}


def relative_path(value):
    if not isinstance(value, str) or not value or len(value) > 4096 or "\0" in value:
        raise ValueError("invalid relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("path must be relative to the project")
    return path


@contextmanager
def parent_fd(mount, path):
    """Traverse the mount with no symlinks and hold the directory through the file operation."""
    if not path.name:
        raise ValueError("file path must name a file")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(mount, flags)
    try:
        for part in path.parts[:-1]:
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


class ProjectTools:
    def __init__(self, session, lease_name, token):
        if lease_name not in (LEASE, "paseo-lease.json"):
            raise ValueError("invalid lease name")
        self.lease = session / lease_name
        self.token = token
        lease = self.check()
        session_presentation(session, lease)  # Validate once at startup; project results stay original.
        self.mount = Path(lease["cwd"]).resolve(strict=True)
        self.approval = lease["approval"]
        account = private_json(session / "codex-home" / "harness-account.json")
        self.codex = account["command"]
        self.rules_dirs = (Path("/etc/codex/rules"), Path(account["account"]) / "rules")
        self.runner = session / "bin" / "rh-run"
        loader = SourceFileLoader("harness_route", str(Path(__file__).with_name("route-command.py")))
        spec = spec_from_loader(loader.name, loader)
        self.route = module_from_spec(spec)
        loader.exec_module(self.route)

    def check(self, cancelled=None):
        if cancelled is not None and cancelled.is_set():
            raise OrcaError("Remote Harness tool call cancelled.")
        return active_lease(self.lease, self.token)

    def rules_decision(self, command, commands, cancelled):
        files = [path for directory in self.rules_dirs for path in sorted(directory.glob("*.rules"))]
        if not files:
            return None
        if len(files) > 64 or len(commands) > 64:
            raise ValueError("too many command policy inputs")
        flags = [arg for path in files for arg in ("--rules", str(path))]
        # The CLI check consumes argv. Reuse the gateway lexer to give it each command in a
        # compound shell expression, and also check rules explicitly matching a shell wrapper.
        for words in (["/bin/bash", "-c", command], ["/bin/bash", "-lc", command], *commands):
            self.check(cancelled)
            output = subprocess.check_output(
                [self.codex, "execpolicy", "check", "--resolve-host-executables", *flags, "--", *words],
                stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, timeout=5,
            )
            decision = json.loads(output).get("decision")
            if decision == "forbidden" or (decision == "prompt" and self.approval == "yolo"):
                return decision
            if decision not in (None, "allow", "prompt"):
                raise ValueError("invalid command policy result")
        return None

    def run(self, args, cancelled):
        command = args["command"]
        if not command.strip() or len(command.encode()) > 32768 or "\0" in command:
            return result("Remote Harness rejected the command input.", True)
        cwd = (self.mount / relative_path(args.get("cwd", "."))).resolve(strict=True)
        if not cwd.is_dir() or (cwd != self.mount and self.mount not in cwd.parents):
            return result("Remote Harness working directory must be inside the project.", True)
        launches_agent, commands = self.route.command_policy(command)
        if launches_agent or any(words and Path(words[0]).name in (
                "orca", "orca-ide", "orca-dev", "orcad", "paseo", "paseod", "native-codex.py")
                for words in commands):
            return result("Remote Harness blocks independent agent launches in project commands.", True)
        if self.rules_decision(command, commands, cancelled):
            return result("Codex execution policy blocked the routed command.", True)
        self.check(cancelled)
        with subprocess.Popen([str(self.runner), "--cwd", str(cwd.relative_to(self.mount)),
                               "--", command], cwd=self.mount, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as child:
            tail = bytearray()
            truncated = False
            next_check = 0
            try:
                while True:
                    if time.monotonic() >= next_check or cancelled.is_set():
                        self.check(cancelled)
                        next_check = time.monotonic() + 1
                    if not select.select([child.stdout], [], [], 0.2)[0]:
                        continue
                    chunk = os.read(child.stdout.fileno(), 65536)
                    tail.extend(chunk)
                    if len(tail) > MAX_OUTPUT:
                        truncated = True
                        del tail[:-MAX_OUTPUT]
                    if not chunk:
                        break
                status = child.wait(timeout=2)
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
        output = tail.decode("utf8", errors="replace")
        prefix = "[Earlier output truncated]\n" if truncated else ""
        return result(f"Exit code: {status}\n{prefix}{output}", status != 0)

    def file(self, name, args, cancelled):
        path = relative_path(args["path"])
        self.check(cancelled)
        with parent_fd(self.mount, path) as parent:
            if name == "read_file":
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                with os.fdopen(fd, "rb") as stream:
                    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                        raise ValueError("file must be regular")
                    content = stream.read(MAX_CONTENT + 1)
                if len(content) > MAX_CONTENT:
                    return result("File exceeds the UTF-8 tool limit. Use a routed project command.", True)
                self.check(cancelled)
                return result(content.decode("utf8"))
            content = args["content"].encode("utf8")
            if len(content) > MAX_CONTENT:
                return result("Content exceeds the UTF-8 tool limit. Use a routed project command.", True)
            mode = None
            try:
                target = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if not stat.S_ISREG(target.st_mode):
                    raise ValueError("file must be regular")
                mode = stat.S_IMODE(target.st_mode) & 0o777
            temporary = ".rh-edit-" + uuid.uuid4().hex
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o666 if mode is None else mode, dir_fd=parent)
            try:
                with os.fdopen(fd, "wb") as stream:
                    if mode is not None:
                        os.fchmod(stream.fileno(), mode)
                    stream.write(content)
                self.check(cancelled)
                os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                try:
                    os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass
        return result("Wrote " + str(path))

    def call(self, params, cancelled):
        try:
            name = params["name"]
            args = params.get("arguments", {})
            if (name not in TOOL_ARGS or not isinstance(args, dict) or args.keys() - set(TOOL_ARGS[name])
                    or any(not isinstance(value, str) for value in args.values())):
                raise ValueError("invalid tool arguments")
            self.check(cancelled)
            return self.run(args, cancelled) if name == "run" else self.file(name, args, cancelled)
        except OrcaError:
            return result("Remote Harness transport ended or the tool was cancelled. Start a new Harness chat if disconnected.", True)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            return result("Remote Harness refused the operation or the project is unavailable.", True)


def main():
    project = ProjectTools(Path(__file__).resolve().parent.parent, *sys.argv[1:])
    output_lock = threading.Lock()
    pending = {}

    def reply(identity, data=None, error=None):
        frame = {"jsonrpc": "2.0", "id": identity}
        if error is not None:
            frame["error"] = {"code": -32601, "message": error}
        else:
            frame["result"] = data
        with output_lock:
            print(json.dumps(frame, ensure_ascii=True), flush=True)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        try:
            while line := sys.stdin.buffer.readline(MAX_FRAME + 1):
                if len(line) > MAX_FRAME:
                    raise ValueError("oversized tool request")
                request = json.loads(line)
                identity, method = request.get("id"), request.get("method")
                params = request.get("params") or {}
                if method == "notifications/cancelled":
                    with output_lock:
                        if event := pending.get(params.get("requestId")):
                            event.set()
                if identity is None:
                    continue
                if method == "initialize":
                    reply(identity, {"protocolVersion": params["protocolVersion"],
                                     "capabilities": {"tools": {}},
                                     "serverInfo": {"name": "remote-harness", "version": "1"}})
                elif method == "ping":
                    reply(identity, {})
                elif method == "tools/list":
                    reply(identity, {"tools": tools()})
                elif method == "tools/call":
                    with output_lock:
                        capacity = identity not in pending and len(pending) < WORKERS
                        if capacity:
                            event = pending[identity] = threading.Event()
                    if not capacity:
                        reply(identity, result("Remote Harness project tools are busy.", True))
                        continue

                    def complete(req_id, tool_params, cancelled):
                        try:
                            reply(req_id, project.call(tool_params, cancelled))
                        finally:
                            with output_lock:
                                pending.pop(req_id, None)

                    pool.submit(complete, identity, params, event)
                else:
                    reply(identity, error="Unsupported project tool request")
        finally:
            with output_lock:
                for event in pending.values():
                    event.set()


if __name__ == "__main__":
    try:
        main()
    except (OrcaError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit("remote-harness: The native Codex project tools have stopped.")
