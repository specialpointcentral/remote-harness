#!/usr/bin/env -S python3 -EsB
"""Codex Command for Paseo and Orca, with a private app server for Harness chats."""
from __future__ import annotations

import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import threading

from native_workspace import CHAT_REQUIRED, protected
from orca_native import (CODEX_CHATS, LEASE, MOUNTS, SESSION_NAME, OrcaError, SessionEnded,
                         active_lease, describe_versions, live_session, private_dir, private_json,
                         require_orca_version, shown_version, unverified_warning, version_support,
                         write_once)

# codex-cli builds whose app-server protocol Harness has been verified against.
CODEX_VERSIONS = ("0.167.0",)
PASEO_LEASE = "paseo-lease.json"
PASEO_SESSION_ENV = "RH_CODEX_SESSION"
PASEO_TOKEN_ENV = "RH_CODEX_TOKEN"
MAX_FRAME = 128 * 1024 * 1024
ORCA_CHAT_REQUIRED = (
    "This Codex invocation is outside its registered Orca Harness chat. "
    "Open the existing Harness chat instead of using '+'. "
    "To open another chat, rerun the original Harness launch command on the project host."
)
MCP_ONLY_APPROVAL = {"granular": {
    "sandbox_approval": False,
    "rules": False,
    "mcp_elicitations": True,
    "request_permissions": False,
    "skill_approval": False,
}}
MODES = {
    "normal": (MCP_ONLY_APPROVAL, "user"),
    "auto": (MCP_ONLY_APPROVAL, "auto_review"),
    "yolo": ("never", "user"),
}
# Import the selected account's model/auth settings, without loading its tools, hooks, projects,
# role definitions, profiles or execution settings. App-server creates private history/database.
ACCOUNT_KEYS = {
    "model", "model_provider", "model_providers", "openai_base_url", "chatgpt_base_url",
    "model_reasoning_effort", "model_reasoning_summary", "model_verbosity", "service_tier",
    "model_context_window", "model_auto_compact_token_limit", "model_catalog_json",
    "cli_auth_credentials_store",
}
FEATURES = {
    "apps": False, "plugins": False, "hooks": False, "shell_tool": False, "unified_exec": False,
    "shell_snapshot": False, "shell_snapshot_v2": False,
    "code_mode": {"enabled": False, "direct_only_tool_namespaces": [
        "mcp__remote_harness", "collaboration",
    ]},
    "code_mode_host": {"enabled": False, "disable_in_process_fallback": True},
    "code_mode_only": False, "code_mode_only_strict_3p_tools": False, "deferred_executor": False,
    "subagent_thread_environments": False, "multi_agent": True,
    "multi_agent_v2": True,
    "tool_call_mcp_elicitation": True,
}
INSPECT = {
    "initialize", "initialized", "config/read", "configRequirements/read", "model/list",
    "modelProviderCapabilities/read", "skills/list", "hooks/list", "mcpServerStatus/list",
    "account/read", "account/rateLimits/read", "experimentalFeature/list", "collaborationMode/list",
    "thread/list", "thread/read", "thread/loaded/list", "thread/turns/list", "thread/turns/items/list",
    "thread/subscribe", "thread/unsubscribe", "thread/metadata/update", "thread/name/set",
}
TURN_ACTIONS = {
    "turn/steer", "turn/interrupt", "thread/compact/start", "thread/rollback",
    "thread/archive", "thread/unarchive", "thread/readState/update",
}


def real_command(home, wrapper):
    command = Path(private_json(home / "codex.json")["codex"])
    if (not command.is_absolute() or not command.is_file() or not os.access(command, os.X_OK)
            or command.resolve() == wrapper.resolve()):
        raise OrcaError("Set codex in the private Harness codex.json to the actual Codex executable.")
    return command.resolve()


def check_version(command, warn=False):
    output = subprocess.check_output([str(command), "--version"], stdin=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, timeout=8, text=True).strip()
    version = output[len("codex-cli "):] if output.startswith("codex-cli ") else None
    support = version_support(version, CODEX_VERSIONS)
    if support is None:
        raise OrcaError(f"Native Harness Codex requires codex-cli {describe_versions(CODEX_VERSIONS)} "
                        f"(this installation runs {shown_version(version)}).")
    if not support and warn:
        print(unverified_warning("codex-cli", version, CODEX_VERSIONS), file=sys.stderr, flush=True)


