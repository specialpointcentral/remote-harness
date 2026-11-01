#!/usr/bin/env python3
"""Behavioral checks for private transport diagnostics and unchanged project streams."""
import base64
import concurrent.futures
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import diagnostics
import warm_pool


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-diagnostics-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'private-connection-config'
        self.config.write_text('Host project\n HostName 127.0.0.1\n')
        self.store = diagnostics.from_config(str(self.config))
        self.project = self.root / 'mount'
        self.project.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        fake = self.bin / 'ssh'
        fake.write_text('#!' + sys.executable + '\n'
            'import base64, os, sys\n'
            'args=sys.argv[1:]\n'
            'if "-O" in args: raise SystemExit(0)\n'
            'with open(os.environ["TEST_SSH_CALLS"],"a") as f: f.write("call\\n")\n'
            'detail=os.environ.get("TEST_SSH_DETAIL", "")\n'
            'if detail:\n'
            ' with open(args[args.index("-E")+1],"a") as f: f.write(detail)\n'
            'os.write(1,base64.b64decode(os.environ.get("TEST_PROJECT_OUT", "")))\n'
            'os.write(2,base64.b64decode(os.environ.get("TEST_PROJECT_ERR", "")))\n'
            'raise SystemExit(int(os.environ.get("TEST_PROJECT_STATUS", "0")))\n')
        fake.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_SSH_CALLS=str(self.calls))

    def runner(self):
        return [str(SCRIPTS / 'run-on-project-host.sh'), '--ssh-config', str(self.config),
                '--alias', 'project', '--project-root', str(self.project),
                '--cwd-relative-b64', 'Lg==', '--command-b64', 'dHJ1ZQ==', '--watch']

    def invoke(self, kind, **env):
        if kind == 'standalone':
            command = self.runner()
        elif kind in ('cold', 'background'):
            command = [sys.executable, '-I', '-S', str(SCRIPTS / 'channel-guard.py'),
                       '--diagnostics-dir', self.store.directory]
            if kind == 'background':
                command.append('--background')
            command += ['--', *self.runner()]
        else:
            command = [sys.executable, '-I', '-S', str(SCRIPTS / 'project-host-tool.py'),
                       '--tool', 'git', '--real', shutil.which('git'),
                       '--runner', str(SCRIPTS / 'run-on-project-host.sh'),
                       '--ssh-config', str(self.config), '--alias', 'project',
                       '--project-root', str(self.project), '--mount-root', str(self.project),
                       '--control-path', str(self.root / 'mux'), '--slots-dir', str(self.root / 'slots'),
                       '--', 'status']
        return subprocess.run(command, cwd=self.project, env=dict(self.env, **env), capture_output=True, timeout=5)

    def test_project_stderr_and_exit255_survive_all_cold_paths_without_retry(self):
        error = b'Permission denied on /private/host/project; mux_client_request_session\n\x00\xff'
        for kind in ('standalone', 'cold', 'background', 'tool'):
            with self.subTest(kind=kind):
                self.calls.unlink(missing_ok=True)
                result = self.invoke(kind, TEST_PROJECT_ERR=base64.b64encode(error).decode(),
                                     TEST_PROJECT_STATUS='255')
                self.assertEqual((result.returncode, result.stdout, result.stderr), (255, b'', error))
                self.assertEqual(self.calls.read_text(), 'call\n')

    def test_project_success_streams_are_exact_and_transport_success_is_quiet(self):
        output, error = b'project\x00\xff\n', b'/private/project warning\n'
        for kind in ('standalone', 'cold', 'background', 'tool'):
            with self.subTest(kind=kind):
                result = self.invoke(kind, TEST_PROJECT_OUT=base64.b64encode(output).decode(),
                                     TEST_PROJECT_ERR=base64.b64encode(error).decode())
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, output, error))
                result = self.invoke(kind)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'', b''))

    def test_transport_detail_is_private_and_tool_retry_keeps_only_final_summary(self):
        detail = 'PRIVATE_TARGET PRIVATE_USER /private/config/path: Connection refused\n'
        for kind in ('standalone', 'cold', 'background', 'tool'):
            with self.subTest(kind=kind):
                self.calls.unlink(missing_ok=True)
                result = self.invoke(kind, TEST_SSH_DETAIL=detail, TEST_PROJECT_STATUS='255')
                self.assertEqual(result.returncode, 255)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(result.stderr, diagnostics.summary('ssh', 255, self.store.session))
                self.assertEqual(len(self.calls.read_text().splitlines()), 2 if kind == 'tool' else 1)
                self.assertTrue(any(detail.encode() in path.read_bytes()
                                    for path in Path(self.store.directory).glob('ssh.*')))

    @unittest.skipUnless(shutil.which('ssh'), 'OpenSSH is unavailable')
    def test_actual_ssh_bad_banner_logs_its_errors_without_network_or_stderr_leak(self):
        real_ssh = shutil.which('ssh')
        banner = b'SSH-PRIVATE_INVALID_VERSION\r\n'
        proxy = self.root / 'invalid-ssh-banner.py'
        # Consume the client banner, then hold the pipes open until OpenSSH rejects ours.
        # Immediate proxy EOF diagnostics vary across OpenSSH versions; this produces an ERROR.
        proxy.write_text('import sys\n'
            'sys.stdin.buffer.readline()\n'
            f'sys.stdout.buffer.write({banner!r})\n'
            'sys.stdout.buffer.flush()\n'
            'sys.stdin.buffer.read()\n')
        proxy_command = 'ProxyCommand=' + shlex.join([sys.executable, str(proxy)])
        # A leading option wins over the runner's disabled ProxyCommand. This test-only wrapper
        # reaches OpenSSH itself, with no network connection or external proxy diagnostic stream.
        (self.bin / 'ssh').write_text('#!' + sys.executable + '\nimport os,sys\n'
            f'os.execv({real_ssh!r}, [{real_ssh!r}, "-o", {proxy_command!r}] + sys.argv[1:])\n')
        result = self.invoke('standalone')
        self.assertEqual(result.returncode, 255)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, diagnostics.summary('ssh', 255, self.store.session))
        self.assertTrue(any(banner.rstrip(b'\r\n') in path.read_bytes()
                            for path in Path(self.store.directory).glob('ssh.*')))

    def warm(self, acknowledged, error, output=b''):
        code = ('import os,sys,time\n'
                'request=sys.stdin.buffer.readline()\n'
                f'os.write(2,{error!r})\n'
                'time.sleep(.03)\n' +
                (f'os.write(1,{warm_pool.GOT + output!r})\n' if acknowledged else '') +
                'raise SystemExit(255)\n')
        proc = subprocess.Popen([sys.executable, '-c', code], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        client, broker = socket.socketpair()
        held = warm_pool.Claim(client, [os.dup(proc.stdin.fileno()), os.dup(proc.stdout.fileno()),
                                       os.dup(proc.stderr.fileno())])
        def finish():
            proc.wait()
            try:
                broker.sendall(b'EXIT 255\n')
            finally:
                broker.close()
        thread = threading.Thread(target=finish)
        thread.start()
        out, err = [], []
        try:
            status = warm_pool.run(held, 'remote-harness-exec Lw== Lg== dHJ1ZQ== watch',
                                   out.append, err.append, diagnostics=self.store)
        finally:
            held.close()
            proc.stdin.close()
            proc.stdout.close()
            proc.stderr.close()
            thread.join(timeout=3)
        return status, b''.join(out), b''.join(err), held.transport_failure

    def test_warm_stderr_before_ack_is_preserved_exactly_when_ack_arrives(self):
        error = b'project own255 Permission denied /private/path\x00\xff'
        self.assertEqual(self.warm(True, error, b'output\x00'), (255, b'output\x00', error, False))

    def test_warm_lost_ack_saves_details_privately_and_marks_uncertain_delivery(self):
        detail = b'PRIVATE_TARGET /private/path: secret transport failure\n'
        self.assertEqual(self.warm(False, detail),
                         (255, b'', diagnostics.summary('delivery_uncertain', 255, self.store.session), True))
        self.assertTrue(any(detail in path.read_bytes()
                            for path in Path(self.store.directory).glob('framework.*')))

    def test_unavailable_private_log_fails_closed_without_command_or_paths(self):
        shutil.rmtree(self.store.directory)
        os.symlink(self.project, self.store.directory)
        for kind in ('standalone', 'cold', 'background', 'tool'):
            with self.subTest(kind=kind):
                result = self.invoke(kind)
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, rb'^remote-harness: category=\w+ exit=\d+ session=\w+\n$')
                self.assertFalse(self.calls.exists())
        self.assertEqual(list(self.project.iterdir()), [])

    def test_missing_standalone_config_does_not_create_files_in_project(self):
        result = subprocess.run([str(SCRIPTS / 'run-on-project-host.sh')], cwd=self.project,
                                env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, diagnostics.summary('framework', 2))
        self.assertEqual(list(self.project.iterdir()), [])

    def test_identity_publish_is_atomic_private_and_does_not_change_umask(self):
        Path(self.store.directory, 'public-id').unlink()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
            identities = list(workers.map(lambda _: diagnostics.from_config(str(self.config)).session, range(32)))
        self.assertEqual(len(set(identities)), 1)
        previous = os.umask(0o027)
        try:
            store = diagnostics.from_config(str(self.config))
            log = Path(store.new_log())
            self.assertEqual(os.umask(0o027), 0o027)
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(store.directory).stat().st_mode & 0o777, 0o700)
        finally:
            os.umask(previous)
        identity = Path(self.store.directory, 'public-id')
        identity.unlink()
        os.mkfifo(identity, 0o600)
        result = self.invoke('cold')
        self.assertEqual(result.returncode, 255)
        self.assertEqual(result.stderr, diagnostics.summary('diagnostics', 255))


if __name__ == '__main__':
    unittest.main()
