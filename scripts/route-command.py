#!/usr/bin/env python3
"""Rewrite a Bash tool call to the remote-harness project-host runner.

It runs before every Bash and Agent call, so it imports only what it uses (no argparse or typing).
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

# Claude modes in which an allow rule approves a call with no prompt and no classifier. Auto mode
# first drops broad allow rules, which only Claude itself can judge, so its classifier decides there.
RULE_ALLOW_MODES = ("default", "acceptEdits", "dontAsk")
MANAGED_SETTINGS = "/etc/claude-code"
# Besides letters and digits, a command made only of these is one simple command: no expansion,
# operator, redirection, glob or comment, so its words are exactly what shlex.split returns.
PLAIN_PUNCTUATION = frozenset(" -_./:=,@%+'\"")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}


def decision(kind: str, **values: object) -> dict[str, object]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": kind,
            **values,
        }
    }


def deny(category: str) -> dict[str, object]:
    # Exceptions may contain session/config paths. Detailed policy guidance lives in the injected
    # instructions; a failed hook returns only its category, status and unavailable correlation ID.
    return decision("deny", permissionDecisionReason=f"remote-harness: category={category} exit=2 session=unknown")


def command_policy(command: str) -> tuple[bool, list[list[str]]]:
    """Whether the command launches an agent, and the words of each simple command in it.

    The project host has no required Python runtime. Its portable lexical check is also used here,
    so quoting and here-documents receive the same policy on both sides of the tunnel.
    """
    checker = os.path.join(os.path.dirname(os.path.realpath(__file__)), "run-on-project-host.sh")
    result = subprocess.run(["sh", checker, "--check-command", "--words"], input=command,
                            text=True, capture_output=True, timeout=10)
    if result.returncode not in (0, 1):
        raise ValueError("incomplete shell quoting or here-document, or unavailable command policy")
    commands = [[unescape(word) for word in line.split("\t")]
                for line in result.stdout.split("\n") if line]
    return result.returncode == 1, commands


def unescape(word: str) -> str:
    if "\\" not in word:
        return word
    return re.sub(r"\\(.)", lambda match: ESCAPES.get(match.group(1), match.group(1)), word, flags=re.S)


def settings_paths(mount_root: str) -> tuple[list[str], list[str]]:
    """Claude's managed settings files, then the user and project ones, in the places Claude reads."""
    managed = [os.path.join(MANAGED_SETTINGS, "managed-settings.json")]
    drop_ins = os.path.join(MANAGED_SETTINGS, "managed-settings.d")
    try:
        managed += [os.path.join(drop_ins, name) for name in sorted(os.listdir(drop_ins))
                    if name.endswith(".json") and not name.startswith(".")]
    except OSError:
        pass
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    project = os.environ.get("CLAUDE_PROJECT_DIR") or mount_root
    return managed, [os.path.join(config_dir, "settings.json"),
                     os.path.join(project, ".claude", "settings.json"),
                     os.path.join(project, ".claude", "settings.local.json")]


