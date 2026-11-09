"""A loopback Responses endpoint for real app-server tests."""
import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler
from itertools import count


CHILD_PATH = "/root/fixture_child"


class Model(BaseHTTPRequestHandler):
    response_ids = count(1)

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "zstd":
            body = subprocess.run(["zstd", "-dc"], input=body, check=True,
                                  capture_output=True).stdout
        request = json.loads(body)
        self.server.requests.append(request)
        number = next(self.response_ids)
        messages = request.get("input", [])
        incoming = json.dumps([item.get("content") for item in messages
                               if item.get("type") == "agent_message"
                               and item.get("recipient") == CHILD_PATH])
        child = "RH_CHILD_CALL" in incoming
        root_prompt = any(item.get("role") == "user"
                          and "RH_START_CHILD" in json.dumps(item.get("content"))
                          for item in messages)
        # Responses Lite includes tools in input items rather than a top-level tools array.
        specs = list(request.get("tools", []))
        for item in messages:
            if item.get("type") == "additional_tools":
                specs.extend(item["tools"])
        tools = {}
        for tool in specs:
            if tool.get("type") == "namespace":
                tools.update({(tool["name"], function["name"]): function for function in tool["tools"]})
            elif tool.get("name"):
                tools["", tool["name"]] = tool
        names = tools.keys()
        self.server.tool_names[child].update(names)
        outputs = [item for item in messages
                   if item.get("type") in ("function_call_output", "custom_tool_call_output")]
        result = {item["call_id"].split("_", 1)[0]: item["output"] for item in outputs}
        blocked = self.server.blocked_outputs
        for output in outputs:
            for prefix in ("shell_", "code_", "patch_"):
                if str(output.get("call_id", "")).startswith(prefix):
                    blocked[prefix] = json.dumps(output["output"])
        child_output = "child" in result
        main_output = "main" in result
        item = None
        if child and "RH_CHILD_INTERRUPT" in incoming and "interruptcommand" not in result:
            item = self.function("interruptcommand", number, "mcp__remote_harness", "run", {
                "command": "printf interrupted > interrupted-marker", "cwd": "sub",
            })
        elif child and "RH_CHILD_FOLLOWUP" in incoming and "followupcommand" not in result:
            item = self.function("followupcommand", number, "mcp__remote_harness", "run", {
                "command": "printf followup-approved > followup-marker", "cwd": "sub",
            })
        elif child and not child_output and ("mcp__remote_harness", "run") in names:
            item = self.function("child", number, "mcp__remote_harness", "run", {
                "command": "printf child-approved > subagent-marker", "cwd": "sub",
            })
        elif child and child_output and "shell_" not in blocked:
            item = self.function("shell", number, "functions", "exec_command", {
                "cmd": "printf wrong > unguarded-shell", "workdir": self.server.mount,
            })
        elif child and child_output and "code_" not in blocked:
            item = {"type": "custom_tool_call", "id": f"ct_fixture_{number}",
                    "call_id": f"code_{number}", "namespace": "functions", "name": "exec",
                    "input": 'console.log("unguarded code mode")'}
        elif child and child_output and "patch_" not in blocked and ("functions", "apply_patch") in names:
            item = {"type": "custom_tool_call", "id": f"ct_fixture_{number}",
                    "call_id": f"patch_{number}", "namespace": "functions", "name": "apply_patch",
                    "input": "*** Begin Patch\n*** Add File: native-patch-marker\n"
                             "+mounted file change\n*** End Patch"}
        elif root_prompt and not child and not main_output and (spawn := self.v2_spawn(tools)):
            item = self.function("main", number, spawn[0], spawn[1], {
                "task_name": "fixture_child",
                "message": "RH_CHILD_CALL Run the routed fixture command.",
                **getattr(self.server, "fork_arguments", {}),
            })
        elif root_prompt and not child and main_output and "wait" not in result:
            namespace = next(namespace for namespace, name in names if name == "wait_agent")
            item = self.function("wait", number, namespace, "wait_agent", {"timeout_ms": 10000})
        elif root_prompt and not child and getattr(self.server, "interrupt_approval", None):
            item = self.collaboration_item(number, tools, result)
        if item is None:
            item = {"id": f"msg_fixture_{number}", "type": "message", "role": "assistant",
                    "status": "completed", "content": [{"type": "output_text",
                    "text": "Fixture finished.", "annotations": []}]}
        response = {"id": f"resp_fixture_{number}", "object": "response",
                    "created_at": int(time.time()), "status": "completed",
                    "model": request["model"], "output": [item],
                    "usage": {"input_tokens": 100, "output_tokens": 20, "total_tokens": 120,
                              "input_tokens_details": {"cached_tokens": 0},
                              "output_tokens_details": {"reasoning_tokens": 0}}}
        events = [
            {"type": "response.created", "response": dict(response, status="in_progress", output=[])},
            {"type": "response.output_item.added", "output_index": 0, "item": item},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": response},
        ]
        payload = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def collaboration_item(self, number, tools, result):
        namespace, _ = self.v2_spawn(tools)
        stages = [
            ("send", "send_message", {"target": CHILD_PATH, "message": "RH_CHILD_QUEUED"}),
            ("followup", "followup_task", {"target": CHILD_PATH, "message": "RH_CHILD_FOLLOWUP"}),
            ("waitagain", "wait_agent", {"timeout_ms": 10000}),
            ("list", "list_agents", {}),
            ("interrupttask", "followup_task", {"target": CHILD_PATH, "message": "RH_CHILD_INTERRUPT"}),
            ("interrupt", "interrupt_agent", {"target": CHILD_PATH}),
        ]
        for prefix, name, args in stages:
            if prefix not in result:
                if prefix == "interrupt" and not self.server.interrupt_approval.wait(8):
                    return None
                return self.function(prefix, number, namespace, name, args)
        return None

    @staticmethod
    def v2_spawn(tools):
        return next((key for key, tool in tools.items()
                     if key[1] == "spawn_agent"
                     and set(tool["parameters"].get("required", ())) == {"task_name", "message"}),
                    None)

    @staticmethod
    def function(prefix, number, namespace, name, arguments):
        return {"id": f"fc_fixture_{number}", "type": "function_call",
                "call_id": f"{prefix}_{number}", "namespace": namespace,
                "name": name, "arguments": json.dumps(arguments), "status": "completed"}
