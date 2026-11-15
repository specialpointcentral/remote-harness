#!/usr/bin/env python3
"""Session guards, plus opt-in real Claude hook execution with a loopback model fixture.

RH_TEST_CLAUDE_CLI=/absolute/path/to/claude python3 tests/test_claude_hooks.py -v
The CLI uses a temporary home, a dummy API key and a scripted local Messages endpoint. No model
or user credentials are used. Run this on the agent host, never on a user's project host.
"""
import json
import base64
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
CLAUDE = os.environ.get('RH_TEST_CLAUDE_CLI')


class ClaudeSessionFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='rh-claude-hooks-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.mount = self.root / 'agent mount'
        self.project = self.root / 'project host'
        self.bin = self.root / 'bin'
        for path in (self.mount, self.project, self.bin):
            path.mkdir()
        self.config = self.root / 'ssh_config'
        self.config.write_text('Host fixture\n HostName 127.0.0.1\n')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('RH_', 'CLAUDE_', 'ANTHROPIC_'))
                    and key not in ('BASH_ENV', 'ENV', 'CLAUDECODE')}
        self.env.update(HOME=str(self.root), RH_HOME=str(self.root / 'rh'), RH_WARM_MAX='0',
                        PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.version('2.1.295 (Claude Code)')

    def version(self, value, status=0):
        path = self.bin / 'claude'
        path.write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(value) + f'\nexit {status}\n')
        path.chmod(0o700)

    def inject(self):
        result = subprocess.run([str(ROOT / 'scripts/inject-rule.sh'), 'on', 'claude',
                                 str(self.project), 'fixture', str(self.mount), 'normal',
                                 str(self.config), 'test'], env=self.env, text=True,
                                capture_output=True, timeout=15)
        return result

    def settings(self):
        result = self.inject()
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in result.stdout.splitlines())
        self.session = Path(values['RH_SESSION_DIR'])
        return json.loads((self.session / 'claude-settings.json').read_text())


class ClaudeHookTests(ClaudeSessionFixture):
    def test_old_unknown_and_failed_versions_refused_before_session_creation(self):
        for version, status in [('2.1.294 (Claude Code)', 0), ('1.9.999', 0), ('2.0.999', 0),
                                ('unrecognized', 0), ('2.1.318', 1), ('2.1.295-beta', 0)]:
            with self.subTest(version=version, status=status):
                self.version(version, status)
                result = self.inject()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), 'RH_STATUS=ERROR')
                self.assertIn('2.1.295 or newer', result.stderr)
                self.assertFalse((self.root / 'rh' / '.sessions').exists())

    def test_supported_version_generates_fail_closed_hook_without_auto_approval(self):
        settings = self.settings()
        hook = settings['hooks']['PreToolUse'][0]['hooks'][0]
        self.assertEqual(hook['onFailure'], 'block')
        self.assertGreater(hook['timeout'], 10)
        event = {'tool_name': 'Bash', 'permission_mode': 'auto', 'cwd': str(self.mount),
                 'tool_input': {'command': 'printf hello'}}
        result = subprocess.run(shlex.split(hook['command']), input=json.dumps(event),
                                env=self.env, text=True, capture_output=True, timeout=hook['timeout'])
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)['hookSpecificOutput']
        self.assertNotIn('permissionDecision', output)
        self.assertEqual(shlex.split(output['updatedInput']['command']),
                         [str(self.session / 'bin/rh-run'), '--cwd', '.', '--', 'printf hello'])


class ModelFixture(BaseHTTPRequestHandler):
    """A fixed tool call followed by a final answer; no generated shell commands."""
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path.split('?')[0] == '/v1/messages/count_tokens':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"input_tokens": 100}')
            return
        if self.path.split('?')[0] != '/v1/messages':
            self.send_error(404)
            return
        results = [block for message in request.get('messages', [])
                   if isinstance(message.get('content'), list) for block in message['content']
                   if block.get('type') == 'tool_result' and block.get('tool_use_id', '').startswith('toolu_rh_')]
        self.server.results.extend(results)
        blocks = ([{'type': 'text', 'text': 'Fixture finished.'}] if results else
                  [{'type': 'tool_use', 'id': 'toolu_rh_1', 'name': getattr(self.server, 'tool_name', 'Bash'),
                    'input': getattr(self.server, 'tool_input', None) or {
                        'command': getattr(self.server, 'command', 'printf executed > execution-marker'),
                        'description': 'Test routing'}}])
        reason = 'end_turn' if results else 'tool_use'
        message = {'id': 'msg_rh_fixture', 'type': 'message', 'role': 'assistant',
                   'model': request['model'], 'content': [], 'stop_reason': None, 'stop_sequence': None,
                   'usage': {'input_tokens': 100, 'output_tokens': 1}}
        events = [{'type': 'message_start', 'message': message}]
        for index, block in enumerate(blocks):
            if block['type'] == 'tool_use':
                start = dict(block, input={})
                delta = {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}
            else:
                start = dict(block, text='')
                delta = {'type': 'text_delta', 'text': block['text']}
            events += [{'type': 'content_block_start', 'index': index, 'content_block': start},
                       {'type': 'content_block_delta', 'index': index, 'delta': delta},
                       {'type': 'content_block_stop', 'index': index}]
        events += [{'type': 'message_delta', 'delta': {'stop_reason': reason, 'stop_sequence': None},
                    'usage': {'output_tokens': 30}}, {'type': 'message_stop'}]
        data = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n'
                       for event in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


