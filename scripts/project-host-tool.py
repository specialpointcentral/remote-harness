#!/usr/bin/env python3
"""Session PATH shim that runs IO-heavy git/rg calls on the project host.

The agent host sees the project through SSHFS, where every lstat, readdir, and file read crosses the
reverse tunnel. Work-tree scans (`git status`, `git diff`, `rg`) and read-only repository discovery
(`git rev-parse`, `git config --get`, ...) are therefore routed to the project host through the
forced gateway's `remote-harness-tool` verb. Absolute project-host paths in discovery output are
mapped back to the mount, so the project root and memory paths seen by the agent never change. git
calls that write keep running on the agent host.

Calls outside the mount run the real tool unchanged. A routed call that cannot reach the project host
fails with a non-zero status; it never falls back to a silent success, a clean status, or "no match".
"""

from __future__ import annotations

import os
import sys

# Every agent-internal git/rg call starts this shim. Modules only a routed call needs are imported once
# the call is known to route, so one that stays on the agent host does not pay ~14 ms for them.
def load_routing_modules() -> None:
    global base64, fcntl, random, re, signal, subprocess, threading, time
    import base64
    import fcntl
    import random
    import re
    import signal
    import subprocess
    import threading
    import time

TRANSPORT_FAILURE = 255

GIT_ROUTED_SUBCOMMANDS = {
    "blame",
    "diff",
    "diff-files",
    "diff-index",
    "diff-tree",
    "grep",
    "log",
    "ls-files",
    "ls-tree",
    "rev-list",
    "shortlog",
    "show",
    "status",
    "whatchanged",
}
# Read-only repository discovery. Over SSHFS each of these reads a dozen .git files one round trip
# at a time (5-20 s per call on a slow link), and agents run several before their first prompt, so
# they run on the project host too; absolute project-host paths in their output are mapped back to
# the mount. Commands whose arguments make them write stay on the agent host.
GIT_DISCOVERY_SUBCOMMANDS = {
    "branch",
    "cat-file",
    "config",
    "count-objects",
    "describe",
    "for-each-ref",
    "merge-base",
    "name-rev",
    "remote",
    "rev-parse",
    "show-ref",
    "symbolic-ref",
    "var",
    "worktree",
}
GIT_CONFIG_READS = {"-l", "--list", "--get-color", "--get-colorbool"}  # plus --get*, and get/list verbs
GIT_BRANCH_WRITES = {"-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-f",
                     "--force", "-u", "--set-upstream-to", "--unset-upstream", "--edit-description",
                     "--track", "--no-track", "-t", "--create-reflog"}


def git_discovery_reads(subcommand: str, rest: list[str]) -> bool:
    """True when a discovery subcommand only reads the repository."""
    positional = [arg for arg in rest if not arg.startswith("-")]
    if subcommand == "config":
        if rest[:1] in (["get"], ["list"]):
            return True
        return any(arg in GIT_CONFIG_READS or arg.startswith("--get") for arg in rest)
    if subcommand == "branch":
        if any(arg in GIT_BRANCH_WRITES or arg.startswith("--set-upstream-to=") for arg in rest):
            return False
        return not positional or "-l" in rest or "--list" in rest
    if subcommand == "symbolic-ref":
        return len(positional) <= 1 and not {"-d", "--delete"} & set(rest)
    if subcommand == "remote":
        return not rest or rest[0] in ("-v", "--verbose", "get-url")
    if subcommand == "worktree":
        return rest[:1] == ["list"]
    return True


GIT_PASSTHROUGH_GLOBALS = {
    "--glob-pathspecs",
    "--icase-pathspecs",
    "--literal-pathspecs",
    "--no-advice",
    "--no-lazy-fetch",
    "--no-optional-locks",
    "--no-pager",
    "--no-replace-objects",
    "--noglob-pathspecs",
    "--paginate",
    "-P",
    "-p",
}
# These change which repository, index, or object store git uses; the project host cannot see the
# agent-host paths they name, so such calls stay local.
GIT_LOCAL_ENV = (
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
)
GIT_PATHSPEC_ENV = {
    "GIT_GLOB_PATHSPECS": "--glob-pathspecs",
    "GIT_ICASE_PATHSPECS": "--icase-pathspecs",
    "GIT_LITERAL_PATHSPECS": "--literal-pathspecs",
    "GIT_NOGLOB_PATHSPECS": "--noglob-pathspecs",
    "GIT_NO_REPLACE_OBJECTS": "--no-replace-objects",
}
GIT_LOCAL_ARGS = ("--batch", "--open-files-in-pager", "--output", "--pathspec-from-file", "--stdin")
# Process-level settings for git that still runs on the SSHFS mount: compare whole-second mtime and
# size instead of inode/device/ctime/nanoseconds, which never match an index written on the project
# host and would otherwise force a content re-read of every tracked file.
GIT_SSHFS_CONFIG = ["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"]

