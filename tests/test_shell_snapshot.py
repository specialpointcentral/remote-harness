#!/usr/bin/env python3
"""Exercise private shell snapshot capture, reuse, and fallback through real dispatch."""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / 'scripts' / 'run-on-project-host.sh'
METADATA_VARS = ('SSH_CLIENT', 'SSH_CONNECTION', 'SSH_TTY', 'SSH_ORIGINAL_COMMAND',
                 'RH_GATEWAY_SESSION_DIR', 'HOSTNAME', 'HOST')


def encoded(value):
    return base64.b64encode(str(value).encode()).decode()


class ShellSnapshotTests(unittest.TestCase):
    shell_name = 'bash'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-shell-snapshot-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.project = self.home / 'project'
        self.project.mkdir()
        self.session = self.home / 'session'
        self.session.mkdir(mode=0o700)
        self.snapshot = self.session / 'shell-snapshot.sh'
        self.login_log = self.home / 'profile-runs'
        self.shell_log = self.home / 'shell-runs'
        self.rejected_marker = self.home / 'rejected-snapshot-ran'
        self.shell = self.home / 'bin' / self.shell_name
        self.shell.parent.mkdir()
        real_shell = os.environ.get(f'RH_TEST_{self.shell_name.upper()}') or shutil.which(self.shell_name)
        if not real_shell:
            self.skipTest(f'{self.shell_name} is not installed')
        shell_options = ['--noprofile', '--norc'] if self.shell_name == 'bash' else ['-f']
        self.profile = self.home / ('.bash_profile' if self.shell_name == 'bash' else '.zprofile')
        # Keep the shell's real capture/load behavior while excluding user startup files. Only
        # the fixture profile runs for -lc; ordinary -c loads no profile, just like the fast path.
        self.shell.write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ['FIXTURE_SHELL_LOG'], 'a') as out:
    out.write(json.dumps({{'flag': sys.argv[1],
                          'metadata': {{key: os.environ.get(key) for key in {METADATA_VARS!r}}}}}) + '\\n')
command = sys.argv[2]
if sys.argv[1] == '-lc':
    command = '. "$HOME/{self.profile.name}"; ' + command
os.execv({real_shell!r}, [{real_shell!r}, *{shell_options!r}, '-c', command, *sys.argv[3:]])
''')
        self.shell.chmod(0o700)
        self.profile.write_text('''printf 'login\\n' >> "$FIXTURE_LOGIN_LOG"