def orca_binding(home, cwd, env):
    identity = env.get("ORCA_AGENT_SESSION_ID", "")
    record = None
    if re.fullmatch(r"codex_[0-9a-f]{32}", identity):
        try:
            registry = private_dir(home / CODEX_CHATS)
            record = private_json(registry / (identity + ".json"))
        except FileNotFoundError:
            pass
    protected = home / MOUNTS
    if record is None:
        if cwd == protected or protected in cwd.parents:
            raise OrcaError(ORCA_CHAT_REQUIRED)
        return None
    if not env.get("ORCA_AGENT_SESSION_SPAWN_TOKEN") or record["cwd"] != str(cwd):
        raise OrcaError(ORCA_CHAT_REQUIRED)
    # A restarted Orca Server can resume this chat before the bridge has checked the new build.
    require_orca_version(env.get("ORCA_APP_VERSION"))
    if not SESSION_NAME.fullmatch(record["session"]):
        raise OrcaError("Invalid Orca Harness session registration.")
    # The chat's Codex conversation outlives the session, so a later launch can continue it.
    return home / ".sessions" / record["session"], LEASE, record["token"], registry / (identity + ".state")


def paseo_binding(home, env):
    directory = env.get(PASEO_SESSION_ENV)
    token = env.get(PASEO_TOKEN_ENV)
    if directory is None and token is None:
        return None
    path = Path(directory or "")
    sessions = home / ".sessions"
    if (not path.is_absolute() or path.parent.resolve() != sessions
            or not SESSION_NAME.fullmatch(path.name) or not token):
        raise OrcaError("Invalid Paseo Harness session registration.")
    return sessions / path.name, PASEO_LEASE, token, None


def toml(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, int) or isinstance(value, float) and math.isfinite(value):
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(map(toml, value)) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{toml(key)} = {toml(item)}" for key, item in value.items()) + " }"
    raise OrcaError("Unsupported value in Codex account config.")


def private_file(path, contents):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(contents)


def native_model_catalog(account, configured, target, command):
    if configured:
        with (account / configured).open("rb") as stream:
            catalog = json.load(stream)
    else:
        # --bundled dumps this binary's built-in metadata without contacting its model provider.
        env = {**os.environ, "CODEX_HOME": str(target)}
        catalog = json.loads(subprocess.check_output(
            [str(command), "debug", "models", "--bundled"], env=env,
            stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
        ))
    models = catalog["models"]
    if not isinstance(models, list) or not models or not all(isinstance(model, dict) for model in models):
        raise OrcaError("The configured Codex model catalog is invalid.")
    for model in models:
        # Codex resolves the model's tool mode before feature defaults. Force direct calls
        # so code-mode-only catalog entries cannot restore the JavaScript executor.
        model["tool_mode"] = "direct"
    return catalog


