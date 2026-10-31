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


def encoded(value):
    return base64.b64encode(str(value).encode()).decode()


class ShellSnapshotTests(unittest.TestCase):
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
        self.shell = self.home / 'bin' / 'bash'
        self.shell.parent.mkdir()
        real_bash = shutil.which('bash')
        self.assertIsNotNone(real_bash)
        # Keep Bash's real capture/load behavior while excluding system/user startup files. Only
        # the fixture profile runs for -lc; ordinary -c loads no profile, just like the fast path.
        self.shell.write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ['FIXTURE_SHELL_LOG'], 'a') as out:
    out.write(json.dumps(sys.argv[1]) + '\\n')
command = sys.argv[2]
if sys.argv[1] == '-lc':
    command = '. "$HOME/.bash_profile"; ' + command
os.execv({real_bash!r}, [{real_bash!r}, '--noprofile', '--norc', '-c', command, *sys.argv[3:]])
''')
        self.shell.chmod(0o700)
        (self.home / '.bash_profile').write_text('''printf 'login\\n' >> "$FIXTURE_LOGIN_LOG"
export PROFILE_VALUE=from-profile
export OPENAI_API_KEY=profile-secret
export ANTHROPIC_API_KEY=profile-secret
fixture_function() { printf function-ok; }
umask 027
''')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RH_') and key not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.home), SHELL=str(self.shell),
                        RH_GATEWAY_SESSION_DIR=str(self.session),
                        FIXTURE_LOGIN_LOG=str(self.login_log), FIXTURE_SHELL_LOG=str(self.shell_log),
                        OPENAI_API_KEY='caller-secret', ANTHROPIC_API_KEY='caller-secret')
        self.command = ('printf "%s|" "$PROFILE_VALUE"; fixture_function; '
                        'printf "|%s|%s|%s" "$(umask)" "${OPENAI_API_KEY-unset}" '
                        '"${ANTHROPIC_API_KEY-unset}"; exit 17')

    def dispatch(self):
        result = subprocess.run(['sh', str(DISPATCHER), '--dispatch', encoded(self.project),
                                 encoded('.'), encoded(self.command)],
                                env=self.env, stdin=subprocess.DEVNULL, text=True,
                                capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, 'from-profile|function-ok|0027|unset|unset')
        self.assertEqual(result.stderr, '')
        return result

    def flags(self):
        return [json.loads(line) for line in self.shell_log.read_text().splitlines()]

    def write_snapshot(self):
        self.snapshot.write_text(f'# remote-harness shell snapshot: {self.shell}\n'
                                 f'touch {shlex.quote(str(self.rejected_marker))}\n'
                                 'export PROFILE_VALUE=from-snapshot\n'
                                 '__rh_snapshot_complete=1\n')
        self.snapshot.chmod(0o600)

    def test_captures_once_and_reuses_private_snapshot_without_credentials(self):
        self.dispatch()
        self.assertTrue(self.snapshot.is_file())
        content = self.snapshot.read_text()
        self.assertTrue(content.startswith(f'# remote-harness shell snapshot: {self.shell}\n'))
        self.assertEqual(stat.S_IMODE(self.snapshot.stat().st_mode), 0o600)
        for secret in ('caller-secret', 'profile-secret'):
            self.assertNotIn(secret, content)
        self.assertNotIn('export RH_GATEWAY_SESSION_DIR=', content)
        captured_at = self.snapshot.stat().st_mtime_ns
        self.dispatch()
        self.assertEqual(self.login_log.read_text().splitlines(), ['login'])
        self.assertEqual(self.flags().count('-lc'), 1)
        self.assertEqual(self.flags()[-1], '-c')
        self.assertEqual(self.snapshot.read_text(), content)
        self.assertEqual(self.snapshot.stat().st_mtime_ns, captured_at)

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


if __name__ == '__main__':
    unittest.main()
