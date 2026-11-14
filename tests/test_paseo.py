#!/usr/bin/env python3
"""Exercise the reverse launcher and generated Claude settings at the Paseo SDK boundary."""
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

from test_claude_hooks import CLAUDE, ClaudeSessionFixture, ModelFixture

ROOT = Path(__file__).resolve().parents[1]
# tests/verify-orca-version.sh points the native UI tests at a copy that also lists a candidate build.
SCRIPTS = Path(os.environ.get('RH_TEST_SCRIPTS') or ROOT / 'scripts')


class PaseoFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='rh-paseo-')
        self.addCleanup(temporary.cleanup)
        # Match the physical paths used by the injector and lease checks (macOS /var is a symlink).
        self.home = Path(temporary.name).resolve()
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith('RH_') and k not in ('BASH_ENV', 'ENV')}
        self.rh = self.home / 'harness'
        self.env.update(HOME=str(self.home), RH_HOME=str(self.rh),
                        PATH=str(self.bin) + os.pathsep + self.env['PATH'])

    def script(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o700)
        return path


class PaseoOptionTests(PaseoFixture):
    def test_public_bootstrap_passes_native_ui_through_reverse_wizard(self):
        local = self.home / 'local'
        local.mkdir()
        for name in ('simple-bootstrap.sh', 'simple-dispatch.sh', 'simple-laptop-setup.sh', '_common.sh'):
            shutil.copy2(SCRIPTS / name, local)
        self.script('ssh', "printf 'PORT=27678\\nCONFIG=/remote/ssh_config\\n'\n")
        shutil.copy2(self.script('record', 'printf "%s\\n" "$@" > "$HOME/launch"\n'),
                     local / 'laptop-setup.sh')
        self.env.update(RH_SIMPLE_CACHE=str(self.home / 'cache'), RH_LOCAL_SSHD='system')
        result = subprocess.run(
            ['bash', str(local / 'simple-bootstrap.sh'), '--mode', 'reverse', '--via', 'testbox',
             '--launch', 'claude', '--ui', 'paseo', '--approval', 'normal'],
            cwd=self.home, input='\ny\n', env=self.env, text=True, capture_output=True,
            timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        launch = (self.home / 'launch').read_text().splitlines()
        self.assertEqual(launch[launch.index('--ui') + 1], 'paseo')

    def test_native_ui_rejects_other_providers_before_setup(self):
        self.script('ssh', 'touch "$HOME/ssh-ran"\nexit 1\n')
        for name in ('simple-bootstrap.sh', 'simple-dispatch.sh',
                     'simple-laptop-setup.sh', 'laptop-setup.sh'):
            with self.subTest(name=name):
                args = ['--port', '27678'] if name == 'laptop-setup.sh' else []
                result = subprocess.run(
                    ['bash', str(SCRIPTS / name), *args, '--launch', 'opencode', '--ui', 'paseo'],
                    env=self.env, text=True, input='', capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                # Either check refuses it first: opencode is no longer supported at all.
                self.assertRegex(result.stderr, r'no longer supports opencode|--ui paseo requires --launch claude or codex')
                self.assertFalse((self.home / 'ssh-ran').exists())


class NativeWorkspaceTests(PaseoFixture):
    def setUp(self):
        super().setUp()
        shutil.copytree(SCRIPTS, self.rh / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        self.marker = self.home / 'agent-started'
        cli = self.script('agent', '''if [ "$1" = --version ]; then
  echo '2.1.319 (Claude Code)'
else
  touch "$HOME/agent-started"
fi
''')
        for name in ('paseo/claude.json', 'orca/claude.json', 'codex.json'):
            path = self.rh / name
            path.parent.mkdir(exist_ok=True)
            path.parent.chmod(0o700)
            path.write_text(json.dumps({'codex' if name == 'codex.json' else 'claude': str(cli)}))
            path.chmod(0o600)
        self.mount = self.home / 'Harness project'
        (self.mount / 'subdir').mkdir(parents=True)
        self.reserve = [sys.executable, '-EsB', str(self.rh / 'scripts/native_workspace.py'),
                        'reserve', str(self.rh), str(self.mount)]
        subprocess.run(self.reserve, check=True, env=self.env)
        self.wrappers = ('paseo-claude.py', 'orca-claude.py', 'native-codex.py')

    def launch(self, wrapper, cwd, *args, env=None):
        return subprocess.run([sys.executable, '-EsB', str(self.rh / 'scripts' / wrapper), *args],
                              cwd=cwd, env=env or self.env, input='', text=True,
                              capture_output=True, timeout=5)

    def test_only_reserved_workspaces_reject_plain_chats(self):
        alias = self.home / 'mount-alias'
        alias.symlink_to(self.mount, target_is_directory=True)
        # Concurrent launches may reserve the same mount, without replacing its record.
        subprocess.run(self.reserve, check=True, env=self.env)
        for wrapper in self.wrappers:
            for cwd in (self.mount, self.mount / 'subdir', alias):
                with self.subTest(wrapper=wrapper, cwd=cwd):
                    result = self.launch(wrapper, cwd, 'app-server')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Open the existing Harness chat', result.stderr)
                    self.assertFalse(self.marker.exists())
        sibling = self.home / 'Harness project ordinary'
        sibling.mkdir()
        for wrapper in self.wrappers:
            result = self.launch(wrapper, sibling, 'app-server')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.marker.exists())
            self.marker.unlink()

    def test_registered_paseo_claude_requires_live_lease_and_original_settings(self):
        sys.path.insert(0, str(SCRIPTS))
        self.addCleanup(sys.path.remove, str(SCRIPTS))
        from orca_native import process_identity
        sessions = self.rh / '.sessions'
        sessions.mkdir(mode=0o700)
        session = sessions / 'bound'
        session.mkdir(mode=0o700)
        lease = session / 'paseo-lease.json'
        lease.write_text(json.dumps({'provider': 'claude', 'token': 'test', 'pid': os.getpid(),
                                    'identity': process_identity(os.getpid()),
                                    'cwd': str(self.mount), 'env': {'PATH': self.env['PATH']}}))
        lease.chmod(0o600)
        settings = session / 'paseo-claude-settings.json'
        settings.write_text('{"disableAllHooks": false}')
        settings.chmod(0o600)
        env = dict(self.env, RH_CLAUDE_SESSION=str(session), RH_CLAUDE_TOKEN='test')
        result = self.launch('paseo-claude.py', self.mount, '--settings', settings.read_text(), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.marker.unlink()
        for cwd, supplied in ((self.mount, '{}'), (self.home, settings.read_text())):
            result = self.launch('paseo-claude.py', cwd, '--settings', supplied, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.marker.exists())
        lease.unlink()
        result = self.launch('paseo-claude.py', self.mount, '--settings', settings.read_text(), env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertNotEqual(self.launch('paseo-claude.py', self.mount).returncode, 0)


@unittest.skipUnless(shutil.which('node'), 'Node.js is required for the Paseo bridge')
class PaseoBridgeTests(PaseoFixture):
    def setUp(self):
        super().setUp()
        self.project = self.home / "mount with spaces"
        self.project.mkdir()
        transport = self.rh / '.sessions' / 'transport'
        transport.mkdir(parents=True)
        self.config = transport / 'ssh_config'
        self.config.touch()
        self.script('claude', "printf '2.1.319 (Claude Code)\\n'\n")
        self.script('ssh', 'exit 1\n')
        self.env.update(RH_WARM_MAX='0', RH_HEARTBEAT_TIMEOUT='0', RH_PASEO_PASSWORD='fixture-secret',
                        ANTHROPIC_API_KEY='do-not-forward', CLAUDE_CODE_BASH_EDIT_DIFF='1')
        sdk = self.rh / 'paseo' / 'node_modules' / '@getpaseo' / 'client'
        sdk.mkdir(parents=True)
        (sdk / 'package.json').write_text(json.dumps({
            'version': '0.15.3', 'type': 'module',
            'exports': {'./internal/daemon-client': './dist/daemon-client.js'},
        }))
        (sdk / 'dist').mkdir()
        shutil.copyfile(ROOT / 'tests/fixtures/paseo-client.mjs', sdk / 'dist/daemon-client.js')
        self.state = self.home / 'state'
        self.state.mkdir()
        self.env['PASEO_TEST_STATE'] = str(self.state)

    def start_bridge(self, approval='auto'):
        result = subprocess.run(
            ['bash', str(SCRIPTS / 'inject-rule.sh'), 'on', 'claude', '/project', 'testbox',
             str(self.project), approval, str(self.config), 'test-native', 'paseo'],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in result.stdout.splitlines())
        self.assertIn('RH_PASEO_LAUNCH', values, 'injector did not supply a native bridge')
        self.session = Path(values['RH_SESSION_DIR'])
        command = ('export ' + values['RH_LAUNCH_ENV'] + '; exec '
                   + values['RH_LAUNCH_PREFIX'] + ' ' + values['RH_PASEO_LAUNCH'])
        self.log = (self.home / 'bridge.log').open('w+')
        self.addCleanup(self.log.close)
        self.bridge = subprocess.Popen(['bash', '-c', command], env=self.env, cwd=self.project,
                                       stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop_bridge)

    def stop_bridge(self):
        if self.bridge.poll() is None:
            self.bridge.kill()
            self.bridge.wait(timeout=5)

    def wait_state(self, name):
        path = self.state / name
        for _ in range(200):
            if path.exists():
                return path.read_text()
            if self.bridge.poll() is not None:
                break
            time.sleep(0.025)
        self.log.seek(0)
        self.fail(f'Bridge did not reach {name}: {self.log.read()}')

    def guard(self, tool, command):
        return subprocess.run(command, shell=True, env=self.env,
                              input=json.dumps({'tool_name': tool}), text=True,
                              capture_output=True, timeout=5)

    def test_native_agent_keeps_lease_until_archive(self):
        self.start_bridge()
        request = json.loads(self.wait_state('created'))
        owner = (self.session / 'owner.env').read_text()
        self.assertIn(f'OWNER_PID={self.bridge.pid}\n', owner)
        self.assertEqual(request['provider'], 'claude')
        self.assertEqual(request['cwd'], str(self.project.resolve()))
        self.assertEqual(request['modeId'], 'auto')
        self.assertNotIn('initialPrompt', request)
        self.assertIn('every Bash command is routed', request['systemPrompt'])
        self.assertTrue(request['env']['PATH'].startswith(str(self.session / 'bin') + ':'))
        self.assertEqual(request['env']['CLAUDE_CODE_BASH_EDIT_DIFF'], '1')
        self.assertEqual(request['env']['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'], '0')
        self.assertNotIn('ANTHROPIC_API_KEY', request['env'])
        self.assertNotIn('RH_PASEO_PASSWORD', request['env'])
        settings = json.loads(request['providerOptions']['extraArgs']['settings'])
        hooks = settings['hooks']['PreToolUse']
        routing = next(h['hooks'][0] for h in hooks if h.get('matcher') == 'Bash|Agent')
        self.assertIn('route-command.py', routing['command'])
        self.assertEqual(routing['onFailure'], 'block')
        guard = next(h['hooks'][0] for h in hooks if not h.get('matcher'))
        self.assertEqual(guard['onFailure'], 'block')
        self.assertEqual(self.guard('Read', guard['command']).returncode, 0)
        self.assertEqual(self.guard('mcp__paseo__create_agent', guard['command']).returncode, 2)
        self.wait_state('idle')
        self.assertIsNone(self.bridge.poll(), 'idle is a turn status and must retain transport')
        (self.state / 'archive-in-app').touch()
        self.assertEqual(self.bridge.wait(timeout=8), 0)
        self.assertNotEqual(self.guard('Read', guard['command']).returncode, 0)
        self.assertFalse((self.state / 'archive-called').exists())

    def test_explicit_stop_revokes_before_archiving(self):
        self.start_bridge(approval='yolo')
        request = json.loads(self.wait_state('created'))
        self.assertEqual(request['modeId'], 'bypassPermissions')
        self.bridge.terminate()
        self.assertEqual(self.bridge.wait(timeout=8), 143)  # 128 + SIGTERM, for the launcher's record
        result = json.loads((self.state / 'archive-called').read_text())
        self.assertEqual(result, {'agentId': request['agentId'], 'leaseLive': False})

    def test_crashed_bridge_cannot_grant_tools(self):
        self.start_bridge()
        request = json.loads(self.wait_state('created'))
        settings = json.loads(request['providerOptions']['extraArgs']['settings'])
        guard = next(h['hooks'][0] for h in settings['hooks']['PreToolUse'] if not h.get('matcher'))
        self.stop_bridge()
        self.assertNotEqual(self.guard('Bash', guard['command']).returncode, 0)

    def test_daemon_claude_version_is_checked_before_creation(self):
        self.env['PASEO_TEST_CLAUDE_VERSION'] = '2.1.294'
        self.start_bridge()
        self.assertNotEqual(self.bridge.wait(timeout=8), 0)
        self.assertFalse((self.state / 'created').exists())
        self.log.seek(0)
        self.assertIn('2.1.295', self.log.read())

    def test_unwrapped_provider_is_refused_before_creation(self):
        self.env['PASEO_TEST_CLAUDE_COMMAND'] = '/ordinary/claude'
        self.start_bridge()
        self.assertNotEqual(self.bridge.wait(timeout=8), 0)
        self.assertFalse((self.state / 'created').exists())
        self.log.seek(0)
        self.assertIn('paseo-claude.py', self.log.read())


PASEO_NODE_MODULES = os.environ.get('RH_TEST_PASEO_NODE_MODULES')


@unittest.skipUnless(CLAUDE and PASEO_NODE_MODULES and shutil.which('node'),
                     'set RH_TEST_CLAUDE_CLI and RH_TEST_PASEO_NODE_MODULES for the native smoke test')
class PaseoNativeRuntimeTests(ClaudeSessionFixture):
    def start_process(self, args, env, cwd, name):
        path = self.root / (name + '.log')
        with path.open('w') as log:
            process = subprocess.Popen(args, env=env, cwd=cwd, stdout=log, stderr=log,
                                       start_new_session=True)

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        self.addCleanup(stop)
        return process, path

    def wait_log(self, process, path, pattern):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            output = path.read_text()
            if match := re.search(pattern, output, re.M):
                return match[1]
            if process.poll() is not None:
                break
            time.sleep(0.1)
        self.fail(f'{path.name} did not report readiness: {path.read_text()[-3000:]}')

    def start_native(self, claude_options=None):
        sdk = Path(PASEO_NODE_MODULES).resolve(strict=True)
        dependencies = self.root / 'rh' / 'paseo'
        dependencies.mkdir(parents=True)
        (dependencies / 'node_modules').symlink_to(sdk, target_is_directory=True)
        scripts = self.root / 'rh' / 'scripts'
        shutil.copytree(SCRIPTS, scripts, ignore=shutil.ignore_patterns('__pycache__'))
        wrapper_config = dependencies / 'claude.json'
        wrapper_config.write_text(json.dumps({'claude': str(Path(CLAUDE).resolve(strict=True))}))
        wrapper_config.chmod(0o600)
        helper = self.root / 'paseo-native.mjs'
        shutil.copyfile(ROOT / 'tests' / 'fixtures' / helper.name, helper)
        (self.root / 'node_modules').symlink_to(sdk, target_is_directory=True)
        paseo_home = self.root / 'paseo'
        paseo_home.mkdir()
        (paseo_home / 'config.json').write_text(json.dumps({
            'version': 1,
            'daemon': {'listen': '127.0.0.1:0', 'relay': {'enabled': False},
                       'mcp': {'enabled': False, 'injectIntoAgents': False}},
            'agents': {'metadataGeneration': {'providers': []}, 'providers': {
                'claude': {'command': [str(scripts / 'paseo-claude.py')],
                           **({'options': claude_options} if claude_options else {})},
                **{key: {'enabled': False} for key in ('codex', 'copilot', 'opencode', 'pi', 'omp')},
            }},
        }))
        result = subprocess.run(
            [str(SCRIPTS / 'inject-rule.sh'), 'on', 'claude', str(self.project), 'fixture',
             str(self.mount), 'normal', str(self.config), 'native', 'paseo'],
            env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in result.stdout.splitlines())
        session = Path(values['RH_SESSION_DIR'])
        # Keep the real Claude hook and bridge. Replace only the transport across hosts with
        # a fixed dispatcher into a separate project directory.
        (session / 'bin/rh-run').write_text(
            '#!/bin/sh\ncd ' + shlex.quote(str(self.project)) + '\nexec sh -c "$4"\n')
        model = ThreadingHTTPServer(('127.0.0.1', 0), ModelFixture)
        model.results = []
        threading.Thread(target=model.serve_forever, daemon=True).start()
        self.addCleanup(model.server_close)
        self.addCleanup(model.shutdown)
        # Allowlist the environment so the fixture cannot use real credentials or user settings.
        env = {key: self.env[key] for key in ('HOME', 'PATH')}
        env.update(PASEO_HOME=str(paseo_home), CLAUDE_CONFIG_DIR=str(self.root / 'cli-config'),
                   ANTHROPIC_API_KEY='sk-ant-fixture-not-a-real-key',
                   ANTHROPIC_BASE_URL=f'http://127.0.0.1:{model.server_port}',
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
                   CLAUDE_CODE_AUTO_MODE_SERVER='0')
        daemon, daemon_log = self.start_process(['node', str(helper), 'serve'], env, self.root, 'daemon')
        port = self.wait_log(daemon, daemon_log, r'^(\d+)$')
        url = f'ws://127.0.0.1:{port}/ws'
        bridge_env = dict(env, RH_HOME=self.env['RH_HOME'], RH_PASEO_URL=url,
                          RH_HEARTBEAT_TIMEOUT='0', RH_PASEO_MODEL='claude-sonnet-4-6')
        command = ('export ' + values['RH_LAUNCH_ENV'] + '; exec '
                   + values['RH_LAUNCH_PREFIX'] + ' ' + values['RH_PASEO_LAUNCH'])
        bridge, bridge_log = self.start_process(['bash', '-c', command], bridge_env, self.mount, 'bridge')
        return session, helper, env, url, bridge, bridge_log, daemon_log

    def test_native_normal_approval_routes_only_to_project_host(self):
        session, helper, env, url, bridge, bridge_log, daemon_log = self.start_native()
        agent = self.wait_log(bridge, bridge_log, r'Paseo Claude agent ([\w-]+) is ready')
        driven = subprocess.run(['node', str(helper), 'drive', url, agent], env=env, cwd=self.root,
                                text=True, capture_output=True, timeout=65)
        self.assertEqual(driven.returncode, 0, (driven.stdout, driven.stderr, daemon_log.read_text()))
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertEqual((self.project / 'execution-marker').read_text(), 'executed')
        extra = subprocess.run(['node', str(helper), 'reject-extra', url, agent], env=env, cwd=self.root,
                               text=True, capture_output=True, timeout=45)
        self.assertEqual(extra.returncode, 0, (extra.stdout, extra.stderr, daemon_log.read_text()))
        self.assertFalse((self.mount / 'execution-marker').exists(),
                         'an ordinary chat ran in the Harness mount without routing')
        with self.assertRaises(subprocess.TimeoutExpired):
            bridge.wait(timeout=3)  # A completed turn and a closed mobile client leave the lease live.
        bridge.terminate()
        self.assertEqual(bridge.wait(timeout=12), 143, bridge_log.read_text())
        self.assertFalse((session / 'paseo-lease.json').exists())


    def test_native_refuses_daemon_settings_that_shadow_session_hooks(self):
        _, _, _, _, bridge, bridge_log, _ = self.start_native(
            {'settings': {'permissions': {'deny': ['Read(//proc/**)']}}})
        result = self.wait_log(bridge, bridge_log,
                               r'(options\.settings|Paseo Claude agent [\w-]+ is ready)')
        self.assertEqual(result, 'options.settings', bridge_log.read_text())
        self.assertNotEqual(bridge.wait(timeout=12), 0)


if __name__ == '__main__':
    unittest.main()