current_proc: subprocess.Popen | None = None
current_claim = None  # a warm channel in use (warm_pool.Claim)


class StayLocal(Exception):
    """The call must run with the agent host's real tool."""


class ToolMissing(Exception):
    """The project host answered that the tool is not installed there."""


class Context:
    def __init__(self, args: Args) -> None:
        self.args = args
        self.mount_real = os.path.realpath(args.mount_root)
        variants = {self.mount_real, os.path.normpath(os.path.abspath(args.mount_root))}
        self.mounts = sorted(variants, key=len, reverse=True)
        self.root = args.project_root.rstrip("/") or "/"
        self.used_mount = self.mount_real
        self.touches_mount = False
        self.rewrite_output = False  # discovery output names project-host paths
        self.rg_json = False

    def inside(self, path: str) -> bool:
        real = os.path.realpath(path)
        try:
            return os.path.commonpath([self.mount_real, real]) == self.mount_real
        except ValueError:
            return False

    def mount_prefix(self, path: str) -> str | None:
        for mount in self.mounts:
            if path == mount or path.startswith(mount.rstrip("/") + "/"):
                return mount
        return None

    def translate_path(self, value: str, cwd: str) -> str:
        """Map an agent-host path argument to the project host, or raise StayLocal."""
        if value.startswith("/"):
            if ".." in value.split("/"):
                # `<mount>/../x` is not in the mount; mapped verbatim it would name `<root>/../x`.
                normalized = os.path.normpath(value)
                value = normalized + "/" if value.endswith("/") and normalized != "/" else normalized
            mount = self.mount_prefix(value)
            if mount is not None:
                self.used_mount = mount
                self.touches_mount = True
                return self.root + value[len(mount):]
            # An absolute path that exists outside the mount names agent-host data. Anything else is
            # a pattern or a path that would not exist on the agent host either; pass it through.
            if os.path.lexists(value):
                raise StayLocal()
            return value
        if value == ".." or value.startswith("../"):
            target = os.path.normpath(os.path.join(cwd, value))
            if os.path.lexists(target) and not self.inside(target):
                raise StayLocal()
        return value

    def translate_arg(self, arg: str, cwd: str) -> str:
        if arg.startswith("/") or arg == ".." or arg.startswith("../"):
            return self.translate_path(arg, cwd)
        if arg.startswith("-") and "=" in arg:
            name, value = arg.split("=", 1)
            if value.startswith("/") or value == ".." or value.startswith("../"):
                return name + "=" + self.translate_path(value, cwd)
        return arg


def encode_args(argv: list[str]) -> str:
    if not argv:
        return "-"
    return ",".join(
        base64.b64encode(b"x" + os.fsencode(arg)).decode("ascii") for arg in argv
    )


