#!/usr/bin/env python3
"""Behavior checks for transport settings, routing quotas, and warm broker lifecycle."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import signal
import socket
import shutil
import concurrent.futures
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-cap-settings-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('RH_') and k not in ('BASH_ENV', 'ENV')}
        self.env['HOME'] = str(self.home)

    def shell(self, body, **values):
        return subprocess.run(['bash', '-uc', '. "$1"; ' + body, 'test', str(SCRIPTS / '_common.sh')],
                              env=dict(self.env, **values), text=True, capture_output=True)

    def test_defaults_reach_new_shell_as_explicit_numeric_environment(self):
        result = self.shell('transport_settings_load && $(transport_settings_env) python3 -c '
                            + shlex.quote('import os; print(os.environ["RH_SSHD_MAX_SESSIONS"], '
                                          'os.environ["RH_WARM_MAX"], os.environ["RH_WARM_READY_MAX"], '
                                          'os.environ["RH_WARM_OPENING_MAX"], os.environ["RH_CHANNEL_QUEUE_SECONDS"], '
                                          'os.environ["RH_BACKGROUND_CONCURRENCY"], os.environ["RH_WARM_MIN"], '
                                          'os.environ["RH_FOREGROUND_CONCURRENCY"], os.environ["RH_TOOL_CONCURRENCY"], '
                                          'os.environ["RH_TOOL_QUEUE_SECONDS"], os.environ["RH_BACKGROUND_QUEUE_SECONDS"])'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '32 9 2 2 600 8 1 6 6 600 10')

    def test_pool_default_follows_the_local_sshd_mode(self):
        # The system sshd keeps OpenSSH's MaxSessions 10; the user-mode sshd is configured by us.
        for mode, settings, expected in (('system', {}, '9'), ('', {}, '9'), ('user', {}, '16'),
                                         ('user', {'RH_SSHD_MAX_SESSIONS': '8'}, '7'),
                                         ('user', {'RH_SSHD_MAX_SESSIONS': '1'}, '0'),
                                         ('user', {'RH_WARM_MAX': '12'}, '12'),
                                         ('system', {'RH_WARM_MAX': '16'}, '16')):
            with self.subTest(mode=mode, settings=settings):
                result = self.shell('transport_settings_load "$1" && printf "%s" "$RH_WARM_MAX"'.replace('"$1"', shlex.quote(mode)),
                                    **settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_sixteen_channel_configuration_is_accepted_from_file_and_environment(self):
        config = self.home / 'transport.conf'
        config.write_text('RH_WARM_MAX=16\n')
        for settings in ({'RH_TRANSPORT_CONFIG': str(config)}, {'RH_WARM_MAX': '16'}):
            with self.subTest(settings=settings):
                result = self.shell('transport_settings_load && $(transport_settings_env) '
                                    'sh -c \'printf "%s" "$RH_WARM_MAX"\'', **settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '16')

    def test_persistent_file_and_environment_precedence_without_overwrite(self):
        config = self.home / 'transport.conf'
        content = '# local choices\nRH_WARM_MAX=7\nRH_BACKGROUND_CONCURRENCY=3\n'
        config.write_text(content)
        result = self.shell('transport_settings_load && printf "%s %s" "$RH_WARM_MAX" "$RH_BACKGROUND_CONCURRENCY"',
                            RH_TRANSPORT_CONFIG=str(config), RH_WARM_MAX='8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '8 3')
        self.assertEqual(config.read_text(), content)

    def test_rejects_invalid_and_unallowlisted_settings_without_execution(self):
        config = self.home / 'transport.conf'
        marker = self.home / 'executed'
        for value in ('RH_WARM_MAX=abc', 'RH_WARM_MAX=99999999999999999999999',
                      'RH_SSHD_MAX_SESSIONS=0', 'RH_WARM_MAX=17', 'PATH=123', f'RH_WARM_MAX=$(touch {marker})'):
            with self.subTest(value=value):
                config.write_text(value + '\n')
                result = self.shell('transport_settings_load', RH_TRANSPORT_CONFIG=str(config))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
        config.unlink()
        for settings in ({'RH_SSHD_MAX_SESSIONS': '-1'}, {'RH_WARM_MAX': '17'}):
            with self.subTest(settings=settings):
                result = self.shell('transport_settings_load', **settings)
                self.assertNotEqual(result.returncode, 0)

    def test_small_and_disabled_pool_normalize_ready_and_minimum(self):
        for maximum, expected in (('1', '1 1 1'), ('0', '0 0 0')):
            result = self.shell('transport_settings_load && $(transport_settings_env) sh -c \'printf "%s %s %s" "$RH_WARM_MAX" "$RH_WARM_READY_MAX" "$RH_WARM_MIN"\'',
                                RH_WARM_MAX=maximum)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_user_sshd_config_has_validated_limit(self):
        result = self.shell('user_sshd_write_config "$HOME" 22222 testuser && cat "$HOME/sshd_config"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('\nMaxSessions 32\n', result.stdout)
        result = self.shell('user_sshd_write_config "$HOME" 22222 testuser && cat "$HOME/sshd_config"',
                            RH_SSHD_MAX_SESSIONS='48')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('\nMaxSessions 48\n', result.stdout)
        result = self.shell('user_sshd_write_config "$HOME" 22222 testuser', RH_SSHD_MAX_SESSIONS='1\nPermitTTY yes')
        self.assertNotEqual(result.returncode, 0)



class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-cap-route-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.mount = self.home / 'mount'
        self.mount.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('RH_') and k not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.home), RH_HOME=str(self.home / 'rh'))

    @staticmethod
    def stop_process(proc):
        if proc.poll() is None:
            # Let the guard cancel and reap its child. Killing only the guard leaves the child's
            # inherited output pipes open, so communicate() can wait for an unrelated job delay.
            proc.terminate()
        try:
            proc.communicate(timeout=6)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate(timeout=3)

    def test_hook_marks_only_explicit_background_calls_and_preserves_input(self):
        runner = self.home / 'runner'
        runner.write_text('#!/bin/sh\nexit 0\n')
        runner.chmod(0o700)
        for background, extra in ((True, ['--background']), (False, [])):
            event = {'tool_name': 'Bash', 'cwd': str(self.mount), 'tool_input':
                     {'command': 'printf hello', 'run_in_background': background, 'timeout': 1234}}
            result = subprocess.run(['python3', str(SCRIPTS / 'route-command.py'), '--runner', str(runner),
                                     '--mount-root', str(self.mount)], input=json.dumps(event),
                                    text=True, capture_output=True, env=self.env)
            updated = json.loads(result.stdout)['hookSpecificOutput']['updatedInput']
            # The hook names the runner by its physical path (macOS: /var -> /private/var).
            self.assertEqual(shlex.split(updated['command']),
                             [os.path.realpath(runner), *extra, 'Lg==', 'cHJpbnRmIGhlbGxv'])
            self.assertEqual(updated['timeout'], 1234)
            self.assertEqual(updated['run_in_background'], background)

    def inject(self, **settings):
        cfg = self.home / 'ssh_config'
        cfg.write_text('Host laptop\n HostName localhost\n')
        env = dict(self.env, **settings)
        result = subprocess.run([str(SCRIPTS / 'inject-rule.sh'), 'on', 'codex', str(self.mount), 'laptop',
                                 str(self.mount), 'normal', str(cfg), 'capacity'],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        sessions = list((self.home / 'rh' / '.sessions').glob('*/bin/rh-run'))
        self.assertEqual(len(sessions), 1)
        return sessions[0].parent

    def test_generated_runner_background_uses_direct_ssh_and_old_calls_still_work(self):
        bin_dir = self.home / 'fake-bin'
        bin_dir.mkdir()
        log = self.home / 'ssh.json'
        fake = bin_dir / 'ssh'
        fake.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                        'open(os.environ["SSH_TEST_LOG"], "w").write(json.dumps(sys.argv[1:]))\n'
                        'sys.exit(23)\n')
        fake.chmod(0o700)
        env = dict(self.env, PATH=str(bin_dir) + ':' + self.env['PATH'], SSH_TEST_LOG=str(log))
        original = self.env
        self.env = env
        session_bin = self.inject(RH_WARM_MAX='0')
        self.env = original
        for flags, master in (([], 'ControlMaster=auto'), (['--background'], 'ControlMaster=no')):
            result = subprocess.run([str(session_bin / 'rh-run'), *flags, 'Lg==', 'dHJ1ZQ=='],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            args = json.loads(log.read_text())
            self.assertIn(master, args)
            self.assertIn('remote-harness-exec', args[-1])
            self.assertTrue(args[-1].endswith(' watch'))
            if flags:
                self.assertIn('ControlPath=none', args)

    def test_restricted_path_without_basename_keeps_session_quotas_separate(self):
        restricted = self.home / 'restricted-bin'
        restricted.mkdir()
        for name in ('bash', 'sh', 'dirname', 'mkdir', 'chmod', 'sed', 'tr', 'awk', 'cat',
                     'rm', 'cp', 'git', 'python3', 'grep', 'cksum', 'base64'):
            (restricted / name).symlink_to(shutil.which(name))
        fake_ssh = restricted / 'ssh'
        fake_ssh.write_text('#!/bin/sh\nexit 23\n')
        fake_ssh.chmod(0o700)
        cfg = self.home / 'ssh_config'
        cfg.write_text('Host laptop\n HostName localhost\n')
        env = dict(self.env, PATH=str(restricted), RH_WARM_MAX='0')
        quota_paths = []
        for session_id in ('first', 'second'):
            result = subprocess.run([str(SCRIPTS / 'inject-rule.sh'), 'on', 'codex', str(self.mount),
                                     'laptop', str(self.mount), 'normal', str(cfg), session_id],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(line.split('=', 1) for line in result.stdout.splitlines())
            session = Path(values['RH_SESSION_DIR'])
            quota = cfg.parent / 'runtime' / 'bash-slots' / session.name
            for flags, kind in (([], 'foreground'), (['--background'], 'background')):
                routed = subprocess.run([str(session / 'bin' / 'rh-run'), *flags, 'Lg==', 'dHJ1ZQ=='],
                                        env=env, text=True, capture_output=True)
                self.assertEqual(routed.returncode, 23, routed.stderr)
                self.assertTrue(list((quota / kind).glob('slot.*')),
                                f'missing per-session {kind} quota; injection stderr: {result.stderr}')
            self.assertEqual(result.stderr, '')
            quota_paths.append(quota)
        self.assertNotEqual(quota_paths[0], quota_paths[1])
        self.assertEqual({path.name for path in (cfg.parent / 'runtime' / 'bash-slots').iterdir()},
                         {path.name for path in quota_paths})

    def test_capacity_refusal_does_not_retire_healthy_tool_master(self):
        subprocess.run(['git', 'init', '-q', str(self.mount)], check=True)
        cfg = self.home / 'ssh_config'
        cfg.write_text('Host laptop\n HostName localhost\n')
        control = self.home / 'mux'
        control.touch()
        fake_bin = self.home / 'bin'
        fake_bin.mkdir()
        log = self.home / 'ssh.log'
        fake = fake_bin / 'ssh'
        fake.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                        'with open(os.environ["SSH_TEST_LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                        'sys.stderr.write("mux_client_request_session: session request failed: Session open refused by peer\\n")\n'
                        'sys.exit(255)\n')
        fake.chmod(0o700)
        env = dict(self.env, PATH=str(fake_bin)+':'+self.env['PATH'], SSH_TEST_LOG=str(log))
        result = subprocess.run(['python3', str(SCRIPTS / 'project-host-tool.py'), '--tool', 'git',
                                 '--real', '/usr/bin/git', '--runner', str(SCRIPTS / 'run-on-project-host.sh'),
                                 '--ssh-config', str(cfg), '--alias', 'laptop', '--project-root', str(self.mount),
                                 '--mount-root', str(self.mount), '--control-path', str(control),
                                 '--slots-dir', str(self.home / 'tool-slots'), '--', 'status'], cwd=self.mount,
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 255, result.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(calls), 2, calls)
        self.assertFalse(any('-O' in call for call in calls))

    def test_session_launcher_freezes_settings_across_a_clean_environment(self):
        session_bin = self.inject(RH_WARM_MAX='7', RH_BACKGROUND_CONCURRENCY='3', RH_FOREGROUND_CONCURRENCY='5')
        for filename in ('session-reaper.sh', 'warm_pool.py'):
            (session_bin.parent / 'impl' / filename).unlink()
        result = subprocess.run([str(session_bin / 'rh-session'), 'python3', '-c',
                                 'import os; print(os.environ["RH_WARM_MAX"], '
                                 'os.environ["RH_BACKGROUND_CONCURRENCY"], os.environ["RH_FOREGROUND_CONCURRENCY"])'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '7 3 5')

    def test_session_launcher_freezes_default_nine_and_eight_settings(self):
        session_bin = self.inject()
        for filename in ('session-reaper.sh', 'warm_pool.py'):
            (session_bin.parent / 'impl' / filename).unlink()
        result = subprocess.run([str(session_bin / 'rh-session'), 'python3', '-c',
                                 'import os; print(os.environ["RH_WARM_MAX"], '
                                 'os.environ["RH_BACKGROUND_CONCURRENCY"])'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '9 8')

    def test_default_background_quota_holds_eight_and_ninth_times_out(self):
        command = ['python3', str(SCRIPTS / 'channel-guard.py'), '--background',
                   '--slots-dir', str(self.home / 'slots'), '--']
        # The long foreground queue does not apply: background slots free up rarely.
        env = dict(self.env, RH_BACKGROUND_QUEUE_SECONDS='1', RH_CHANNEL_QUEUE_SECONDS='600')
        child = ['python3', '-c', 'import sys; print("running", flush=True); sys.stdin.read()']
        held = []
        for index in range(8):
            proc = subprocess.Popen(command + child, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            held.append(proc)
            self.addCleanup(self.stop_process, proc)
            self.assertEqual(proc.stdout.readline().strip(), 'running', f'background slot {index + 1}')
        started = time.monotonic()
        blocked = subprocess.run(command + child, env=env, text=True, capture_output=True, timeout=3)
        elapsed = time.monotonic() - started
        self.assertEqual(blocked.returncode, 255)
        self.assertNotIn('running', blocked.stdout)
        self.assertIn('too many concurrent background', blocked.stderr)
        self.assertGreaterEqual(elapsed, .8)
        self.assertLess(elapsed, 2.5)
        held[0].terminate()
        held[0].communicate(timeout=3)
        reused = subprocess.run(command + ['python3', '-c', 'raise SystemExit(21)'],
                                env=env, text=True, capture_output=True, timeout=3)
        self.assertEqual(reused.returncode, 21, reused.stderr)

    def test_guard_limits_fallback_and_background_independently(self):
        command = ['python3', str(SCRIPTS / 'channel-guard.py'), '--slots-dir', str(self.home / 'slots')]
        env = dict(self.env, RH_FOREGROUND_CONCURRENCY='1', RH_BACKGROUND_CONCURRENCY='1', RH_CHANNEL_QUEUE_SECONDS='0')
        release = self.home / 'release'
        child = ['python3', '-c', 'import sys,time; from pathlib import Path\n'
                 'print("running", flush=True)\n'
                 'while not Path(sys.argv[1]).exists(): time.sleep(.01)\n'
                 'raise SystemExit(17)', str(release)]
        first = subprocess.Popen(command + ['--'] + child, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_process, first)
        self.assertEqual(first.stdout.readline().strip(), 'running')
        blocked = subprocess.run(command + ['--'] + child, env=env, text=True, capture_output=True)
        self.assertEqual(blocked.returncode, 255)
        self.assertNotIn('running', blocked.stdout)
        background = subprocess.run(command + ['--background', '--', 'python3', '-c', 'raise SystemExit(19)'],
                                    env=env, text=True, capture_output=True)
        self.assertEqual(background.returncode, 19, background.stderr)
        release.touch()
        out, err = first.communicate(timeout=4)
        self.assertEqual(first.returncode, 17, err)
        reused = subprocess.run(command + ['--', 'python3', '-c', 'raise SystemExit(21)'],
                                env=env, text=True, capture_output=True)
        self.assertEqual(reused.returncode, 21, reused.stderr)

    def test_guard_background_keeps_stdin_open_and_cancels_child(self):
        pid_file = self.home / 'child.pid'
        body = 'import os,sys; open(sys.argv[1], "w").write(str(os.getpid())); print("started",flush=True); sys.stdin.read()'
        guard = subprocess.Popen(['python3', str(SCRIPTS / 'channel-guard.py'), '--background', '--slots-dir',
                                  str(self.home / 'slots'), '--', 'python3', '-c', body, str(pid_file)],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_process, guard)
        self.assertEqual(guard.stdout.readline().strip(), 'started')
        self.assertIsNone(guard.poll())
        child_pid = int(pid_file.read_text())
        cancelled_at = time.monotonic()
        guard.terminate()
        guard.communicate(timeout=6)
        self.assertLess(time.monotonic() - cancelled_at, 2)
        self.assertEqual(guard.returncode, 128 + signal.SIGTERM)
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)



class PoolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-pool-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.socket = str(self.root / 'pool')
        self.control = str(self.root / 'mux')
        self.session = self.root / 'session'
        self.session.mkdir()
        self.project = self.root / 'project'
        self.project.mkdir()
        self.mode = self.root / 'mode'
        self.mode.write_text('normal')
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        (fake_bin / 'ssh').symlink_to(ROOT / 'tests' / 'fixtures' / 'capacity_ssh.py')
        gateway_bin = self.root / 'gateway' / 'bin'
        gateway_bin.mkdir(parents=True)
        for filename in ('project-host-gateway.sh', 'run-on-project-host.sh'):
            shutil.copy2(SCRIPTS / filename, gateway_bin)
        registration = self.root / 'gateway' / '.sessions' / 'gateways' / 'capacity'
        registration.mkdir(parents=True)
        registration.joinpath('project-root.b64').write_text(base64.b64encode(os.fsencode(self.project)).decode())
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('RH_') and k not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.root), POOL_FIXTURE=str(self.root), PATH=str(fake_bin)+':'+self.env['PATH'],
                        RH_WARM_MAX='8', RH_WARM_MIN='2', RH_WARM_READY_MAX='2', RH_WARM_OPENING_MAX='2',
                        RH_WARM_OPEN_TIMEOUT='1')
        self.pool = None
        spec = importlib.util.spec_from_file_location('warm_capacity_test', SCRIPTS / 'warm_pool.py')
        self.warm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.warm)
        self.addCleanup(self.stop)

    def start(self, mode='normal', **settings):
        self.mode.write_text(mode)
        self.error = (self.root / 'broker.err').open('w')
        self.addCleanup(self.error.close)
        self.pool = subprocess.Popen(['python3', str(SCRIPTS / 'warm_pool.py'), 'serve', '--socket', self.socket,
                                      '--control-path', self.control, '--ssh-config', '/dev/null', '--alias', 'host',
                                      '--owner-pid', str(os.getpid()), '--session-dir', str(self.session),
                                      '--log', str(self.root / 'warm.log')],
                                     env=dict(self.env, **settings), stdout=subprocess.DEVNULL, stderr=self.error)
        self.wait_for(lambda: Path(self.socket).exists())

    def stop(self):
        if self.pool is not None and self.pool.poll() is None:
            self.pool.terminate()
            try:
                self.pool.wait(timeout=6)
            except subprocess.TimeoutExpired:
                self.pool.kill()
                self.pool.wait(timeout=3)

        events = self.root / 'events'
        if events.exists():
            for line in events.read_text().splitlines():
                pid = json.loads(line)['pid']
                try:
                    command = Path(f'/proc/{pid}/cmdline').read_bytes()
                    if os.fsencode(self.root / 'bin' / 'ssh') in command:
                        os.kill(pid, signal.SIGKILL)
                except (FileNotFoundError, ProcessLookupError):
                    pass

    def wait_for(self, predicate, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.pool is not None and self.pool.poll() is not None:
                self.fail('broker exited: ' + (self.root / 'broker.err').read_text())
            time.sleep(.025)
        self.fail('timed out; stats=' + str(self.stats()) + '; log=' + self.log())

    def log(self):
        path = self.root / 'warm.log'
        return path.read_text() if path.exists() else ''

    def stats(self):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(.5)
                conn.connect(self.socket)
                conn.sendall(b'STAT\n')
                return {key: int(value) for key, value in (part.split('=') for part in conn.recv(512).decode().split())}
        except OSError:
            return {}

    def ready(self, number=2):
        self.wait_for(lambda: self.stats().get('ready') == number)

    def request(self, command):
        root = base64.b64encode(os.fsencode(self.project)).decode()
        encoded = base64.b64encode(command.encode()).decode()
        return f'remote-harness-exec {root} Lg== {encoded} watch'

    def run_claim(self, held, command):
        out, err = [], []
        try:
            status = self.warm.run(held, self.request(command), out.append, err.append)
            return status, b''.join(out), b''.join(err)
        finally:
            held.close()

    def test_repeated_claim_close_does_not_close_reused_descriptor(self):
        left, right = socket.socketpair()
        self.addCleanup(right.close)
        descriptors = [os.open('/dev/null', os.O_RDWR) for _ in range(3)]
        claim = self.warm.Claim(left, descriptors)
        claim.close()
        reused = os.open('/dev/null', os.O_RDWR)
        os.dup2(reused, descriptors[0])
        if reused != descriptors[0]:
            os.close(reused)
        reused = descriptors[0]
        claim.close()
        os.fstat(reused)
        os.close(reused)

    def test_empty_demand_never_grows_reserve_or_opening_past_caps(self):
        self.start('hang-opening', RH_WARM_OPENING_MAX='1')
        for _ in range(20):
            self.assertIsNone(self.warm.claim(self.socket))
        counts = self.stats()
        self.assertLessEqual(counts['target'], 2)
        self.assertLessEqual(counts['opening'], 1)

    def test_real_fd_handoff_caps_ready_and_opening_and_preserves_exit(self):
        self.start()
        self.ready()
        held = []
        for _ in range(6):
            self.wait_for(lambda: self.stats().get('ready', 0) > 0)
            ch = self.warm.claim(self.socket)
            self.assertIsNotNone(ch)
            held.append(ch)
            self.addCleanup(ch.close)
            counts = self.stats()
            self.assertLessEqual(counts['ready'], 2)
            self.assertLessEqual(counts['opening'], 2)
            self.assertLessEqual(sum(counts[k] for k in ('ready', 'opening', 'handed', 'closing')), 8)
        self.ready()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            futures = [executor.submit(self.run_claim, ch, 'printf one; exit 17') for ch in held]
            for future in futures:
                self.assertEqual(future.result(timeout=5), (17, b'one', b''))
        self.wait_for(lambda: self.stats().get('handed') == 0)
        self.ready()
        counts = self.stats()
        self.assertLessEqual(counts['ready'], 2)
        self.assertLessEqual(counts['target'], 2)
        events = (self.root / 'events').read_text()
        self.assertNotIn('fresh-connection-allowed', events)
        self.assertIn('opening->ready', self.log())
        self.assertIn('ready->handed', self.log())
        self.assertNotIn('printf one', self.log())

    def test_explicit_sixteen_pool_holds_sixteen_channels_and_refuses_seventeenth(self):
        self.start(RH_WARM_MAX='16')
        count = 16
        held = []
        for index in range(count):
            self.wait_for(lambda: self.stats().get('ready', 0) > 0, timeout=2)
            ch = self.warm.claim(self.socket)
            self.assertIsNotNone(ch, f'pool channel {index + 1}')
            held.append(ch)
            self.addCleanup(ch.close)
            counts = self.stats()
            self.assertLessEqual(counts['ready'], 2)
            self.assertLessEqual(counts['opening'], 2)
            self.assertLessEqual(sum(counts[k] for k in ('ready', 'opening', 'handed', 'closing')), count)
        self.assertEqual(self.stats()['handed'], count)
        self.assertIsNone(self.warm.claim(self.socket, wait_seconds=.15))
        self.assertEqual(self.stats()['handed'], count)
        with concurrent.futures.ThreadPoolExecutor(max_workers=count) as executor:
            futures = [executor.submit(self.run_claim, ch, 'printf sixteen; exit 17') for ch in held]
            for future in futures:
                self.assertEqual(future.result(timeout=5), (17, b'sixteen', b''))
        self.wait_for(lambda: self.stats().get('handed') == 0)

    def test_broker_default_and_oversized_configuration_complete_gateway_handshake(self):
        # Exercise serve()'s actual configuration without repeating the full sixteen-job cycle.
        # No forwarded size stays below the system sshd's MaxSessions 10; direct callers that
        # bypass the launcher's strict setting validation are capped at sixteen.
        for maximum, expected in ((None, 9), ('17', 16)):
            with self.subTest(maximum=maximum):
                self.env.pop('RH_WARM_MAX', None)
                if maximum is not None:
                    self.env['RH_WARM_MAX'] = maximum
                log_offset = len(self.log())
                self.start()
                try:
                    self.ready()
                    self.assertRegex(self.log()[log_offset:],
                                     rf'warm pool started \(min \d+, max {expected},')
                    held = self.warm.claim(self.socket)
                    self.assertIsNotNone(held)
                    self.assertEqual(self.run_claim(held, 'printf configured; exit 17'),
                                     (17, b'configured', b''))
                    self.wait_for(lambda: self.stats().get('handed') == 0)
                finally:
                    self.stop()

    def test_queued_fallback_takes_a_warm_channel_that_frees_up(self):
        self.start('hang-opening', RH_WARM_MIN='1')
        self.wait_for(lambda: self.stats().get('opening') == 1)
        env = dict(self.env, RH_FOREGROUND_CONCURRENCY='1', RH_CHANNEL_QUEUE_SECONDS='20')
        slots = str(self.root / 'slots')
        holder = subprocess.Popen(['python3', str(SCRIPTS / 'channel-guard.py'), '--slots-dir', slots, '--',
                                   'python3', '-c', 'import sys; print("holding", flush=True); sys.stdin.read()'],
                                  env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(RoutingTests.stop_process, holder)
        self.assertEqual(holder.stdout.readline().strip(), 'holding')
        cold = self.root / 'cold'
        waiting = subprocess.Popen(['python3', str(SCRIPTS / 'channel-guard.py'), '--slots-dir', slots,
                                    '--warm', self.socket, '--warm-request', self.request('printf warm-after-wait'),
                                    '--', '/bin/sh', '-c', 'touch ' + shlex.quote(str(cold))],
                                   env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(RoutingTests.stop_process, waiting)
        time.sleep(.6)
        self.assertIsNone(waiting.poll(), 'the fallback queue must wait, not fail')
        self.mode.write_text('normal')  # the hung opening times out and a ready channel replaces it
        out, err = waiting.communicate(timeout=6)
        self.assertEqual((waiting.returncode, out), (0, 'warm-after-wait'), err)
        self.assertIsNone(holder.poll(), 'the warm channel, not a freed slot, served the queued call')
        self.assertFalse(cold.exists())

    def test_opening_deadline_reaps_unresponsive_children_and_backs_off(self):
        self.start('hang-opening')
        self.wait_for(lambda: self.stats().get('opening') == 2)
        self.wait_for(lambda: 'opening timeout' in self.log(), timeout=4)
        self.wait_for(lambda: self.stats().get('closing') == 0, timeout=4)
        counts = self.stats()
        self.assertLessEqual(counts['opening'], 2)
        self.assertLessEqual(counts['target'], 2)
        self.mode.write_text('normal')
        self.ready()

    def test_capacity_refusal_backs_off_without_silent_direct_connections(self):
        self.start('capacity')
        self.wait_for(lambda: 'capacity' in self.log().lower(), timeout=4)
        time.sleep(.3)
        events = [json.loads(line) for line in (self.root / 'events').read_text().splitlines()]
        self.assertEqual(sum(e['event'] == 'master-start' for e in events), 1)
        self.assertNotIn('hidden-fresh-connection', [e['event'] for e in events])
        self.assertNotIn('fresh-connection-allowed', [e['event'] for e in events])
        self.assertLessEqual(sum(e['event'] == 'opening' for e in events), 2)
        self.assertEqual(self.stats()['ready'], 0)
        self.mode.write_text('normal')
        self.ready()

    def test_exited_channel_whose_stderr_already_ended_does_not_crash_the_broker(self):
        # reap() drains an exited opening channel; the loop may already have unregistered its stderr.
        self.start('early-stderr-eof', RH_WARM_MIN='1')
        self.wait_for(lambda: 'its ssh exited' in self.log(), timeout=4)
        self.assertIsNone(self.pool.poll(), (self.root / 'broker.err').read_text())
        self.mode.write_text('normal')
        self.ready(1)

    def test_bounded_claim_waits_for_opening_channel_before_fallback(self):
        self.start('delay-ready', RH_WARM_MIN='1')
        self.wait_for(lambda: self.stats().get('opening') == 1)
        held = self.warm.claim(self.socket, wait_seconds=.25)
        self.assertIsNotNone(held)
        self.assertEqual(self.run_claim(held, 'printf warmed'), (0, b'warmed', b''))

    def test_empty_pool_wait_is_bounded_and_missing_broker_is_immediate(self):
        self.start('hang-opening', RH_WARM_MIN='1')
        self.wait_for(lambda: self.stats().get('opening') == 1)
        started = time.monotonic()
        self.assertIsNone(self.warm.claim(self.socket, wait_seconds=.15))
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, .12)
        self.assertLess(elapsed, .5)
        started = time.monotonic()
        self.assertIsNone(self.warm.claim(str(self.root / 'missing'), wait_seconds=.25))
        self.assertLess(time.monotonic() - started, .1)

    def test_complete_request_with_lost_ack_never_runs_cold_fallback(self):
        self.start('loss-ack')
        self.ready()
        marker = self.root / 'once'
        command = 'printf x >> ' + shlex.quote(str(marker))
        cold = self.root / 'cold'
        result = subprocess.run(['python3', str(SCRIPTS / 'channel-guard.py'), '--warm', self.socket,
                                 '--warm-request', self.request(command), '--', '/bin/sh', '-c',
                                 'printf retry >> ' + shlex.quote(str(cold))], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 255, result.stderr)
        self.assertEqual(marker.read_text(), 'x')
        self.assertFalse(cold.exists(), 'uncertain delivery must never retry Bash')
        self.assertIn('delivery', result.stderr.lower())

    def test_cancelled_claim_is_closed_before_sending_request(self):
        self.start()
        self.ready()
        spec = importlib.util.spec_from_file_location('guard_capacity_test', SCRIPTS / 'channel-guard.py')
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        guard.cancelled = signal.SIGTERM  # state when SIGTERM arrives while claim() has no held FD yet
        marker = self.root / 'cancelled-request'
        status = guard.run_warm(self.socket, self.request('touch ' + shlex.quote(str(marker))))
        self.assertEqual(status, 128 + signal.SIGTERM)
        self.assertFalse(marker.exists())

    def test_idle_reserve_ages_each_ready_channel_and_keeps_handed_job(self):
        self.start(RH_WARM_MIN='1', RH_WARM_IDLE='5')
        self.ready(1)
        live = self.warm.claim(self.socket)
        self.assertIsNotNone(live)
        self.assertIsNone(self.warm.claim(self.socket))  # demand grows reserve to its bounded target
        started = self.project / 'job-started'
        release = self.project / 'job-release'
        held_command = 'touch job-started; while [ ! -e job-release ]; do sleep .05; done; printf alive'
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            running = executor.submit(self.run_claim, live, held_command)
            try:
                self.wait_for(started.exists)
                self.ready(2)
                # Channel age remains a real-clock integration check. A deterministic clock would
                # require refactoring the broker loop; keep that separate from fixture cleanup.
                time.sleep(4)
                fresh = self.warm.claim(self.socket)
                self.assertIsNotNone(fresh)
                self.assertEqual(self.run_claim(fresh, 'exit 0'), (0, b'', b''))
                self.ready(2)
                self.wait_for(lambda: self.stats().get('ready') == 1, timeout=3)
                counts = self.stats()
                self.assertEqual(counts['target'], 1)
                self.assertEqual(counts['handed'], 1)
                self.assertFalse(running.done())
            finally:
                release.touch()
            self.assertEqual(running.result(timeout=4), (0, b'alive', b''))

    def test_acknowledged_failure_is_not_retried(self):
        self.start('acked-drop')
        self.ready()
        marker = self.root / 'once'
        cold = self.root / 'cold'
        result = subprocess.run(['python3', str(SCRIPTS / 'channel-guard.py'), '--warm', self.socket,
                                 '--warm-request', self.request('printf x >> ' + shlex.quote(str(marker))),
                                 '--', '/bin/sh', '-c', 'touch ' + shlex.quote(str(cold))],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 255)
        self.assertEqual(marker.read_text(), 'x')
        self.assertFalse(cold.exists())

    def test_background_bypasses_real_pool_socket(self):
        self.start()
        self.ready()
        result = subprocess.run(['python3', str(SCRIPTS / 'channel-guard.py'), '--background',
                                 '--slots-dir', str(self.root / 'slots'), '--warm', self.socket,
                                 '--warm-request', self.request('exit 33'), '--', '/bin/sh', '-c', 'exit 19'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(self.stats()['handed'], 0)
        self.assertEqual(self.stats()['ready'], 2)

    def test_pool_shutdown_drains_live_handed_command(self):
        self.start()
        self.ready()
        held = self.warm.claim(self.socket)
        self.assertIsNotNone(held)
        marker = self.root / 'started'
        release = self.root / 'release'
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            result = executor.submit(self.run_claim, held,
                                     'touch ' + shlex.quote(str(marker)) + '; while [ ! -e '
                                     + shlex.quote(str(release)) + ' ]; do sleep .01; done; printf survived')
            try:
                self.wait_for(marker.exists)
                self.pool.terminate()
                self.wait_for(lambda: 'warm pool draining handed channels' in self.log())
                self.assertIsNone(self.pool.poll())
                self.assertFalse(result.done(), 'shutdown must wait for the handed command')
            finally:
                release.touch()
            self.assertEqual(result.result(timeout=4), (0, b'survived', b''))
        self.pool.wait(timeout=4)
        self.assertEqual(self.pool.returncode, 0)


if __name__ == '__main__':
    unittest.main()
