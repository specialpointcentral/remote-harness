#!/usr/bin/env python3
"""The agent judges the original command, not rh-run.

The Claude hook applies the user's own Bash rules to it; Codex reads it after an unreachable exit.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROUTER = ROOT / 'scripts/route-command.py'
DISPATCHER = ROOT / 'scripts/run-on-project-host.sh'


class PermissionRuleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='rh-permission-rules-')
        self.addCleanup(temporary.cleanup)
        base = Path(os.path.realpath(temporary.name))
        self.home, self.mount = base / 'home', base / 'mount'
        self.session = base / 'session'
        (self.session / 'bin').mkdir(parents=True)
        self.runner = self.session / 'bin' / 'rh-run'
        self.runner.write_text('#!/bin/sh\nexit 0\n')
        self.runner.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('RH_', 'CLAUDE_')) and key not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.home), CLAUDE_PROJECT_DIR=str(self.mount))
        self.write(self.home / '.claude/settings.json', json.dumps({'permissions': {
            'allow': ['Bash(npm test:*)', 'Bash(git status)', 'Read(*)'], 'deny': ['Bash(rm:*)']}}))
        self.write(self.mount / '.claude/settings.local.json',
                   json.dumps({'permissions': {'ask': ['Bash(git push *)']}}))

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def hook(self, agent, command, **extra):
        event = {'tool_name': 'Bash', 'cwd': str(self.mount), 'tool_input': {'command': command}}
        event['tool_input'].update(extra.pop('tool_input', {}))
        event.update(extra)
        result = subprocess.run(['python3', str(ROUTER), '--runner', str(self.runner), '--mount-root',
                                 str(self.mount), '--agent', agent], input=json.dumps(event),
                                text=True, capture_output=True, check=True, env=self.env)
        return json.loads(result.stdout)['hookSpecificOutput']

    def claude(self, command, mode='default'):
        specific = self.hook('claude', command, permission_mode=mode)
        return specific.get('permissionDecision'), specific.get('permissionDecisionReason', '')

    def test_lexer_lists_each_simple_command_from_its_command_word(self):
        command = 'cd a && sudo -u root rm -rf "x\ty"; echo $(git push) `ls`\ncat <<\'EOF\'\nrm body\nEOF\n'
        result = subprocess.run(['sh', str(DISPATCHER), '--check-command', '--words'], input=command,
                                text=True, capture_output=True, check=True, env=self.env)
        self.assertEqual(result.stdout.split('\n'), [
            'cd\ta', 'rm\t-rf\tx\\ty', 'git\tpush', 'ls', 'echo\t$()\t$()', 'cat', ''])

    def test_claude_deny_and_ask_rules_match_any_command_in_every_mode(self):
        for mode in ('default', 'auto', 'bypassPermissions'):
            for command in ('npm test && rm -rf x', 'echo $(rm -f a)', 'sudo -u root /bin/rm -rf b'):
                with self.subTest(mode=mode, command=command):
                    self.assertEqual(self.claude(command, mode), (
                        'deny', 'remote-harness: the permission rule Bash(rm:*) denies this command'))
            specific = self.hook('claude', 'git push origin main', permission_mode=mode)
            self.assertEqual(specific['permissionDecision'], 'ask')
            self.assertIn('--cwd . -- \'git push origin main\'', specific['updatedInput']['command'])
        # Data is not a command: a literal here-document body or an argument never matches.
        self.assertEqual(self.claude("cat <<'EOF'\nrm -rf x\nEOF"), (None, ''))
        self.assertEqual(self.claude('echo rm -rf x'), (None, ''))

    def test_claude_allow_rules_take_plain_commands_in_modes_without_a_classifier(self):
        allowed = ('allow', 'remote-harness: allowed by the permission rule Bash(npm test:*)')
        for mode in ('default', 'acceptEdits', 'dontAsk'):
            self.assertEqual(self.claude('npm test -- --watch', mode), allowed)
        self.assertEqual(self.claude('git status')[0], 'allow')
        # Auto mode drops broad allow rules before its classifier runs; only Claude can judge that.
        for mode in ('auto', 'plan', 'bypassPermissions', None):
            self.assertEqual(self.claude('npm test', mode), (None, ''))
        for command in ('npm testing', 'git status -s', 'npm test > out', 'npm test | tee log', 'npm test $HOME',
                        "npm test '$HOME'", 'npm test *.js', '/tmp/x/npm test', 'FOO=1 npm test',
                        'sudo npm test'):
            with self.subTest(command=command):
                self.assertEqual(self.claude(command), (None, ''))

    def test_rule_changes_apply_without_rereading_unchanged_files(self):
        self.assertEqual(self.claude('make lint')[0], None)
        cache = self.session / 'claude-rules.json'
        self.assertTrue(cache.is_file())
        self.write(self.mount / '.claude/settings.local.json',
                   json.dumps({'permissions': {'allow': ['Bash(make lint)']}}))
        self.assertEqual(self.claude('make lint')[0], 'allow')
        # An unchanged identity reuses the cached rules without opening the settings files.
        stored = json.loads(cache.read_text())
        stored['rules']['deny'].append('Bash(make:*)')
        cache.write_text(json.dumps(stored))
        self.assertEqual(self.claude('make lint')[0], 'deny')

    def test_codex_reads_the_original_after_an_exit_its_shell_never_reaches(self):
        specific = self.hook('codex', 'rm -rf build')
        self.assertEqual(specific['permissionDecision'], 'allow')
        self.assertEqual(specific['updatedInput']['command'],
                         shlex.quote(str(self.runner)) + " --cwd . -- 'rm -rf build'; exit\nrm -rf build")
        # Only the runner runs, and its status is the command's. The shell stops before parsing the
        # second line, so neither its side effects nor syntax it cannot parse reach it.
        self.runner.write_text('#!/bin/sh\nprintf "%s|" "$@"\nexit 7\n')
        marker = self.mount / 'tail-ran'
        command = f'touch {marker}\nfor f (*.txt) echo $f'
        rewritten = self.hook('codex', command)['updatedInput']['command']
        for shell in ('bash', 'sh'):
            with self.subTest(shell=shell):
                result = subprocess.run([shell, '-c', rewritten], text=True, capture_output=True,
                                        cwd=self.mount, env=self.env)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (7, f'--cwd|.|--|{command}|', ''))
                self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