def cached_rules(cache_path: str, paths: list[str], load):  # type: ignore[no-untyped-def]
    """`load()`, cached in the session directory by the identity of every file it reads.

    Project rules live on the SSHFS mount, where stat answers from the attribute cache but every
    open is a round trip to the laptop, so unchanged files are not read again.
    """
    identity: list[list[object]] = []
    for path in paths:
        try:
            info = os.stat(path)
            identity.append([path, info.st_ino, info.st_size, info.st_mtime_ns])
        except OSError:
            identity.append([path])
    try:
        with open(cache_path, encoding="utf-8") as handle:
            cached = json.load(handle)
        if cached["identity"] == identity:
            return cached["rules"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    rules = load()
    try:
        temporary = f"{cache_path}.{os.getpid()}"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump({"identity": identity, "rules": rules}, handle)
        os.replace(temporary, cache_path)
    except OSError:
        pass
    return rules


def claude_rules(cache_path: str, mount_root: str) -> dict[str, list[str]]:
    """The user's Claude `Bash` permission rules, per behavior."""
    managed, others = settings_paths(mount_root)
    return cached_rules(cache_path, managed + others, lambda: load_claude_rules(managed, others))


def load_claude_rules(managed: list[str], others: list[str]) -> dict[str, list[str]]:
    rules: dict[str, list[str]] = {"allow": [], "ask": [], "deny": []}
    managed_only = False
    for path in managed + others:
        try:
            with open(path, encoding="utf-8") as handle:
                settings = json.load(handle)
            permissions = settings.get("permissions") or {}
            if path in managed and settings.get("allowManagedPermissionRulesOnly") is True:
                managed_only = True
            for behavior, found in rules.items():
                # Under managed-only rules Claude ignores the others; keeping their deny rules is stricter.
                entries = permissions.get(behavior)
                if (managed_only and path not in managed and behavior != "deny") or not isinstance(entries, list):
                    continue
                found.extend(entry for entry in entries if isinstance(entry, str) and (
                    entry == "Bash" or entry.startswith("Bash(") and entry.endswith(")")))
        except (OSError, ValueError, AttributeError):
            continue
    return rules


def rule_pattern(rule: str) -> re.Pattern[str]:
    """A Claude `Bash` rule as a regular expression over a command's words joined by spaces."""
    content = rule[5:-1] if rule.startswith("Bash(") else "*"
    try:
        text = " ".join(shlex.split(content))
    except ValueError:
        text = " ".join(content.split())
    if text in ("", "*"):
        return re.compile(r"(?s).*")
    tail = ""
    if text.endswith(":*") or text.endswith(" *"):
        # `npm test:*` and `npm test *` both match `npm test` and `npm test ...`, not `npm testing`.
        text, tail = text[:-2].rstrip(), "(?: .*)?"
    return re.compile("(?s)" + ".*".join(re.escape(part) for part in text.split("*")) + tail)


def matching_rule(rules: list[str], commands: list[list[str]], basenames: bool) -> str | None:
    for rule in rules:
        pattern = rule_pattern(rule)
        for words in commands:
            candidates = [words]
            if basenames and words and "/" in words[0]:
                candidates.append([words[0].rsplit("/", 1)[1], *words[1:]])
            if any(pattern.fullmatch(" ".join(candidate)) for candidate in candidates):
                return rule
    return None


def plain_words(command: str) -> list[str] | None:
    """The words of a command that is one plain simple command, else None.

    Allow rules are applied here only to such commands: anything else (pipes, substitutions,
    redirections, globs, variables) waits for Claude's own judgment, as its parser would split it.
    """
    if not all(character.isalnum() or character in PLAIN_PUNCTUATION for character in command):
        return None
    try:
        return shlex.split(command) or None
    except ValueError:
        return None


def claude_decision(event: dict[str, object], command: str, commands: list[list[str]],
                    cache_path: str, mount_root: str, updated_input: dict[str, object]) -> dict[str, object]:
    """Apply the user's `Bash(...)` rules to the original command; Claude itself sees only rh-run.

    Deny rules, then ask rules, match any simple command in it (wrappers such as sudo and env
    skipped, a path's basename too). Allow rules match only a plain simple command, in modes where
    Claude would let them approve without a prompt. Otherwise Claude judges the call as usual.
    """
    rules = claude_rules(cache_path, mount_root)
    rule = matching_rule(rules["deny"], commands, basenames=True)
    if rule:
        return decision("deny", permissionDecisionReason=f"remote-harness: the permission rule {rule} denies this command")
    rule = matching_rule(rules["ask"], commands, basenames=True)
    if rule:
        return decision("ask", permissionDecisionReason=f"remote-harness: the permission rule {rule} asks first",
                        updatedInput=updated_input)
    words = plain_words(command) if event.get("permission_mode") in RULE_ALLOW_MODES and rules["allow"] else None
    rule = matching_rule(rules["allow"], [words], basenames=False) if words else None
    if rule:
        return decision("allow", permissionDecisionReason=f"remote-harness: allowed by the permission rule {rule}",
                        updatedInput=updated_input)
    # A hook "allow" would skip Claude's approval prompt and auto-mode classifier. Without a
    # decision Claude judges the rewritten call under the user's own approval mode.
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": updated_input}}


def route(runner_arg: str, mount_root_arg: str, agent: str) -> dict[str, object]:
    try:
        event = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError):
        return deny("input")

    tool_name = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return deny("input")
    if tool_name == "Agent":
        if tool_input.get("isolation") == "worktree":
            return deny("worktree")
        return {}
    if tool_name != "Bash":
        return deny("input")

    command = tool_input.get("command")
    if not isinstance(command, str) or not command.strip():
        return deny("input")
    try:
        launches_agent, commands = command_policy(command)
    except ValueError:
        return deny("command_parse")
    if launches_agent:
        return deny("local_agent")

    runner = os.path.realpath(os.path.expanduser(runner_arg))
    if not os.path.isfile(runner) or not os.access(runner, os.X_OK):
        return deny("runner")

    mount_root = os.path.realpath(os.path.expanduser(mount_root_arg))
    requested_cwd = tool_input.get("workdir") or event.get("cwd")
    if not isinstance(requested_cwd, str) or not requested_cwd:
        return deny("input")
    cwd = os.path.realpath(os.path.expanduser(requested_cwd))
    try:
        inside_mount = os.path.commonpath([mount_root, cwd]) == mount_root
    except ValueError:
        inside_mount = False
    if not inside_mount:
        return deny("outside_mount")

    relative_cwd = os.path.relpath(cwd, mount_root)
    updated_input = dict(tool_input)
    runner_args = [runner]
    if tool_input.get("run_in_background") is True:
        runner_args.append("--background")
    # The agent's approval prompt and automatic review read this text, so it carries the original
    # command readably.
    runner_args.extend(("--cwd", relative_cwd, "--", command))
    updated_input["command"] = " ".join(shlex.quote(part) for part in runner_args)
    if agent == "claude":
        # The runner sits in the session's private bin directory; the rule cache goes beside it.
        cache = os.path.join(os.path.dirname(os.path.dirname(runner)), "claude-rules.json")
        return claude_decision(event, command, commands, cache, mount_root, updated_input)
    # Codex judges the original itself: its exec policy rules, its forced-rm check and its approval
    # all read the commands after `exit`, which the shell never reaches. After the newline the shell
    # does not even parse them, so syntax only the project host's shell accepts cannot stop the
    # runner. Codex takes updatedInput only with "allow", which keeps its own approval in place.
    updated_input["command"] += "; exit\n" + command
    return decision("allow", updatedInput=updated_input)


def parse_args(argv: list[str]) -> dict[str, str]:
    """The fixed `--runner PATH --mount-root PATH [--agent claude|codex]` that inject-rule.sh writes."""
    if len(argv) % 2:
        raise ValueError("options need values")
    values = dict(zip(argv[::2], argv[1::2]))
    if len(values) * 2 != len(argv):
        raise ValueError("an option repeats")
    values.setdefault("--agent", "codex")
    if sorted(values) != ["--agent", "--mount-root", "--runner"] or values["--agent"] not in ("claude", "codex"):
        raise ValueError("expected --runner PATH --mount-root PATH [--agent claude|codex]")
    return values


def main() -> int:
    try:
        args = parse_args(sys.argv[1:])
        result = route(args["--runner"], args["--mount-root"], args["--agent"])
    except Exception:  # Keep hook execution fail-closed after Python starts.
        result = deny("framework")
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
