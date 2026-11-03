#!/usr/bin/env python3
"""Keep project-host identifiers out of agent instructions while preserving routing."""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INJECT = ROOT / 'scripts' / 'inject-rule.sh'


class RulePrivacyTests(unittest.TestCase):
    def test_agent_instruction_channels_omit_host_details_and_keep_runtime_routing(self):
        with tempfile.TemporaryDirectory(prefix='rh-rule-privacy-') as temporary:
            home = Path(temporary)
            mount = home / 'mount'
            (mount / 'packages' / 'api').mkdir(parents=True)
            (mount / 'package.json').write_text('{}\n')
            project_root = "/home/host-path-private-4f62/project 'quoted'"
            alias = 'host-alias-private-4f62'
            config = home / "ssh config 'quoted'" / 'ssh_config'
            config.parent.mkdir()
            config.write_text(f'Host {alias}\n HostName 127.0.0.1\n')
            fake_bin = home / 'fake-bin'
            fake_bin.mkdir()
            ssh_log = home / 'ssh.jsonl'
            ssh = fake_bin / 'ssh'
            ssh.write_text(f'''#!{sys.executable}
import json, os, sys
with open(os.environ['SSH_TEST_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
print('project-host-routed')
sys.exit(23)
''')
            ssh.chmod(0o700)
            # inject-rule reads the opencode version to pick its plugin format.
            (fake_bin / 'opencode').write_text('#!/bin/sh\necho 1.19.5\n')
            (fake_bin / 'opencode').chmod(0o700)
            env = {name: value for name, value in os.environ.items()
                   if not name.startswith('RH_') and name not in ('BASH_ENV', 'ENV')}
            env.update(HOME=str(home), RH_HOME=str(home / 'rh'), RH_WARM_MAX='0',
                       PATH=str(fake_bin) + ':' + env['PATH'], SSH_TEST_LOG=str(ssh_log))

            for agent in ('codex', 'claude', 'opencode'):
                with self.subTest(agent=agent):
                    result = subprocess.run(
                        [str(INJECT), 'on', agent, project_root, alias, str(mount), 'normal',
                         str(config), f'privacy.{agent}'], env=env, text=True,
                        capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    output = dict(line.split('=', 1) for line in result.stdout.splitlines())
                    self.assertEqual(output['RH_STATUS'], 'INJECTED')
                    session = Path(output['RH_SESSION_DIR'])
                    rule = (session / 'rule.md').read_text()
                    flags = shlex.split(output['RH_LAUNCH_FLAGS'])
                    if agent == 'codex':
                        developer = next(flag.split('=', 1)[1] for flag in flags
                                         if flag.startswith('developer_instructions='))
                        instructions = json.loads(developer)
                        self.assertEqual(instructions, rule.rstrip('\n'))
                    elif agent == 'claude':
                        path = Path(flags[flags.index('--append-system-prompt-file') + 1])
                        self.assertEqual(path, session / 'rule.md')
                        instructions = path.read_text()
                    else:
                        config_entry = next(entry for entry in shlex.split(output['RH_LAUNCH_ENV'])
                                            if entry.startswith('OPENCODE_CONFIG='))
                        agent_config = json.loads(Path(config_entry.split('=', 1)[1]).read_text())
                        self.assertEqual(agent_config['instructions'], [str(session / 'rule.md')])
                        instructions = Path(agent_config['instructions'][0]).read_text()

                    for private_value in (project_root, alias, str(mount)):
                        self.assertNotIn(private_value, instructions)
                    guidance = ' '.join(instructions.split())
                    for required in ('SSHFS mount', 'File tools edit the mount',
                                     'Run ordinary relative commands',
                                     'do not wrap them in `ssh` or bypass the router',
                                     'Commands get no stdin', 'no PTY', 'kills its process tree',
                                     'project host is unreachable', 'do not retry against the mount',
                                     'never work around it by running the project command on this machine',
                                     'npm test'):
                        self.assertIn(required, guidance)
                    # Claude's session settings deny reading the session directories, logs included.
                    self.assertIn('This session cannot read them' if agent == 'claude' else
                                  'Read those logs only when the user explicitly asks for detailed diagnostics',
                                  guidance)
                    if agent == 'claude':
                        for required in ('Ordinary and nested subagents work',
                                         'Do not use Agent Teams or Agent `isolation: worktree`',
                                         'separate remote-harness session for isolated parallel work'):
                            self.assertIn(required, guidance)

                    # Execute the generated runner, including its SSH wrapper, without a network.
                    # Private host values must still reach the encoded gateway request unchanged.
                    # The hooks and the opencode plugin write the readable form.
                    routed_env = dict(env, PATH=str(session / 'bin') + ':' + env['PATH'])
                    command = "printf 'routing preserved'"
                    routed = subprocess.run([str(session / 'bin' / 'rh-run'), '--cwd', 'packages/api', '--',
                                             command],
                                            env=routed_env, text=True, capture_output=True, timeout=8)
                    self.assertEqual(routed.returncode, 23, routed.stderr)
                    self.assertEqual(routed.stdout, 'project-host-routed\n')
                    ssh_arguments = json.loads(ssh_log.read_text().splitlines()[-1])
                    self.assertEqual(ssh_arguments[ssh_arguments.index('-F') + 1], str(config))
                    self.assertEqual(ssh_arguments[-2], alias)
                    request = ssh_arguments[-1].split()
                    self.assertEqual(request[0], 'remote-harness-exec')
                    self.assertEqual([base64.b64decode(value).decode() for value in request[1:4]],
                                     [project_root, 'packages/api', command])
                    self.assertEqual(request[4:], ['watch'])


if __name__ == '__main__':
    unittest.main()