def git_plan(ctx: Context, argv: list[str], cwd: str) -> tuple[str, list[str]]:
    for name in GIT_LOCAL_ENV:
        if os.environ.get(name):
            raise StayLocal()
    routed: list[str] = []
    # Claude Code hardens every internal git call with GIT_CONFIG_PARAMETERS (git's own sq-quoted
    # `-c` list). Forward those entries as `-c` instead of staying local: a local `git status` at
    # session start would otherwise scan the whole work tree over SSHFS and stall the agent.
    params = os.environ.get("GIT_CONFIG_PARAMETERS", "")
    if params.strip():
        import shlex  # here: only calls that carry config entries need it

        try:
            entries = shlex.split(params)
        except ValueError:
            raise StayLocal()
        for entry in entries:
            if not entry or entry.startswith("="):
                raise StayLocal()
            routed += ["-c", ctx.translate_arg(entry, cwd)]
    try:
        count = int(os.environ.get("GIT_CONFIG_COUNT", "0") or "0")
    except ValueError:
        raise StayLocal()
    for index in range(count):
        key = os.environ.get(f"GIT_CONFIG_KEY_{index}")
        if not key:
            raise StayLocal()
        value = os.environ.get(f"GIT_CONFIG_VALUE_{index}", "")
        routed += ["-c", ctx.translate_arg(f"{key}={value}", cwd)]
    for name, flag in GIT_PATHSPEC_ENV.items():
        if os.environ.get(name) not in (None, "", "0", "false"):
            routed.append(flag)

    effective = cwd
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "-C" or (arg.startswith("-C") and len(arg) > 2):
            if arg == "-C":
                if i + 1 >= len(argv):
                    raise StayLocal()
                value = argv[i + 1]
                i += 2
            else:
                value = arg[2:]
                i += 1
            if value:
                effective = os.path.join(effective, value)
            continue
        if arg == "-c":
            if i + 1 >= len(argv):
                raise StayLocal()
            routed += ["-c", ctx.translate_arg(argv[i + 1], effective)]
            i += 2
            continue
        if arg in GIT_PASSTHROUGH_GLOBALS:
            routed.append(arg)
            i += 1
            continue
        if arg.startswith("-"):
            raise StayLocal()
        break
    subcommand = argv[i] if i < len(argv) else ""
    rest = argv[i + 1:]
    discovery = subcommand in GIT_DISCOVERY_SUBCOMMANDS and git_discovery_reads(subcommand, rest)
    if subcommand not in GIT_ROUTED_SUBCOMMANDS and not discovery:
        if ctx.inside(effective):
            ctx.touches_mount = True
        raise StayLocal()
    if not ctx.inside(effective):
        raise StayLocal()
    ctx.touches_mount = True
    ctx.rewrite_output = discovery
    ctx.used_mount = ctx.mount_prefix(os.path.abspath(effective)) or ctx.mount_real
    for arg in rest:
        if arg.startswith(GIT_LOCAL_ARGS) or arg == "--no-index":
            raise StayLocal()
        if subcommand == "grep" and arg == "-O":
            raise StayLocal()
    routed.append(subcommand)
    routed += [ctx.translate_arg(arg, effective) for arg in rest]
    return effective, routed


def rg_config_args() -> list[str]:
    path = os.environ.get("RIPGREP_CONFIG_PATH")
    if not path:
        return []
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as handle:
            lines = [line.rstrip("\r\n") for line in handle]
    except OSError:
        return []
    return [line for line in lines if line.strip() and not line.lstrip().startswith("#")]


