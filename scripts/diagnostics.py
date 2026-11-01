"""Private harness diagnostics, separate from the project's stdout and stderr.

These files protect against accidental disclosure. They do not isolate processes of the same UID.
Only the harness reads them automatically; agents need an explicit request for detailed diagnostics.
"""
from __future__ import annotations

import os
import stat
import sys


class Unavailable(Exception):
    pass


def summary(category: str, status: int, session: str = "unknown") -> bytes:
    return f"remote-harness: category={category} exit={status} session={session}\n".encode()


def private_directory(path: str) -> None:
    """Only managed runtime/log directories are created or chmodded; neither may be a symlink."""
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Unavailable()
    os.chmod(path, 0o700)


class Diagnostics:
    """Per-session private error files. Callers pass a prepared file to OpenSSH's -E option."""
    def __init__(self, directory: str) -> None:
        try:
            # Canonicalize the trusted config parent: /tmp, /var and HOME may be normal OS aliases.
            runtime = os.path.dirname(os.path.abspath(directory))
            runtime = os.path.join(os.path.realpath(os.path.dirname(runtime)), os.path.basename(runtime))
            directory = os.path.join(runtime, os.path.basename(directory))
            private_directory(os.path.dirname(directory))
            private_directory(directory)
            self.directory = directory
            identity = os.path.join(directory, "public-id")
            if not os.path.lexists(identity):
                import secrets
                import tempfile
                fd, temporary = tempfile.mkstemp(prefix="id.", dir=directory)
                try:
                    with os.fdopen(fd, "w") as output:
                        output.write(secrets.token_hex(16))
                    try:
                        os.link(temporary, identity, follow_symlinks=False)
                    except FileExistsError:
                        pass
                finally:
                    os.unlink(temporary)
            fd = os.open(identity, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "r") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode):
                    raise Unavailable()
                self.session = source.read(65).strip()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or len(self.session) != 32
                    or any(c not in "0123456789abcdef" for c in self.session)):
                raise Unavailable()
        except (OSError, ValueError) as error:
            raise Unavailable() from error

    def new_log(self, prefix: str = "ssh") -> str:
        try:
            import tempfile
            # Masters can keep writing after a client ends. Session cleanup owns these records.
            fd, path = tempfile.mkstemp(prefix=prefix + ".", dir=self.directory)
            os.close(fd)
            return path
        except OSError as error:
            raise Unavailable() from error

    def record(self, data: bytes) -> None:
        try:
            path = self.new_log("framework")
            fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "wb") as output:
                output.write(data[-512 * 1024:])
        except (OSError, Unavailable) as error:
            raise Unavailable() from error

    def emit(self, category: str, status: int, output=None) -> None:
        if output is None:
            output = sys.stderr.buffer.write
        output(summary(category, status, self.session))


def from_config(config: str) -> Diagnostics:
    return Diagnostics(os.path.join(os.path.dirname(os.path.abspath(config)), "runtime", "diagnostics"))