export PROFILE_VALUE=from-profile
export PATH="$HOME/toolchain:$PATH"
export OPENAI_API_KEY=profile-secret
export ANTHROPIC_API_KEY=profile-secret
fixture_function() { printf function-ok; }
umask 027
''' + ''.join(f'export {name}=profile-metadata-{name}\n' for name in METADATA_VARS))
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RH_') and key not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.home), SHELL=str(self.shell),
                        FIXTURE_LOGIN_LOG=str(self.login_log), FIXTURE_SHELL_LOG=str(self.shell_log),
                        OPENAI_API_KEY='caller-secret', ANTHROPIC_API_KEY='caller-secret',
                        USER='fixture-user', LOGNAME='fixture-login', DEV_CONFIG='caller-config',
                        SSH_AUTH_SOCK=str(self.home / 'ssh-agent.sock'))
        self.env.update({name: f'caller-metadata-{name}' for name in METADATA_VARS})
        self.env['RH_GATEWAY_SESSION_DIR'] = str(self.session)
        self.kept_env = {name: self.env[name]
                         for name in ('HOME', 'USER', 'LOGNAME', 'SSH_AUTH_SOCK', 'DEV_CONFIG')}
        inspect_env = (f'import json, os, sys; print(json.dumps({{'
                       f'"metadata": {{key: os.environ.get(key) for key in {METADATA_VARS!r}}}, '
                       f'"shell_metadata": sys.argv[1:], '
                       f'"kept": {{key: os.environ.get(key) for key in {tuple(self.kept_env)!r}}}, '
                       f'"toolchain_path": {str(self.home / "toolchain")!r} in os.environ["PATH"].split(":"), '
                       f'"umask": os.umask(0)}}, sort_keys=True))')
        self.command = ('printf "%s|" "$PROFILE_VALUE"; fixture_function; '
                        'printf "|%s|%s\\n" "${OPENAI_API_KEY-unset}" "${ANTHROPIC_API_KEY-unset}"; '
                        f'{shlex.quote(sys.executable)} -c {shlex.quote(inspect_env)} ' +
                        ' '.join(f'"${{{name}-unset}}"' for name in (*METADATA_VARS, '__rh_unset_name')) +
                        '; printf "command-stderr\\n" >&2; exit 17')
        self.expected_stdout = 'from-profile|function-ok|unset|unset\n' + json.dumps({
            'metadata': dict.fromkeys(METADATA_VARS),
            'shell_metadata': ['unset'] * (len(METADATA_VARS) + 1), 'kept': self.kept_env,
            'toolchain_path': True, 'umask': 0o27}, sort_keys=True) + '\n'

    def dispatch(self):
        result = subprocess.run(['sh', str(DISPATCHER), '--dispatch', encoded(self.project),
                                 encoded('.'), encoded(self.command)],
                                env=self.env, stdin=subprocess.DEVNULL, text=True,
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, self.expected_stdout)
        self.assertEqual(result.stderr, 'command-stderr\n')
        return result

    def shell_runs(self):
        return [json.loads(line) for line in self.shell_log.read_text().splitlines()]

    def flags(self):
        return [run['flag'] for run in self.shell_runs()]

    def write_snapshot(self):
        self.snapshot.write_text(f'# remote-harness shell snapshot: {self.shell}\n'
                                 f'touch {shlex.quote(str(self.rejected_marker))}\n'
                                 'export PROFILE_VALUE=from-snapshot\n'
                                 '__rh_snapshot_complete=1\n')
        self.snapshot.chmod(0o600)

    def test_captures_once_and_reuses_snapshot_without_credentials_or_metadata(self):
        self.dispatch()
        self.assertTrue(self.snapshot.is_file())
        content = self.snapshot.read_text()
        self.assertTrue(content.startswith(f'# remote-harness shell snapshot: {self.shell}\n'))
        self.assertEqual(stat.S_IMODE(self.snapshot.stat().st_mode), 0o600)
        for secret in ('caller-secret', 'profile-secret'):
            self.assertNotIn(secret, content)
        for name in METADATA_VARS:
            self.assertNotIn(f'export {name}=', content)
            self.assertNotIn(f'caller-metadata-{name}', content)
            self.assertNotIn(f'profile-metadata-{name}', content)
        captured_at = self.snapshot.stat().st_mtime_ns
        self.dispatch()
        self.assertEqual(self.login_log.read_text().splitlines(), ['login'])
        self.assertEqual(self.flags().count('-lc'), 1)
        self.assertEqual(self.flags()[-1], '-c')
        self.assertEqual(self.snapshot.read_text(), content)
        self.assertEqual(self.snapshot.stat().st_mtime_ns, captured_at)
        # Inspect the actual process boundary before the fixture starts the shell or a login profile.
        for run in self.shell_runs():
            self.assertEqual(run['metadata'], dict.fromkeys(METADATA_VARS))

    def test_snapshot_load_cannot_reintroduce_metadata(self):
        self.dispatch()
        content = self.snapshot.read_text()
        exports = ''.join(f'export {name}=old-snapshot-metadata-{name}\n' for name in METADATA_VARS)
        self.snapshot.write_text(content.replace('__rh_snapshot_complete=1\n',
                                                 exports + '__rh_snapshot_complete=1\n'))
        self.dispatch()
        self.assertEqual(self.login_log.read_text().splitlines(), ['login'])
        self.assertEqual(self.flags()[-1], '-c')

    def test_writable_snapshot_falls_back_when_another_capture_holds_the_lock(self):
        self.write_snapshot()
        self.snapshot.chmod(0o666)
        # A live capture owns this fresh lock, so an unusable snapshot must fall back immediately.
        (self.session / 'shell-snapshot.lock').mkdir(mode=0o700)
        self.dispatch()
        self.assertFalse(self.rejected_marker.exists())
        self.assertEqual(self.flags(), ['-lc'])
        self.assertEqual(self.login_log.read_text().splitlines(), ['login'])

    def test_disabled_snapshot_uses_login_profile_without_loading_snapshot(self):
        self.write_snapshot()
        original = self.snapshot.read_text()
        (self.session / 'shell-snapshot.off').touch()
        self.dispatch()
        self.assertFalse(self.rejected_marker.exists())
        self.assertEqual(self.flags(), ['-lc'])
        self.assertEqual(self.snapshot.read_text(), original)
        self.assertEqual(self.login_log.read_text().splitlines(), ['login'])

    def test_readonly_profile_metadata_fails_cleanly_before_command(self):
        with self.profile.open('a') as profile:
            profile.write('readonly HOSTNAME\n')
        for snapshot_disabled in (False, True):
            with self.subTest(snapshot_disabled=snapshot_disabled):
                if snapshot_disabled:
                    (self.session / 'shell-snapshot.off').touch()
                result = subprocess.run(['sh', str(DISPATCHER), '--dispatch', encoded(self.project),
                                         encoded('.'), encoded('printf command-ran')],
                                        env=self.env, stdin=subprocess.DEVNULL, text=True,
                                        capture_output=True, timeout=8)
                self.assertEqual(result.returncode, 125)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, 'remote-harness: category=environment exit=125 session=unknown\n')
                self.assertFalse(self.snapshot.exists())

    def test_without_session_snapshot_uses_clean_login_environment(self):
        self.env.pop('RH_GATEWAY_SESSION_DIR')
        self.dispatch()
        self.assertEqual(self.flags(), ['-lc'])
        self.assertFalse(self.snapshot.exists())

    def test_profile_nounset_preserves_clean_command_environment(self):
        with self.profile.open('a') as profile:
            profile.write('set -u\n')
        self.dispatch()

    def test_direct_git_helper_receives_developer_environment_without_metadata(self):
        if not shutil.which('git'):
            self.skipTest('git is not installed')
        helper = self.home / '.local' / 'bin' / 'git-rh-metadata'
        helper.parent.mkdir(parents=True)
        helper.write_text(f'''#!{sys.executable}