def rg_plan(ctx: Context, argv: list[str], cwd: str) -> tuple[str, list[str]]:
    if not ctx.inside(cwd):
        raise StayLocal()
    ctx.touches_mount = True
    args = argv if "--no-config" in argv else rg_config_args() + argv
    # The option roles come from rg 15's --help (including its documented aliases). Unknown
    # options stay local: guessing whether their following argument is a pattern or a path can
    # silently change a search. This is a planning decision, never a transport-error fallback.
    values = set("""regexp file pre pre-glob dfa-size-limit encoding engine max-count
        regex-size-limit threads glob iglob ignore-file max-depth maxdepth max-filesize type
        type-not type-add type-clear after-context before-context color colors context
        context-separator field-context-separator field-match-separator hostname-bin
        hyperlink-format max-columns path-separator replace sort sortr generate""".split())
    flags = set("""search-zip case-sensitive crlf fixed-strings ignore-case invert-match
        line-regexp mmap multiline multiline-dotall no-unicode null-data pcre2 smart-case
        stop-on-nonmatch text word-regexp auto-hybrid-regex no-pcre2-unicode binary follow
        glob-case-insensitive hidden ignore-file-case-insensitive no-ignore no-ignore-dot
        no-ignore-exclude no-ignore-files no-ignore-global no-ignore-parent no-ignore-vcs
        no-require-git one-file-system unrestricted block-buffered byte-offset column heading
        help include-zero line-buffered line-number no-line-number max-columns-preview null
        only-matching passthru passthrough pretty quiet trim vimgrep with-filename no-filename
        sort-files count count-matches files-with-matches files-without-match json debug
        no-ignore-messages no-messages stats trace files no-config pcre2-version type-list
        version print0""".split())
    flags |= {"no-" + flag for flag in flags if not flag.startswith("no-")}
    flags |= {"ignore", "ignore-dot", "ignore-exclude", "ignore-files", "ignore-global",
              "ignore-parent", "ignore-vcs", "require-git", "unicode", "pcre2-unicode",
              "ignore-messages", "messages", "no-encoding", "no-pre", "no-context-separator"}
    short_values = dict(zip("efEmjgdtTABC Mr".replace(" ", ""),
                            "regexp file encoding max-count threads glob max-depth type type-not "
                            "after-context before-context context max-columns replace".split()))
    short_flags = dict(zip("zsFivxUPSawL.u bhnN0opqHIclV".replace(" ", ""),
                           "search-zip case-sensitive fixed-strings ignore-case invert-match "
                           "line-regexp multiline pcre2 smart-case text word-regexp follow hidden "
                           "unrestricted byte-offset help line-number no-line-number null "
                           "only-matching pretty quiet with-filename no-filename count "
                           "files-with-matches version".split()))
    routed = list(args)
    paths: list[int] = []
    explicit_pattern = False
    mode = "search"
    options = True

    def option(name: str, index: int, prefix: str = "") -> None:
        nonlocal explicit_pattern, mode
        if name in ("regexp", "file"):
            explicit_pattern = True
        if name in ("file", "ignore-file"):
            value = routed[index][len(prefix):]
            if value == "-":
                raise StayLocal()  # pattern files on stdin need agent-side stdin
            routed[index] = prefix + ctx.translate_path(value, cwd)
        # Programs named by these options can depend on agent-host executables or credentials.
        if name in ("pre", "hostname-bin"):
            raise StayLocal()
        if name in ("files", "type-list", "files-with-matches", "files-without-match",
                    "count", "count-matches"):
            mode = name
        if name in ("json", "no-json"):
            ctx.rg_json = name == "json"

    i = 0
    while i < len(args):
        arg = args[i]
        if options and arg == "--":
            options = False
        elif options and arg.startswith("--"):
            name, equals, _value = arg[2:].partition("=")
            if name in values:
                if equals:
                    option(name, i, "--" + name + "=")
                else:
                    i += 1
                    if i >= len(args):
                        raise StayLocal()
                    option(name, i)
            elif name in flags and not equals:
                option(name, i)
            else:
                raise StayLocal()
        elif options and arg.startswith("-") and arg != "-":
            j = 1
            while j < len(arg):
                char = arg[j]
                if char in short_values:
                    if j + 1 < len(arg):
                        option(short_values[char], i, arg[:j + 1])
                    else:
                        i += 1
                        if i >= len(args):
                            raise StayLocal()
                        option(short_values[char], i)
                    break
                if char not in short_flags:
                    raise StayLocal()
                option(short_flags[char], i)
                j += 1
        else:
            paths.append(i)
        i += 1
    # -e/-f can occur after a positional: then *all* positionals name search paths.
    if not explicit_pattern and mode not in ("files", "type-list") and paths:
        paths.pop(0)
    for index in paths:
        if args[index] == "-":
            raise StayLocal()
        routed[index] = ctx.translate_path(args[index], cwd)
    return cwd, routed