def selected_account(session, mount, lease, binding, policy, command):
    import tomllib

    account = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser().resolve()
    target = session / "codex-home"
    if target.exists():
        private_dir(target)
        if private_json(target / "harness-account.json") != {"account": str(account), "command": str(command)}:
            raise OrcaError("The Codex account changed. Start a new Harness chat.")
        return target
    source = account / "config.toml"
    try:
        with source.open("rb") as stream:
            original = tomllib.load(stream)
    except FileNotFoundError:
        original = {}
    config = {key: original[key] for key in ACCOUNT_KEYS if key in original}
    if config.get("cli_auth_credentials_store") not in (None, "auto", "file"):
        raise OrcaError("Native Harness Codex requires file-based or environment-based authentication.")
    catalog_source = config.pop("model_catalog_json", None)
    # Prevent project config from adding another command executor or plugin. The account's own
    # model provider and credentials still drive the private app server.
    config.update({
        "cli_auth_credentials_store": "file",
        "projects": {str(mount): {"trust_level": "untrusted"}},
        "features": FEATURES,
        "allow_login_shell": False,
        "approval_policy": policy["approvalPolicy"],
        "approvals_reviewer": policy["approvalsReviewer"],
        "sandbox_mode": "workspace-write",
        "sandbox_workspace_write": {
            "writable_roots": [], "network_access": False,
            "exclude_tmpdir_env_var": True, "exclude_slash_tmp": True,
        },
        "mcp_servers": {"remote_harness": {
            "command": lease["python"],
            "args": ["-EsB", str(session / "impl" / "codex-project-tools.py"),
                     str(binding[1]), binding[2]],
            "default_tools_approval_mode": "approve" if lease["approval"] == "yolo" else "prompt",
            "enabled_tools": ["run", "read_file", "write_file"],
            "tools": {"read_file": {"approval_mode": "approve"}},
            "startup_timeout_sec": 10,
            "tool_timeout_sec": 3600,
        }},
    })
    tmp = session / "codex-home.new"
    private_dir(tmp, create=True)
    for path in ("config.toml", "auth.json", "harness-account.json", "models.json"):
        (tmp / path).unlink(missing_ok=True)
    if state := binding[3]:
        # Codex writes the chat's conversation (its rollouts) to the chat's private state; the
        # credentials and settings stay in the session.
        conversation = private_dir(private_dir(state, create=True) / "sessions", create=True)
        if (tmp / "sessions").is_symlink():
            (tmp / "sessions").unlink()
        (tmp / "sessions").symlink_to(conversation, target_is_directory=True)
    catalog = native_model_catalog(account, catalog_source, tmp, command)
    private_file(tmp / "models.json", json.dumps(catalog).encode())
    config["model_catalog_json"] = str(target / "models.json")
    try:
        auth = private_json(account / "auth.json")
    except FileNotFoundError:
        # Custom model providers may use an env key, credential helper or anonymous API.
        # The built-in provider otherwise needs a file login or a supported account env.
        if config.get("model_provider", "openai") == "openai" and not any(
                os.environ.get(key) for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN")):
            raise OrcaError("Log in to Codex using file credentials or set the provider's API key.")
    else:
        private_file(tmp / "auth.json", json.dumps(auth).encode())
    private_file(tmp / "config.toml",
                 "".join(f"{toml(key)} = {toml(value)}\n" for key, value in config.items()).encode())
    write_once(tmp / "harness-account.json", {"account": str(account), "command": str(command)})
    tmp.rename(target)
    return target


def send(stream, obj):
    stream.write(json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode() + b"\n")
    stream.flush()


def frames(fd):
    pending = bytearray()
    while chunk := os.read(fd, 65536):
        pending.extend(chunk)
        while (end := pending.find(b"\n")) >= 0:
            if end > MAX_FRAME:
                raise OrcaError("Codex app-server frame exceeded the Harness limit.")
            frame = json.loads(pending[:end])
            del pending[:end + 1]
            if not isinstance(frame, dict):
                raise OrcaError("Invalid Codex app-server frame.")
            yield frame
        if len(pending) > MAX_FRAME:
            raise OrcaError("Codex app-server frame exceeded the Harness limit.")


class SessionProxy:
    """Keep manager and Codex on native JSON-RPC while pinning execution policy to the lease."""

    def __init__(self, session, lease_name, token, policy, mount, child, state=None):
        self.session, self.lease_name, self.token = session, lease_name, token
        self.policy, self.mount, self.child, self.state = policy, mount, child, state
        self.thread_file = session / "codex-thread.json"
        self.thread = private_json(self.thread_file)["thread"] if self.thread_file.exists() else None
        self.start_id = None
        self.approvals = {}
        self.out_lock = threading.Lock()
        self.in_lock = threading.Lock()
        self.done = threading.Event()
        self.rule = (session / "rule.md").read_text(encoding="utf8")

    def emit(self, frame):
        with self.out_lock:
            send(sys.stdout.buffer, frame)

    def dispatch(self, frame):
        with self.in_lock:
            send(self.child.stdin, frame)

    def check(self):
        active_lease(self.session / self.lease_name, self.token)

    def monitor(self):
        while not self.done.wait(0.5):
            try:
                self.check()
            except (OrcaError, OSError, ValueError, KeyError, subprocess.SubprocessError):
                self.done.set()
                break

    def from_codex(self):
        try:
            for frame in frames(self.child.stdout.fileno()):
                if self.start_id is not None and frame.get("id") == self.start_id and "method" not in frame:
                    if "result" in frame:
                        thread = frame["result"]["thread"]["id"]
                        if not isinstance(thread, str) or not thread:
                            raise OrcaError("Codex did not return a valid thread ID.")
                        write_once(self.thread_file, {"thread": thread})
                        if self.state:
                            write_once(self.state / "thread.json", {"thread": thread})
                        self.thread = thread
                    self.start_id = None
                method = frame.get("method")
                if method and "id" in frame:
                    if method == "mcpServer/elicitation/request":
                        params = frame["params"]
                        args = (params.get("_meta") or {}).get("tool_params")
                        if (params.get("serverName") != "remote_harness" or not isinstance(args, dict)):
                            self.reject_server_request(frame)
                            continue
                        if isinstance(command := args.get("command"), str):
                            params["message"] += f"\n\nProject directory: {args.get('cwd', '.')}\n{command}"
                        elif isinstance(path := args.get("path"), str):
                            params["message"] += f"\n\nProject file: {path}"
                    elif method != "item/tool/requestUserInput":
                        self.reject_server_request(frame)
                        continue
                    self.approvals[frame["id"]] = method
                self.emit(frame)
        except (OrcaError, OSError, ValueError, TypeError, KeyError):
            pass
        finally:
            self.done.set()

    def reject_server_request(self, frame):
        self.dispatch({"id": frame["id"], "error": {"code": -32601,
            "message": "This operation is unavailable in a Remote Harness Codex chat."}})

    def refuse(self, frame):
        if "id" in frame:
            self.emit({"id": frame["id"], "error": {"code": -32602,
                "message": "This operation is unavailable in a Remote Harness Codex chat."}})

    def from_manager(self, frame):
        method = frame.get("method")
        if method is None:
            kind = self.approvals.pop(frame.get("id"), None)
            if kind is None:
                return
            if kind == "mcpServer/elicitation/request":
                # Each approval is bound to exactly one command. Never store a broad MCP grant.
                result = frame.get("result")
                if isinstance(result, dict):
                    result["_meta"] = None
            self.dispatch(frame)
            return
        params = frame.get("params") or {}
        if not isinstance(params, dict):
            return self.refuse(frame)
        if method in ("thread/start", "thread/resume"):
            if method == "thread/start":
                if self.thread or self.start_id is not None or "id" not in frame:
                    return self.refuse(frame)
                self.start_id = frame["id"]
            elif not self.thread or params.get("threadId") != self.thread:
                return self.refuse(frame)
            # These providers send mutable policy and MCP settings at thread start, resume and
            # later turns. Keep model/UI fields, discard execution overrides and workspace changes.
            params = {key: params[key] for key in (
                "threadId", "model", "serviceTier", "personality", "excludeTurns"
            ) if key in params}
            params.update(self.policy, cwd=str(self.mount), sandbox="workspace-write",
                          developerInstructions=self.rule)
        elif method == "turn/start":
            if not self.thread or params.get("threadId") != self.thread:
                return self.refuse(frame)
            for key in ("config", "cwd", "sandboxPolicy", "disabledPluginIds", "toolOutput",
                        "approvalPolicy", "approvalsReviewer"):
                params.pop(key, None)
            params.update(self.policy, cwd=str(self.mount))
        elif method in TURN_ACTIONS:
            if not self.thread or params.get("threadId") != self.thread:
                return self.refuse(frame)
        elif method not in INSPECT:
            return self.refuse(frame)
        frame["params"] = params
        self.dispatch(frame)

    def from_client(self):
        try:
            for frame in frames(sys.stdin.fileno()):
                if self.done.is_set():
                    break
                self.check()
                self.from_manager(frame)
        except (OrcaError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
            pass
        finally:
            self.done.set()

    def run(self):
        threading.Thread(target=self.monitor, daemon=True).start()
        threading.Thread(target=self.from_client, daemon=True).start()
        outgoing = threading.Thread(target=self.from_codex, daemon=True)
        outgoing.start()
        try:
            self.done.wait()
        finally:
            self.done.set()
            stop_child(self.child)
            outgoing.join(timeout=1)


def stop_child(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can report EPERM for a process group with an exiting leader.
        child.kill()
    child.wait(timeout=5)


def serve(command, binding):
    session, lease_name, token, state = binding
    live_session(session)
    lease = active_lease(session / lease_name, token)
    check_version(command)
    mount = Path(lease["cwd"]).resolve(strict=True)
    env = os.environ.copy()
    env.update(lease["env"])
    from orca_native import session_presentation
    presentation = session_presentation(session, lease)
    for key in ("SSH_CONNECTION", "SSH_CLIENT", PASEO_SESSION_ENV, PASEO_TOKEN_ENV,
                "BASH_ENV", "ENV", "CODEX_SQLITE_HOME") + (("TZ", "TZDIR") if presentation.version else ()):
        if key not in lease["env"]:
            env.pop(key, None)
    presentation.environment(env)
    if Path(env["PATH"].split(os.pathsep)[0]).resolve() != session / "bin":
        raise OrcaError("Codex cannot start without the Harness PATH shims.")
    approval, reviewer = MODES[lease["approval"]]
    policy = {"approvalPolicy": approval, "approvalsReviewer": reviewer}
    fd = os.open(session / "codex-writer.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OrcaError("Invalid Codex writer lock.")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        env["CODEX_HOME"] = str(selected_account(session, mount, lease, binding, policy, command))
        thread_file = session / "codex-thread.json"
        if state and (state / "thread.json").exists() and not thread_file.exists():
            # A launch that continues the chat resumes its Codex thread.
            thread = private_json(state / "thread.json")["thread"]
            if not isinstance(thread, str) or not thread:
                raise OrcaError("Invalid Codex thread of the Orca chat to continue.")
            write_once(thread_file, {"thread": thread})
        # These session flags also override same-named project or machine defaults at load time.
        flags = [flag for key, value in FEATURES.items()
                 for flag in ("-c", f"features.{key}={toml(value)}")]
        flags += ["-c", f"projects.{toml(str(mount))}.trust_level=\"untrusted\""]
        active_lease(session / lease_name, token)
        child = subprocess.Popen([str(command), "app-server", "--listen", "stdio://", *flags],
                                 cwd=mount, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 start_new_session=True)
        try:
            proxy = SessionProxy(session, lease_name, token, policy, mount, child, state)
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, lambda signum, _: sys.exit(128 + signum))
            proxy.run()
        finally:
            if child.poll() is None:
                stop_child(child)


def main():
    wrapper = Path(os.path.abspath(__file__))
    home = wrapper.parent.parent.resolve()
    command = real_command(home, wrapper)
    args = sys.argv[1:]
    if args == ["check-harness-version"]:
        if sys.version_info < (3, 11):
            raise OrcaError("Native Harness Codex requires Python 3.11 or newer.")
        check_version(command, warn=True)
        return
    if args in (["--version"], ["-V"], ["--help"], ["-h"]):
        os.execv(command, [str(command), *args])
    binding = paseo_binding(home, os.environ) or orca_binding(home, Path.cwd(), os.environ)
    if binding is None:
        if protected(home, Path.cwd()):
            raise OrcaError(CHAT_REQUIRED)
        os.execv(command, [str(command), *args])
    if args not in (["app-server"], ["app-server", "--enable", "goals"]):
        raise OrcaError("The native Harness Codex command requires an unmodified app-server stdio launch.")
    try:
        if sys.version_info < (3, 11):
            session, lease_name, token, _ = binding
            live_session(session)
            python = active_lease(session / lease_name, token)["python"]
            subprocess.run([python, "-EsB", "-c", "import tomllib"], check=True,
                           stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            os.execv(python, [python, "-EsB", str(wrapper), *args])
        serve(command, binding)
    except SessionEnded as error:
        hint = ("To continue this chat, start a new Orca Harness launch for the project and choose "
                "the chat when the launcher offers it." if binding[3] else "Start a new Harness chat.")
        raise OrcaError(f"{error} {hint}") from error


if __name__ == "__main__":
    try:
        main()
    except OrcaError as error:
        print("remote-harness:", error, file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        sys.exit("remote-harness: Native Codex launch or lease check failed. Start a new Harness chat.")
