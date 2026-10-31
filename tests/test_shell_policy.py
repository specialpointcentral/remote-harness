#!/usr/bin/env python3
"""Check that the hook and dispatcher distinguish shell code from quoted/heredoc data."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / 'scripts/run-on-project-host.sh'
ROUTER = ROOT / 'scripts/route-command.py'


def encoded(value):
    return base64.b64encode(str(value).encode()).decode()


class ShellPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-shell-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.runner = self.path / 'runner'
        self.runner.write_text('#!/bin/sh\nexit 0\n')
        self.runner.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RH_') and key not in ('BASH_ENV', 'ENV')}
        self.env.update(SHELL='/bin/sh', HOME=str(self.path))
        self.started = self.path / 'agent-started'
        self.agent = self.path / 'codex'
        self.agent.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(self.started)) + '\n')
        self.agent.chmod(0o700)

    def route(self, command):
        event = {'tool_name': 'Bash', 'cwd': str(self.path),
                 'tool_input': {'command': command, 'timeout_ms': 123}}
        result = subprocess.run(['python3', str(ROUTER), '--runner', str(self.runner),
                                 '--mount-root', str(self.path)], input=json.dumps(event),
                                text=True, capture_output=True, check=True, env=self.env)
        return json.loads(result.stdout)['hookSpecificOutput']

    def dispatch(self, command):
        return subprocess.run(['sh', str(DISPATCHER), '--dispatch', encoded(self.path),
                               encoded('.'), encoded(command)], stdin=subprocess.DEVNULL,
                              text=True, capture_output=True, timeout=5, env=self.env)

    def assert_allowed(self, command, output):
        hook = self.route(command)
        self.assertEqual(hook['permissionDecision'], 'allow', hook)
        updated = hook['updatedInput']
        self.assertEqual(updated['timeout_ms'], 123)
        self.assertEqual(base64.b64decode(shlex.split(updated['command'])[-1]).decode(), command)
        result = self.dispatch(command)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, output)
        self.assertFalse(self.started.exists())

    def assert_denied(self, command):
        hook = self.route(command)
        self.assertEqual(hook['permissionDecision'], 'deny', hook)
        result = self.dispatch(command)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('Agent processes must run on the remote', result.stderr)
        self.assertFalse(self.started.exists())

    def use_bash(self):
        real_bash = shutil.which('bash')
        self.assertIsNotNone(real_bash)
        shell = self.path / 'bash'
        shell.write_text('#!/bin/sh\nexec ' + shlex.quote(real_bash)
                         + ' --noprofile --norc "$@"\n')
        shell.chmod(0o700)
        self.env['SHELL'] = str(shell)

    def assert_bash_matches(self, command):
        self.assertEqual(self.route(command)['permissionDecision'], 'allow')
        direct = subprocess.run([self.env['SHELL'], '-lc', command], cwd=self.path,
                                env=self.env, stdin=subprocess.DEVNULL,
                                text=True, capture_output=True, timeout=5)
        result = self.dispatch(command)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (direct.returncode, direct.stdout, direct.stderr))
        self.assertFalse(self.started.exists())

    def test_quoted_arguments_and_comments_are_data(self):
        command = "printf '%s\\n' 'claude --help' \"codex exec demo\" 'text; opencode run' # codex\n"
        self.assert_allowed(command, 'claude --help\ncodex exec demo\ntext; opencode run\n')

    def test_ansi_c_quoted_arguments_are_literal_data(self):
        self.use_bash()
        command = (r'''printf '%s\n' $'it\'s' $'back\\slash' $'\"quote\"' '''
                   r'''$'$(codex); `opencode`' $'line\nnext\tend' ''')
        self.assert_allowed(command, 'it\'s\nback\\slash\n"quote"\n$(codex); `opencode`\nline\nnext\tend\n')

    def test_ansi_c_quoted_agent_names_are_denied(self):
        for command in ("$'codex'", "co$'dex'", "command $'co'dex",
                        "$'" + str(self.agent) + "'"):
            with self.subTest(command=command):
                self.assert_denied(command)

    def test_ansi_c_encoded_command_names_fail_closed(self):
        for command in (r"$'\x63odex'", r"$'\143odex'", r"$'co\u0064ex'",
                        r"$'co\U00000064ex'", r"$'co\cDex'", r"co$'\0X='dex",
                        r"$'\x63'$(printf '')odex", r"env $'\055u' X true",
                        r"exec $'\x63odex'", r"sudo -u user $'\x63odex'",
                        r"exec -a name $'\x63odex'", r"sudo --user user $'\x63odex'",
                        r"sudo --group group $'\x63odex'", r"sudo --chdir /tmp $'\x63odex'",
                        r"env -u $'\x58' $'\x63odex'"):
            with self.subTest(command=command):
                self.assertEqual(self.route(command)['permissionDecision'], 'deny')
                result = self.dispatch(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn('could not safely parse', result.stderr)
                self.assertFalse(self.started.exists())

    def test_ansi_c_encoded_data_preserves_bash_behavior(self):
        self.use_bash()
        for command in (r"printf $'\033[1mbold\033[0m'", r"echo $'\x1b[31m'",
                        r"sort -t $'\0'", r'''value=$'\u00e9\0ignored'; printf '%s' "$value"''',
                        r"printf value >$'\x64ata'; cat data",
                        r"printf '%s' $'\x1b'$(printf nested)$'\033[0m'",
                        r'''printf '%s' "$(printf '%s' $'\033nested')"''',
                        r"env -u $'\x58' printf '%s' $'\x1b'",
                        r"exec -a $'\x6eame' printf '%s' $'\x1b'",
                        r"printf '%s' $'\033'; printf done",
                        r"$(printf '%s' $'\x70')rintf '%s' nested",
                        r"printf '%s' $'\q; $(codex)'"):
            with self.subTest(command=command):
                self.assert_bash_matches(command)

    def test_ansi_c_data_does_not_hide_following_commands(self):
        for prefix in (r"printf '%s' $'\033[0m'; ", r"value=$'\0ignored' ",
                       r"printf value >$'\x64ata'; ", r"sudo -u $'env' ",
                       r"env -u $'\x58' "):
            with self.subTest(prefix=prefix):
                self.assert_denied(prefix + shlex.quote(str(self.agent)))
        self.assert_denied("printf '%s' $'\\033'\"$(" + shlex.quote(str(self.agent)) + ')"')

    def test_ansi_c_encoded_heredoc_delimiters_fail_closed(self):
        # The checker must know the actual delimiter to distinguish its body from later code.
        command = r"cat <<$'\x45OF'" + '\ntext\nEOF\n'
        self.assertEqual(self.route(command)['permissionDecision'], 'deny')
        result = self.dispatch(command)
        self.assertEqual(result.returncode, 2)
        self.assertIn('could not safely parse', result.stderr)

    def test_quoted_heredoc_accepts_apostrophes_and_literal_agent_names(self):
        body = "can't do this\nclaude -p example\ncodex exec example\nopencode run\n"
        self.assert_allowed("cat <<'EOF'\n" + body + 'EOF\n', body)

    def test_real_command_after_heredoc_is_checked(self):
        self.assert_denied("cat <<'EOF'\ncan't run this\nEOF\n" + shlex.quote(str(self.agent)))

    def test_queued_quoted_delimiters_and_tab_stripping(self):
        self.assert_allowed('cat <<\'ONE\' <<-"TWO"; printf suffix\n'
                            "first document's text\nONE\n\tcan't run codex\n\tTWO\n",
                            "can't run codex\nsuffix")

    def test_unquoted_heredoc_names_are_data_but_substitutions_are_code(self):
        self.assert_allowed('cat <<EOF\ncodex exec example\nEOF\n', 'codex exec example\n')
        self.assert_denied('cat <<EOF\n$(' + shlex.quote(str(self.agent)) + ')\nEOF\n')

    def test_escaped_delimiter_keeps_substitution_literal(self):
        body = '$(' + str(self.agent) + ')\n'
        self.assert_allowed('cat <<\\EOF\n' + body + 'EOF\n', body)

    def test_direct_quoted_path_wrapper_and_separated_launches_are_denied(self):
        for command in ('claude -p example', 'env TEST=1 opencode run',
                        shlex.quote(str(self.agent)) + ' exec example',
                        '"' + str(self.agent) + '" exec example',
                        'command -- ' + shlex.quote(str(self.agent)),
                        'sudo -u someone ' + shlex.quote(str(self.agent)),
                        'printf safe; ' + shlex.quote(str(self.agent)),
                        'printf safe\n' + shlex.quote(str(self.agent)),
                        '2>/dev/null ' + shlex.quote(str(self.agent))):
            with self.subTest(command=command):
                self.assert_denied(command)

    def test_substitutions_are_checked_inside_double_quotes_and_process_substitutions(self):
        for command in ('printf "%s" "$(' + shlex.quote(str(self.agent)) + ')"',
                        'printf "%s" `' + shlex.quote(str(self.agent)) + '`',
                        'cat <(' + shlex.quote(str(self.agent)) + ')'):
            with self.subTest(command=command):
                self.assert_denied(command)

    def test_arithmetic_words_are_data_and_nested_commands_are_checked(self):
        self.assert_allowed('codex=2; printf "%s|%s" "$((1 + 2))" "$((codex + 1))"', '3|3')
        self.assert_allowed('codex=2; cat <<EOF\n$((codex + 1))\nEOF\n', '3\n')
        self.assert_denied('printf "%s" "$((1 + $(' + shlex.quote(str(self.agent)) + ')))"')

    def test_hook_fails_closed_when_policy_check_times_out(self):
        spec = importlib.util.spec_from_file_location('route_command_policy_test', ROUTER)
        router = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(router)
        event = {'tool_name': 'Bash', 'cwd': str(self.path), 'tool_input': {'command': 'true'}}
        output = io.StringIO()
        with mock.patch.object(router.subprocess, 'run', side_effect=subprocess.TimeoutExpired('check', 10)) as check:
            with mock.patch.object(router.sys, 'stdin', io.StringIO(json.dumps(event))), \
                 mock.patch.object(router.sys, 'argv', [str(ROUTER), '--runner', str(self.runner),
                                                       '--mount-root', str(self.path)]), \
                 contextlib.redirect_stdout(output):
                self.assertEqual(router.main(), 0)
        self.assertEqual(json.loads(output.getvalue())['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertGreater(check.call_args.kwargs['timeout'], 0)
        self.assertLessEqual(check.call_args.kwargs['timeout'], 10)

    def test_incomplete_quotes_and_heredocs_fail_closed(self):
        for command in ('printf "unterminated', "printf $'unterminated", "printf $'escaped\\'",
                        "cat <<'EOF'\ntext\n", 'printf x \\'):
            with self.subTest(command=command):
                self.assertEqual(self.route(command)['permissionDecision'], 'deny')
                result = self.dispatch(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn('could not safely parse', result.stderr)

    def test_hook_check_only_does_not_execute_commands(self):
        command = 'touch ' + shlex.quote(str(self.started))
        self.assertEqual(self.route(command)['permissionDecision'], 'allow')
        self.assertFalse(self.started.exists())
        result = subprocess.run(['sh', str(DISPATCHER), '--check-command'], input=command,
                                text=True, capture_output=True, check=True, env=self.env)
        self.assertEqual(result.stdout, '')
        self.assertFalse(self.started.exists())

    def test_nested_shell_still_hits_the_path_guard(self):
        command = "sh -c 'codex exec example'"
        self.assertEqual(self.route(command)['permissionDecision'], 'allow')
        result = self.dispatch(command)
        self.assertEqual(result.returncode, 126)
        self.assertIn('Agent processes must run on the remote', result.stderr)
        self.assertFalse(self.started.exists())


if __name__ == '__main__':
    unittest.main()