class OutputRewriter:
    """Map rg filename prefixes or paths in small git discovery records.

    rg text retains only an undecided root prefix, so even huge matches stream immediately.
    JSON is decoded one whole record at a time and changes only data.path; git discovery uses
    newline/NUL records. Those two record formats may use memory proportional to a record.
    """

    def __init__(self, old: str, new: str, json_mode: bool, anywhere: bool = False) -> None:
        self.enabled = old != new
        self.old = os.fsencode(old)
        self.new = os.fsencode(new)
        self.json_mode = json_mode
        self.anywhere = re.compile(
            rb"(?<![^\s\x00:=])" + re.escape(self.old) + rb"(?=$|[/\s\x00:])"
        ) if anywhere else None
        self.pending = b""
        self.leading = True
        self.record = bytearray()

    def _text(self, chunk: bytes, final: bool = False):
        # Only an undecided filename prefix is retained. Content-only output beginning with the
        # project root is ambiguous and receives the same prefix mapping as filename output.
        for part in re.split(rb"([\n\0])", chunk):
            if part in (b"\n", b"\0"):
                if self.pending:
                    yield self._leading(self.pending, True)
                    self.pending = b""
                yield part
                self.leading = True
            elif part:
                if not self.leading:
                    yield part
                    continue
                data = self.pending + part
                if len(data) <= len(self.old) and self.old.startswith(data):
                    self.pending = data
                else:
                    self.pending = b""
                    self.leading = False
                    yield self._leading(data, False)
        if final and self.pending:
            yield self._leading(self.pending, True)
            self.pending = b""

    def _leading(self, data: bytes, final: bool) -> bytes:
        if data.startswith(self.old) and (data[len(self.old):len(self.old) + 1] in
                                          (b"/", b":") or (final and data == self.old)):
            return self.new + data[len(self.old):]
        return data

    def _json_record(self, data: bytes) -> bytes:
        import json

        try:
            value = json.loads(data)
            path = value["data"]["path"]
            # rg's text/bytes alternatives are exclusive; other shapes pass through unchanged.
            if not isinstance(path, dict) or len(path) != 1:
                return data
            kind = next(iter(path))
            if kind not in ("text", "bytes") or not isinstance(path[kind], str):
                return data
            original = (path[kind].encode("utf-8") if kind == "text" else
                        base64.b64decode(path[kind], validate=True))
            if original != self.old and not original.startswith(self.old + b"/"):
                return data
            mapped = self.new + original[len(self.old):]
            path[kind] = (mapped.decode("utf-8") if kind == "text" else
                          base64.b64encode(mapped).decode("ascii"))
            return json.dumps(value).encode("utf-8") + (b"\n" if data.endswith(b"\n") else b"")
        except (ValueError, UnicodeError, TypeError, KeyError, IndexError, RecursionError):
            return data

    def _record(self, data: bytes) -> bytes:
        if self.json_mode:
            return self._json_record(data)
        assert self.anywhere is not None
        return self.anywhere.sub(lambda _match: self.new, data)

    def feed(self, chunk: bytes):
        if not self.enabled:
            yield chunk
        elif not self.json_mode and self.anywhere is None:
            yield from self._text(chunk)
        else:
            # Discovery output is small; rg JSON records can be multi-megabyte match lines.
            separator = rb"\n" if self.json_mode else rb"[\n\0]"
            start = 0
            for match in re.finditer(separator, chunk):
                end = match.end()
                self.record.extend(chunk[start:end])
                yield self._record(bytes(self.record))
                self.record.clear()
                start = end
            self.record.extend(chunk[start:])

    def flush(self):
        if self.enabled:
            if not self.json_mode and self.anywhere is None:
                yield from self._text(b"", final=True)
            elif self.record:
                yield self._record(bytes(self.record))
                self.record.clear()