@unittest.skipUnless(CLAUDE, 'set RH_TEST_CLAUDE_CLI to test an installed Claude on the agent host')
class ClaudeHookRuntimeTests(ClaudeSessionFixture):
    def run_cli(self, failure=None, protect=True, project_disables_hooks=False,
                command='printf executed > execution-marker', tool_name='Bash', tool_input=None,
                metadata_path=None, session_view=False):
        settings = self.settings()
        if session_view:
            from fixtures.privacy import bind_v3
            _, gateway = bind_v3(self.session, Path(self.env['RH_HOME']), project=self.project)
            import shutil
            shutil.copy2(gateway / 'session-info', self.project / 'rh-session-info')
        if metadata_path:
            path = self.session / 'privacy.json'
            privacy = json.loads(path.read_text())
            privacy['metadata_paths'].append(str(metadata_path))
            path.write_text(json.dumps(privacy))
        if project_disables_hooks:
            project_settings = self.mount / '.claude'
            project_settings.mkdir()
            (project_settings / 'settings.local.json').write_text('{"disableAllHooks":true}')
        hook = settings['hooks']['PreToolUse'][0]['hooks'][0]
        if failure == 'timeout':
            # Sleep before Python can catch anything. Use the real generated timeout, not a mock
            # TimeoutExpired inside route-command.py, and wait long enough that the host cancels it.
            hook['command'] = shlex.join([sys.executable, '-c', 'import time; time.sleep(60)'])
        elif failure == 'missing':
            hook['command'] = str(self.root / 'missing-hook')
        elif failure == 'invalid':
            hook['command'] = "printf '{invalid json}'"
        if not protect:
            hook.pop('onFailure')
        # Execute a routed command in the separate project directory. The real Claude CLI still
        # performs hook scheduling, cancellation, JSON validation, permissions and Bash execution.
        runner = self.session / 'bin/rh-run'
        runner.write_text('#!/bin/sh\ncd ' + shlex.quote(str(self.project)) + '\nexec sh -c "$4"\n')
        path = self.root / 'settings.json'
        path.write_text(json.dumps(settings))
        server = ThreadingHTTPServer(('127.0.0.1', 0), ModelFixture)
        server.results = []
        server.command = command
        server.tool_name, server.tool_input = tool_name, tool_input
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        # Start with an allowlist: no real credentials, proxy, user hooks or MCP servers reach the CLI.
        env = {key: self.env[key] for key in ('PATH', 'HOME')}
        env.update(CLAUDE_CONFIG_DIR=str(self.root / 'cli-config'),
                   ANTHROPIC_API_KEY='sk-ant-fixture-not-a-real-key',
                   ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}',
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
                   CLAUDE_CODE_AUTO_MODE_SERVER='0')
        command = [CLAUDE, '-p', 'Run the fixture command once.', '--model', 'claude-sonnet-4-6',
                   '--permission-mode', 'bypassPermissions', '--setting-sources',
                   'user,project,local' if project_disables_hooks else '', '--settings', str(path), '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
                   '--tools', 'Bash,Read', '--output-format', 'json', '--max-turns', '3']
        process = subprocess.Popen(command, cwd=self.mount, env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            out, err = process.communicate(timeout=60)
        finally:
            # Include a timed-out hook's descendants even if Claude has already exited.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        self.assertEqual(process.returncode, 0, (out[-3000:], err[-1000:]))
        self.assertTrue(server.results, (out[-3000:], err[-1000:]))
        return server.results

    def test_success_routes_without_executing_in_agent_directory(self):
        self.run_cli()
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertEqual((self.project / 'execution-marker').read_text(), 'executed')

    def test_project_command_output_reaches_model_without_identity_substitution(self):
        self.env.update(SSH_CONNECTION='192.0.2.7 51234 203.0.113.45 22',
                        HOSTNAME='agent-hk-private.example')
        payload = '203.0.113.45 agent-hk-private.example Asia/Hong_Kong HK +08:00'
        results = self.run_cli(command='printf %s ' + shlex.quote(payload) + ' | tee original.txt')
        returned = json.dumps(results)
        self.assertIn('203.0.113.45', returned)
        self.assertIn('agent-hk-private.example', returned)
        self.assertIn('Asia/Hong_Kong HK +08:00', returned)
        self.assertEqual((self.project / 'original.txt').read_text(), payload)

    def test_project_read_keeps_business_addresses_and_regions(self):
        self.env['SSH_CONNECTION'] = '192.0.2.7 51234 203.0.113.45 22'
        path = self.mount / 'project-config.txt'
        path.write_text('address=203.0.113.45:443\nregion=HK\n')
        results = self.run_cli(tool_name='Read', tool_input={'file_path': str(path)})
        self.assertIn('203.0.113.45:443', str(results))
        self.assertIn('region=HK', str(results))
        self.assertIn('203.0.113.45', path.read_text())

    def test_v3_project_adapter_returns_real_center_session_view_to_model(self):
        import socket
        results = self.run_cli(command='./rh-session-info', session_view=True)
        output = json.dumps(results)
        self.assertIn(socket.gethostname(), output)
        self.assertIn('agent_center', output)
        self.assertIn('timestamp_conversion', output)
        self.assertNotIn('SOURCE_', output)
        self.assertNotIn('project host', output)

    def test_metadata_file_alias_is_denied_in_actual_cli(self):
        alias = self.mount / 'project-clock'
        alias.symlink_to('/etc/localtime')
        results = self.run_cli(tool_name='Read', tool_input={'file_path': str(alias)})
        self.assertTrue(results[-1].get('is_error'), results)
        self.assertIn('denied', str(results).lower())

    def test_registered_metadata_read_uses_project_identity_and_converts_instant(self):
        self.env['RH_PRESENTATION_POLICY'] = '2'
        project = {'hostname': 'project-kr.example', 'ipv4': '192.0.2.80', 'timezone': 'Asia/Seoul'}
        self.env.update(SSH_CONNECTION='192.0.2.7 51234 203.0.113.45 22',
                        HOSTNAME='agent-hk-private.example', RH_SESSION_TZ='Asia/Seoul',
                        RH_PROJECT_IDENTITY_B64=base64.b64encode(json.dumps(project).encode()).decode())
        path = self.root / 'fixture-agent-metadata'
        original = ('hostname=agent-hk-private.example\nserver_ip=203.0.113.45\n'
                    'host_time=2026-11-14T23:30:00+08:00\ntimezone=Asia/Hong_Kong\n')
        path.write_text(original)
        results = self.run_cli(tool_name='Read', tool_input={'file_path': str(path)}, metadata_path=path)
        output = str(results)
        self.assertIn('project-kr.example', output)
        self.assertIn('192.0.2.80', output)
        self.assertIn('2026-11-15T00:30:00+09:00', output)
        self.assertIn('Asia/Seoul', output)
        self.assertNotIn('203.0.113.45', output)
        self.assertNotIn('agent-hk-private.example', output)
        self.assertNotIn('[remote-host-', output)
        self.assertEqual(path.read_text(), original)

    def test_project_settings_cannot_disable_harness_routing_hooks(self):
        self.run_cli(project_disables_hooks=True)
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertEqual((self.project / 'execution-marker').read_text(), 'executed')

    def test_outer_timeout_blocks_original_command(self):
        results = self.run_cli('timeout')
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertFalse((self.project / 'execution-marker').exists())
        self.assertTrue(results[-1].get('is_error'), results)
        self.assertIn('timed out', str(results))

    def test_missing_hook_blocks_original_command(self):
        results = self.run_cli('missing')
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertFalse((self.project / 'execution-marker').exists())
        self.assertTrue(results[-1].get('is_error'), results)
        self.assertIn('onFailure', str(results))

    def test_invalid_output_blocks_original_command(self):
        results = self.run_cli('invalid')
        self.assertFalse((self.mount / 'execution-marker').exists())
        self.assertFalse((self.project / 'execution-marker').exists())
        self.assertTrue(results[-1].get('is_error'), results)
        self.assertIn('onFailure', str(results))

    def test_control_without_onfailure_reproduces_wrong_host_execution(self):
        self.run_cli('timeout', protect=False)
        self.assertEqual((self.mount / 'execution-marker').read_text(), 'executed')
        self.assertFalse((self.project / 'execution-marker').exists())


if __name__ == '__main__':
    unittest.main()