import json, os, sys
print(json.dumps({{'metadata': {{key: os.environ.get(key) for key in {METADATA_VARS!r}}},
                  'kept': {{key: os.environ.get(key) for key in {tuple(self.kept_env)!r}}},
                  'credentials': {{key: os.environ.get(key) for key in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY')}}}},
                 sort_keys=True))
sys.stderr.write('tool-stderr\\n')
sys.exit(23)
''')
        helper.chmod(0o700)
        result = subprocess.run(['sh', str(DISPATCHER), '--dispatch-tool', encoded(self.project),
                                 encoded('.'), 'git', encoded('xrh-metadata')],
                                env=self.env, stdin=subprocess.DEVNULL, text=True,
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(result.stdout, json.dumps({
            'metadata': dict.fromkeys(METADATA_VARS), 'kept': self.kept_env,
            'credentials': {'OPENAI_API_KEY': None, 'ANTHROPIC_API_KEY': None}},
            sort_keys=True) + '\n')
        self.assertEqual(result.stderr, 'tool-stderr\n')
        self.assertFalse(self.shell_log.exists(), 'direct tooling must not start a profile shell')


class ZshShellSnapshotTests(ShellSnapshotTests):
    shell_name = 'zsh'


if __name__ == '__main__':
    unittest.main()