def acquire_slot(directory: str, limit: int, wait_seconds: float) -> int | None:
    os.makedirs(directory, mode=0o700, exist_ok=True)
    deadline = time.monotonic() + wait_seconds
    order = list(range(limit))
    while True:
        random.shuffle(order)
        for index in order:
            fd = os.open(os.path.join(directory, f"slot.{index}"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except BlockingIOError:
                os.close(fd)
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.05)


def runner_command(args: Args, relative: str, spec: str, mux: bool) -> list[str]:
    command = [
        args.runner,
        "--ssh-config", args.ssh_config,
        "--alias", args.alias,
        "--project-root", args.project_root,
        "--project-root-b64", base64.b64encode(os.fsencode(args.project_root)).decode("ascii"),
        "--cwd-relative-b64", base64.b64encode(os.fsencode(relative)).decode("ascii"),
        "--tool", args.tool,
        "--args-b64", spec,
    ]
    if mux and args.control_path:
        command += ["--control-path", args.control_path]
    else:
        command.append("--no-mux")
    return command


def stop_master(args: Args) -> None:
    """Ask a possibly wedged master to stop accepting sessions; running sessions finish normally."""
    if not args.control_path or not os.path.exists(args.control_path):
        return
    try:
        subprocess.run(
            ["ssh", "-F", "/dev/null", "-o", f"ControlPath={args.control_path}", "-O", "stop", "rh-mux"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        pass


class ErrorRewriter(OutputRewriter):
    """Map the project root back to the mount in error text, where paths often sit in quotes.

    Lines are rewritten whole; one longer than LIMIT is rewritten in LIMIT-sized pieces.
    """

    LIMIT = 65536

    def __init__(self, old: str, new: str) -> None:
        super().__init__(old, new, False, anywhere=True)
        self.anywhere = re.compile(
            rb"(?<![^\s\x00:='\"`(\[<])" + re.escape(self.old) + rb"(?=$|[/\s\x00:'\"`)\]>,])"
        )

    def feed(self, chunk: bytes):
        while chunk:  # never hold more than LIMIT bytes of one line
            room = max(1, self.LIMIT - len(self.record))
            piece, chunk = chunk[:room], chunk[room:]
            yield from super().feed(piece)
            if len(self.record) >= self.LIMIT:
                yield self._record(bytes(self.record))
                self.record.clear()


class DiagnosticCapture:
    """Hold small project stderr for missing-tool detection; stream overflow as it arrives.

    Error text has the project root mapped back to the mount. Any project stderr inhibits transport
    retries, including a small pending buffer. SSH's own diagnostics go to a separate file and never
    enter this stream.
    """

    LIMIT = 65536

    def __init__(self, ctx: Context) -> None:
        self.pending = bytearray()
        self.emitted = False
        self.ctx = ctx
        self.paths: ErrorRewriter | None = None  # most calls write no stderr: build it on demand

    def _write(self, chunk: bytes) -> None:
        if chunk:
            sys.stderr.buffer.write(chunk)
            sys.stderr.buffer.flush()
            self.emitted = True

    def feed(self, chunk: bytes) -> None:
        if self.paths is None:
            self.paths = ErrorRewriter(self.ctx.root, self.ctx.used_mount)
        for data in self.paths.feed(chunk):
            self._hold(data)

    def _hold(self, chunk: bytes) -> None:
        if not self.emitted and len(self.pending) + len(chunk) <= self.LIMIT:
            self.pending.extend(chunk)
            return
        if self.pending:
            self._write(bytes(self.pending))
            self.pending.clear()
        self._write(chunk)

    def finish(self) -> bytes:
        for data in self.paths.flush() if self.paths is not None else ():
            self._hold(data)
        if self.emitted:
            return b""
        output = bytes(self.pending)
        self.pending.clear()
        return output


def run_attempt(command: list[str], rewriter: OutputRewriter, ctx: Context) -> tuple[int, bool, bytes]:
    global current_proc
    if not getattr(ctx, "diagnostics", None):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import diagnostics
        ctx.diagnostics = diagnostics.from_config(ctx.args.ssh_config)
    log = ctx.diagnostics.new_log()
    if command[0] == ctx.args.runner:
        command += ["--diagnostic-log", log, "--diagnostic-id", ctx.diagnostics.session]
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,  # held open: closing it tells the project host to stop the tool
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    current_proc = proc
    errors = DiagnosticCapture(ctx)

    def drain_stderr() -> None:
        assert proc.stderr is not None
        for chunk in iter(lambda: proc.stderr.read1(65536), b""):
            try:
                errors.feed(chunk)
            except BrokenPipeError:
                proc.terminate()
                os._exit(141)

    reader = threading.Thread(target=drain_stderr, daemon=True)
    reader.start()
    emitted = False
    out = sys.stdout.buffer
    assert proc.stdout is not None
    try:
        for chunk in iter(lambda: proc.stdout.read1(65536), b""):
            for data in rewriter.feed(chunk):
                out.write(data)
                out.flush()
                emitted = True
        for tail in rewriter.flush():
            out.write(tail)
            out.flush()
            emitted = True
    except BrokenPipeError:
        proc.terminate()
        proc.wait()
        os._exit(141)
    status = proc.wait()
    reader.join()
    proc.stdout.close()
    assert proc.stderr is not None
    proc.stderr.close()
    try:
        if proc.stdin is not None:
            proc.stdin.close()
    except OSError:
        pass
    current_proc = None
    stderr = errors.finish()
    ctx.transport_failure = bool(status == TRANSPORT_FAILURE and os.path.getsize(log))
    ctx.transport_detail = b""
    if ctx.transport_failure:
        with open(log, "rb") as source:
            ctx.transport_detail = source.read(65536)
    return status, emitted or errors.emitted, stderr


def warm_attempt(ctx: Context, relative: str, spec: str, rewriter: OutputRewriter) -> tuple[int, bool, bytes] | None:
    """The call on a channel the session's warm pool opened ahead of time (warm_pool.py), or None when
    there is none or the complete request could not be written. Read-only requests can also retry
    after an uncertain delivery status of 255."""
    global current_claim
    args = ctx.args
    if not args.warm_socket:
        return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # warm_pool.py sits beside us
    import warm_pool

    held = warm_pool.claim(args.warm_socket)
    if held is None:
        return None
    current_claim = held
    request = " ".join(("remote-harness-tool", base64.b64encode(os.fsencode(args.project_root)).decode("ascii"),
                        base64.b64encode(os.fsencode(relative)).decode("ascii"), args.tool, spec))
    errors = DiagnosticCapture(ctx)
    emitted = False
    out = sys.stdout.buffer

    def on_stdout(chunk: bytes) -> None:
        nonlocal emitted
        for data in rewriter.feed(chunk):
            out.write(data)
            out.flush()
            emitted = True

    try:
        status = warm_pool.run(held, request, on_stdout, errors.feed, diagnostics=ctx.diagnostics,
                               report_failures=False)
        for tail in rewriter.flush():
            out.write(tail)
            out.flush()
            emitted = True
    except warm_pool.NotDelivered:
        return None
    except BrokenPipeError:
        held.close()
        os._exit(141)
    finally:
        held.close()
        current_claim = None
    stderr = errors.finish()
    ctx.transport_failure = getattr(held, "transport_failure", False)
    ctx.transport_detail = b""
    return status, emitted or errors.emitted, stderr


def route(ctx: Context, effective: str, routed: list[str]) -> int:
    args = ctx.args
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import diagnostics as diagnostic_helpers
    try:
        ctx.diagnostics = diagnostic_helpers.from_config(args.ssh_config)
    except diagnostic_helpers.Unavailable:
        sys.stderr.buffer.write(diagnostic_helpers.summary("diagnostics", 255))
        return TRANSPORT_FAILURE
    ctx.transport_failure = False
    ctx.transport_detail = b""
    relative = os.path.relpath(os.path.realpath(effective), ctx.mount_real)
    spec = encode_args(routed)
    json_mode = args.tool == "rg" and ctx.rg_json

    def rewriter() -> OutputRewriter:
        # git scan output is repository-relative; rg and git discovery (rev-parse --show-toplevel,
        # worktree list, ...) print absolute project-host paths that must name the mount again.
        target = ctx.used_mount if args.tool == "rg" or ctx.rewrite_output else ctx.root
        return OutputRewriter(ctx.root, target, json_mode, anywhere=ctx.rewrite_output)

    try:
        limit = max(1, int(os.environ.get("RH_TOOL_CONCURRENCY") or args.concurrency))
        queue_seconds = float(os.environ.get("RH_TOOL_QUEUE_SECONDS") or "600")
    except ValueError:
        limit, queue_seconds = 6, 600.0
    slot = acquire_slot(args.slots_dir, limit, queue_seconds)
    if slot is None:
        ctx.diagnostics.emit("capacity", TRANSPORT_FAILURE)
        return TRANSPORT_FAILURE
    try:
        # A warm channel first. The call is read-only, so one that failed on its transport without
        # output is safe to run again on a new channel.
        result = warm_attempt(ctx, relative, spec, rewriter())
        if result is None or (ctx.transport_failure and not result[1] and not result[2]):
            result = run_attempt(runner_command(args, relative, spec, True), rewriter(), ctx)
            if ctx.transport_failure and not result[1] and not result[2] and args.control_path:
                # A capacity refusal says the master is alive. Leave its running sessions and
                # future callers alone; only other transport failures retire a possibly wedged one.
                error = ctx.transport_detail.lower()
                if b"session open refused" not in error and b"no more sessions" not in error:
                    stop_master(args)
                result = run_attempt(runner_command(args, relative, spec, False), rewriter(), ctx)
        status, emitted, stderr = result
    finally:
        os.close(slot)
    if status == 127 and not emitted and missing_message(args.tool) in stderr:
        raise ToolMissing()
    sys.stderr.buffer.write(stderr)
    sys.stderr.flush()
    if ctx.transport_failure:
        ctx.diagnostics.emit("ssh", status)
    return status


def missing_message(tool: str) -> bytes:
    return f"remote-harness: {tool} is not installed on the project host".encode()


def missing_marker(args: Args) -> str:
    """Session-scoped record that the project host has no such tool (it sits beside the slots)."""
    return os.path.join(os.path.dirname(args.slots_dir.rstrip("/")), f"tool-missing.{args.tool}")


def run_local(ctx: Context, argv: list[str]) -> int:
    real = ctx.args.real
    if not real:
        sys.stderr.write("remote-harness: category=tool exit=127 session=unknown\n")
        return 127
    extra: list[str] = []
    if ctx.args.tool == "git":
        try:
            in_mount = ctx.touches_mount or ctx.inside(os.getcwd())
        except OSError:
            in_mount = ctx.touches_mount
        if in_mount:
            extra = GIT_SSHFS_CONFIG
    try:
        os.execv(real, [ctx.args.real_argv0 or real] + extra + argv)
    except OSError as error:
        status = 127 if isinstance(error, FileNotFoundError) else 126
        sys.stderr.write(f"remote-harness: category=tool exit={status} session=unknown\n")
        return status
    return 127


def handle_signal(signum: int, _frame: object) -> None:
    if current_claim is not None:
        current_claim.close()  # closing the channel's stdin stops the tool on the project host
    proc = current_proc
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    os._exit(128 + signum)


TOOLS = ("git", "rg")


class Args:
    """The shim's options as inject-rule.sh writes them: `--name value` pairs, no argparse needed."""

    OPTIONS = ("--tool", "--real", "--real-argv0", "--runner", "--ssh-config", "--alias",
               "--project-root", "--mount-root", "--control-path", "--slots-dir", "--concurrency",
               "--warm-socket")
    REQUIRED = ("tool", "runner", "ssh_config", "alias", "project_root", "mount_root", "slots_dir")

    def __init__(self, argv: list[str]) -> None:
        self.real = ""
        self.real_argv0 = ""  # e.g. a native Claude binary serving `rg`
        self.control_path = ""
        self.concurrency = "6"
        self.warm_socket = ""  # the session's warm pool, when it has one
        if len(argv) % 2:
            raise ValueError("every option needs a value")
        for flag, value in zip(argv[::2], argv[1::2]):
            if flag not in self.OPTIONS:
                raise ValueError(f"unknown option {flag}")
            setattr(self, flag[2:].replace("-", "_"), value)
        missing = [name for name in self.REQUIRED if not hasattr(self, name)]
        if missing:
            raise ValueError("missing --" + ", --".join(name.replace("_", "-") for name in missing))
        if self.tool not in TOOLS:
            raise ValueError(f"unsupported tool {self.tool}")


def main() -> int:
    raw = sys.argv[1:]
    if "--" not in raw:
        sys.stderr.write("remote-harness: category=input exit=2 session=unknown\n")
        return 2
    split = raw.index("--")
    try:
        args = Args(raw[:split])
    except ValueError:
        sys.stderr.write("remote-harness: category=input exit=2 session=unknown\n")
        return 2
    argv = raw[split + 1:]
    ctx = Context(args)

    try:
        cwd = os.getcwd()
    except OSError:
        return run_local(ctx, argv)
    try:
        if args.tool == "git":
            effective, routed = git_plan(ctx, argv, cwd)
        else:
            effective, routed = rg_plan(ctx, argv, cwd)
    except StayLocal:
        return run_local(ctx, argv)
    # The project host was reachable but lacks this tool (e.g. a Mac without ripgrep): keep the
    # agent-host tool for the rest of the session. This is not a transport failure, so it does not
    # weaken the rule that an unreachable project host never falls back to scanning the mount.
    if os.path.exists(missing_marker(args)):
        return run_local(ctx, argv)

    load_routing_modules()
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, handle_signal)
    try:
        return route(ctx, effective, routed)
    except ToolMissing:
        try:
            with open(missing_marker(args), "w", encoding="utf-8") as handle:
                handle.write(f"{args.tool} is not installed on the project host\n")
        except OSError:
            pass
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, signal.SIG_DFL)
        return run_local(ctx, argv)
    except Exception:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import diagnostics
        store = getattr(ctx, "diagnostics", None)
        if store:
            try:
                import traceback
                store.record(traceback.format_exc().encode())
            except diagnostics.Unavailable:
                pass
        sys.stderr.buffer.write(diagnostics.summary("framework", 255, store.session if store else "unknown"))
        return 255


if __name__ == "__main__":
    raise SystemExit(main())
