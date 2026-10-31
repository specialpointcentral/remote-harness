#!/usr/bin/env python3
"""Behavioral checks for tool argument roles, path mapping and transport retry safety."""
import base64
import importlib.util
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import tracemalloc
import types
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
spec = importlib.util.spec_from_file_location('project_host_tool', SCRIPTS / 'project-host-tool.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
tool.load_routing_modules()


class Stream:
    def __init__(self):
        self.buffer = io.BytesIO()

    def flush(self):
        self.buffer.flush()

    def write(self, text):
        self.buffer.write(text.encode())


class CountingStream(Stream):
    def __init__(self):
        self.buffer = self
        self.count = 0
        self.largest = 0

    def write(self, data):
        self.count += len(data)
        self.largest = max(self.largest, len(data))

    def flush(self):
        pass


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-tool-tests-')
        self.addCleanup(self.tmp.cleanup)
        self.mount = Path(self.tmp.name) / 'mount'
        self.mount.mkdir()
        self.args = types.SimpleNamespace(mount_root=str(self.mount), project_root='/project/root',
            tool='rg', warm_socket='', control_path='', concurrency='6',
            slots_dir=str(Path(self.tmp.name) / 'slots'), runner='unused-runner', ssh_config='unused',
            alias='project')
        self.ctx = tool.Context(self.args)
        self.old = '/project/root'
        self.new = '/remote/挂载'

    def plan(self, args):
        with mock.patch.dict(os.environ, {'RIPGREP_CONFIG_PATH': ''}):
            return tool.rg_plan(self.ctx, args, str(self.mount))[1]

    def rewrite(self, data, size=1, json_mode=False, anywhere=False):
        rewriter = tool.OutputRewriter(self.old, self.new, json_mode, anywhere)
        out = []
        for offset in range(0, len(data), size):
            out.extend(rewriter.feed(data[offset:offset + size]))
        out.extend(rewriter.flush())
        return b''.join(out)

    def test_literal_pattern_and_nonpath_option_values_remain_unchanged(self):
        literal = str(self.mount / 'literal')
        for args in ([literal, str(self.mount)], ['-F', '-e', literal, str(self.mount)],
                     ['--regexp=' + literal, '--replace=' + literal, str(self.mount)],
                     ['-Fe' + literal, '-r' + literal, '-g' + literal, str(self.mount)],
                     ['--glob', literal, '--iglob=' + literal, '--pre-glob', literal,
                      '--context-separator', literal, '-e', literal, str(self.mount)]):
            with self.subTest(args=args):
                self.assertEqual(self.plan(list(args)), list(args[:-1]) + [self.old])

    def test_patterns_anywhere_make_all_positionals_search_paths(self):
        literal = str(self.mount / 'pattern')
        cases = [([str(self.mount), '-nFe', literal], [self.old, '-nFe', literal]),
                 ([str(self.mount), '--regexp', literal], [self.old, '--regexp', literal]),
                 (['-f', str(self.mount / 'patterns'), str(self.mount)],
                  ['-f', self.old + '/patterns', self.old]),
                 (['-nFf' + str(self.mount / 'patterns'), str(self.mount)],
                  ['-nFf' + self.old + '/patterns', self.old]),
                 (['--file=' + str(self.mount / 'patterns'), '--ignore-file',
                   str(self.mount / 'ignores'), str(self.mount)],
                  ['--file=' + self.old + '/patterns', '--ignore-file',
                   self.old + '/ignores', self.old])]
        for args, expected in cases:
            with self.subTest(args=args):
                self.assertEqual(self.plan(args), expected)

    def test_files_and_separator_roles(self):
        self.assertEqual(self.plan(['--files', str(self.mount), '-g', '/literal/glob']),
                         ['--files', self.old, '-g', '/literal/glob'])
        self.assertEqual(self.plan(['--', str(self.mount / 'literal'), str(self.mount)]),
                         ['--', str(self.mount / 'literal'), self.old])
        self.assertEqual(self.plan(['-e', str(self.mount), '--', '-strange-path', str(self.mount)]),
                         ['-e', str(self.mount), '--', '-strange-path', self.old])
        self.assertEqual(self.plan(['-e', '-', '.']), ['-e', '-', '.'])

    def test_config_values_use_the_same_roles_and_no_config_disables_them(self):
        config = Path(self.tmp.name) / 'rg.conf'
        config.write_text('--regexp\n' + str(self.mount / 'literal') + '\n--ignore-file=' +
                          str(self.mount / 'ignore') + '\n')
        with mock.patch.dict(os.environ, {'RIPGREP_CONFIG_PATH': str(config)}):
            self.assertEqual(tool.rg_plan(self.ctx, [str(self.mount)], str(self.mount))[1],
                ['--regexp', str(self.mount / 'literal'), '--ignore-file=' + self.old + '/ignore', self.old])
            self.assertEqual(tool.rg_plan(self.ctx, ['--no-config', 'literal', str(self.mount)],
                                          str(self.mount))[1], ['--no-config', 'literal', self.old])

    def test_unknown_ambiguous_and_stdin_inputs_stay_local(self):
        for args in (['--future-option', str(self.mount)], ['-nf'], ['--regexp'],
                     ['-e', 'x', '-'], ['-f-'], ['--file=-'], ['--pre=/agent/program', 'x'],
                     ['--glob'], ['--json=yes', 'x']):
            with self.subTest(args=args), self.assertRaises(tool.StayLocal):
                self.plan(args)

    @unittest.skipUnless(shutil.which('rg'), 'rg is not installed')
    def test_real_rg_vimgrep_single_absolute_file_maps_back_to_mount(self):
        host = Path(self.tmp.name) / 'project'
        host.mkdir()
        (host / 'file').write_text('needle\n')
        self.args.project_root = str(host)
        ctx = tool.Context(self.args)
        real_attempt = tool.run_attempt
        for flags in (['--vimgrep'], ['-I', '--vimgrep'], ['--vimgrep', '-I']):
            with self.subTest(flags=flags):
                argv = ['--no-config', *flags, 'needle', str(self.mount / 'file')]
                effective, routed = tool.rg_plan(ctx, argv, str(self.mount))
                actual = subprocess.run(['rg', *routed], capture_output=True, check=True).stdout
                expected = actual.replace(os.fsencode(host), os.fsencode(self.mount), 1)
                if flags == ['--vimgrep']:
                    self.assertEqual(actual, os.fsencode(host / 'file') + b':1:1:needle\n')
                else:
                    self.assertEqual(actual, b'1:1:needle\n')
                stdout, stderr = Stream(), Stream()
                def attempt(_command, rewriter, context):
                    return real_attempt(['rg', *routed], rewriter, context)
                with mock.patch.object(tool, 'run_attempt', side_effect=attempt), \
                     mock.patch.object(tool.sys, 'stdout', stdout), \
                     mock.patch.object(tool.sys, 'stderr', stderr):
                    self.assertEqual(tool.route(ctx, effective, routed), 0)
                self.assertEqual(stdout.buffer.getvalue(), expected)
                self.assertEqual(stderr.buffer.getvalue(), b'')

    @unittest.skipUnless(shutil.which('rg'), 'rg is not installed')
    def test_real_rg_json_retains_match_content_and_byte_offsets(self):
        file = self.mount / 'unicode'
        file.write_text('한글 ' + str(self.mount) + '/literal\n')
        raw = subprocess.run(['rg', '--no-config', '--json', '-F', str(self.mount), str(file)],
                             capture_output=True, check=True).stdout
        expected = [json.loads(record) for record in raw.splitlines()]
        for record in expected:
            if 'path' in record['data']:
                record['data']['path']['text'] = self.new + '/unicode'
        rewriter = tool.OutputRewriter(str(self.mount), self.new, True)
        output = b''.join(rewriter.feed(raw)) + b''.join(rewriter.flush())
        self.assertEqual([json.loads(record) for record in output.splitlines()], expected)
        match = next(record['data'] for record in expected if record['type'] == 'match')
        self.assertEqual(match['submatches'][0]['start'], len('한글 '.encode()))
        self.assertIn(str(self.mount), match['lines']['text'])

    def test_content_only_root_prefix_has_documented_text_ambiguity(self):
        # Text cannot reliably distinguish filenames from a match beginning with the root.
        self.plan(['-I', 'root', str(self.mount)])
        def attempt(_command, rewriter, _ctx):
            data = b'/project/root/content\n'
            result = b''.join(rewriter.feed(data)) + b''.join(rewriter.flush())
            self.assertEqual(result, os.fsencode(self.mount) + b'/content\n')
            return 0, True, b''
        with mock.patch.object(tool, 'run_attempt', side_effect=attempt), \
             mock.patch.object(tool.sys, 'stderr', Stream()):
            self.assertEqual(tool.route(self.ctx, str(self.mount), []), 0)

    def test_json_option_values_do_not_enable_json_output(self):
        self.plan(['-e', '--json', str(self.mount)])
        self.assertFalse(self.ctx.rg_json)
        self.plan(['--json', '--no-json', '-e', 'x', str(self.mount)])
        self.assertFalse(self.ctx.rg_json)
        self.plan(['--no-json', '--json', '-e', 'x', str(self.mount)])
        self.assertTrue(self.ctx.rg_json)

    def test_text_rewrites_only_leading_complete_root(self):
        data = b'/project/root/a:/project/root/body\n/project/rooted/a\0/project/root\0other /project/root\n'
        expected = (self.new + '/a:/project/root/body\n/project/rooted/a\0' + self.new +
                    '\0other /project/root\n').encode()
        for size in (1, 2, 7, 13, 64, 65536):
            self.assertEqual(self.rewrite(data, size), expected)

    def test_discovery_boundaries_include_nul_and_survive_every_split(self):
        data = b'worktree /project/root\0HEAD xyz\0/project/root/.git\0/project/rooted x=/project/root/a\n'
        expected = ('worktree ' + self.new + '\0HEAD xyz\0' + self.new +
                    '/.git\0/project/rooted x=' + self.new + '/a\n').encode()
        for split in range(len(data) + 1):
            rewriter = tool.OutputRewriter(self.old, self.new, False, True)
            out = b''.join(rewriter.feed(data[:split])) + b''.join(rewriter.feed(data[split:]))
            self.assertEqual(out + b''.join(rewriter.flush()), expected, split)

    def test_discovery_rewrites_roots_without_consuming_neighboring_paths(self):
        data = b' /project/aX/projectX/project /project/aX/projectx'
        expected = b' /mount/aX/projectX/project /mount/aX/projectx'
        for size in range(1, len(data) + 1):
            rewriter = tool.OutputRewriter('/project', '/mount', False, True)
            result = b''.join(chunk for offset in range(0, len(data), size)
                              for chunk in rewriter.feed(data[offset:offset + size]))
            self.assertEqual(result + b''.join(rewriter.flush()), expected, size)

    def test_newline_free_text_streams_with_root_sized_state(self):
        for prefix in (b'', b'/project/root/file:'):
            rewriter = tool.OutputRewriter(self.old, self.new, False)
            list(rewriter.feed(prefix))
            chunk = b'x' * 65536
            count = 0
            tracemalloc.start()
            try:
                for _ in range(128):
                    output = list(rewriter.feed(chunk))
                    self.assertTrue(output)
                    count += sum(map(len, output))
                    self.assertLessEqual(len(rewriter.pending), len(self.old) + 1)
                count += sum(map(len, rewriter.flush()))
                self.assertLess(tracemalloc.get_traced_memory()[1], 1024 * 1024)
            finally:
                tracemalloc.stop()
            self.assertEqual(count, 8 * 1024 * 1024)

    def test_json_rewrites_only_path_and_preserves_match_bytes_offsets_and_unicode(self):
        for ascii_mode in (False, True):
            value = {'type': 'match', 'data': {'lines': {'text': '/project/root/literal 한글\n'},
                'submatches': [{'match': {'text': '/project/root/literal'}, 'start': 0, 'end': 21}],
                'path': {'text': '/project/root/文件'}, 'line_number': 1}}
            data = (json.dumps(value, ensure_ascii=ascii_mode) + '\n').encode()
            expected = json.loads(data)
            expected['data']['path']['text'] = self.new + '/文件'
            for size in (1, 2, 3, 13, 31, 65536):
                with self.subTest(ascii=ascii_mode, size=size):
                    self.assertEqual(json.loads(self.rewrite(data, size, True)), expected)

    def test_json_base64_path_and_root_collision(self):
        path = b'/project/root/invalid-\xff'
        original = base64.b64encode(path).decode()
        record = json.dumps({'data': {'path': {'bytes': original}, 'lines': {'bytes': original}},
                             'type': 'context'}).encode()
        rewritten = json.loads(self.rewrite(record, 1, True))
        self.assertEqual(base64.b64decode(rewritten['data']['path']['bytes']),
                         self.new.encode() + b'/invalid-\xff')
        self.assertEqual(rewritten['data']['lines']['bytes'], original)
        for path in ('/project/rooted/file', '/project/root-prefix', 'relative'):
            data = json.dumps({'data': {'path': {'text': path}}, 'type': 'begin'}).encode()
            self.assertEqual(self.rewrite(data, 2, True), data)

    def test_malformed_json_and_nonconforming_records_pass_through(self):
        for data in (b'{"data":{"path":{"text":"/project/root/a"}},',
                     b'{"data":{"path":{"text":"/project/root/a"}} BAD}',
                     b'{"data":{"path":{"text":"/project/root/a"}},"data":{}}',
                     b'{"data":{"path":{"text":"/project/root/\\q"}}}',
                     b'{"data":{"path":{"text":"/project/root/a"}},"other":[1,]}',
                     b'{"data":{"path":{"text":"/project/root/a"}},"body":"\xff"}',
                     b'null', b'[]', b'{"data":null}', b'{"data":{"path":null}}',
                     b'{"data":{"path":{"text":123}}}',
                     b'{"data":{"path":{"text":"/project/root/a","bytes":""}}}',
                     b'{"data":{"path":{"bytes":"invalid!"}}}'):
            with self.subTest(data=data):
                self.assertEqual(self.rewrite(data, 7, True), data)

    def test_multi_megabyte_json_record_preserves_content_and_offsets(self):
        # The real path follows the huge match string; only data.path may change.
        value = {'type': 'match', 'data': {
            'lines': {'text': '/project/root/' + 'x' * (3 * 1024 * 1024)},
            'path': {'text': '/project/root/file'},
            'submatches': [{'match': {'text': '/project/root/'}, 'start': 0, 'end': 14}]}}
        data = (json.dumps(value) + '\n').encode()
        rewritten = self.rewrite(data, 16384, True)
        expected = json.loads(data)
        expected['data']['path']['text'] = self.new + '/file'
        self.assertEqual(json.loads(rewritten), expected)
        self.assertTrue(rewritten.endswith(b'\n'))

    def test_json_multiple_records_and_unterminated_final_record(self):
        records = [{'data': {'path': {'text': self.old + '/one'}}},
                   {'data': {'path': {'text': self.old + '/two'}}},
                   {'type': 'summary', 'data': {'elapsed_total': {'secs': 1}}}]
        data = b'\n'.join(json.dumps(record).encode() for record in records)
        expected = json.loads(json.dumps(records))
        expected[0]['data']['path']['text'] = self.new + '/one'
        expected[1]['data']['path']['text'] = self.new + '/two'
        for size in (1, 7, len(data)):
            output = self.rewrite(data, size, True)
            self.assertEqual([json.loads(record) for record in output.splitlines()], expected)
            self.assertFalse(output.endswith(b'\n'))

    def test_small_diagnostics_map_paths_without_becoming_visible(self):
        self.ctx.root, self.ctx.used_mount = self.old, self.new
        stream = Stream()
        with mock.patch.object(tool.sys, 'stderr', stream):
            errors = tool.DiagnosticCapture(self.ctx)
            errors.feed(b'rg: /project/ro')
            errors.feed(b'ot/missing: not found\n')
            self.assertEqual(errors.finish(), ('rg: ' + self.new + '/missing: not found\n').encode())
        self.assertFalse(errors.emitted)
        self.assertEqual(stream.buffer.getvalue(), b'')

    def test_diagnostic_capture_streams_after_bound_without_retaining_history(self):
        stream = CountingStream()
        with mock.patch.object(tool.sys, 'stderr', stream):
            errors = tool.DiagnosticCapture(self.ctx)
            for _ in range(128):
                errors.feed(b'x' * 65536)
                self.assertLessEqual(len(errors.pending), errors.LIMIT)
                self.assertLessEqual(len(errors.rewriter.record), errors.LIMIT)
            self.assertEqual(errors.finish(), b'')
        self.assertTrue(errors.emitted)
        self.assertEqual(stream.count, 8 * 1024 * 1024)
        self.assertLessEqual(stream.largest, 65536 + len(self.old) + 1)

    def test_large_diagnostic_overflow_streams_without_path_mapping(self):
        self.ctx.root, self.ctx.used_mount = self.old, self.new
        prefix = b'rg: /project/root/missing '
        prefix += b'x' * (tool.DiagnosticCapture.LIMIT - len(prefix))
        self.assertEqual(len(prefix), tool.DiagnosticCapture.LIMIT)
        overflow = b'/project/root/overflow'
        stream = Stream()
        with mock.patch.object(tool.sys, 'stderr', stream):
            errors = tool.DiagnosticCapture(self.ctx)
            errors.feed(prefix)
            errors.feed(overflow)
            self.assertEqual(errors.finish(), b'')
        self.assertTrue(errors.emitted)
        self.assertEqual(stream.buffer.getvalue(),
                         prefix.replace(self.old.encode(), self.new.encode(), 1) + overflow)
        self.assertEqual(errors.pending, b'')
        self.assertEqual(errors.rewriter.record, b'')

    def test_cold_attempt_streams_both_outputs_and_keeps_error_status(self):
        stdout, stderr = CountingStream(), CountingStream()
        command = [sys.executable, '-c', 'import os; os.write(1,b"o"*131072); '
                   'os.write(2,b"e"*131072); raise SystemExit(23)']
        with mock.patch.object(tool.sys, 'stdout', stdout), mock.patch.object(tool.sys, 'stderr', stderr):
            status, emitted, captured = tool.run_attempt(command,
                tool.OutputRewriter(self.old, self.new, False), self.ctx)
        self.assertEqual((status, emitted, captured), (23, True, b''))
        self.assertEqual(stdout.count, 131072)
        self.assertEqual(stderr.count, 131072)

    def test_visible_cold_stderr_prevents_retries(self):
        script = Path(self.tmp.name) / 'runner'
        counter = Path(self.tmp.name) / 'attempts'
        script.write_text('#!' + sys.executable + '\nimport os\n'
                          f'open({str(counter)!r},"a").write("attempt\\n")\n'
                          'os.write(2,b"e"*131072)\nraise SystemExit(255)\n')
        script.chmod(0o700)
        self.args.runner = str(script)
        self.args.control_path = str(Path(self.tmp.name) / 'mux')
        stream = CountingStream()
        with mock.patch.object(tool.sys, 'stderr', stream):
            self.assertEqual(tool.route(self.ctx, str(self.mount), ['x']), 255)
        self.assertEqual(counter.read_text(), 'attempt\n')
        self.assertEqual(stream.count, 131072)

    def fake_warm_pool(self, callback):
        held = types.SimpleNamespace(close=mock.Mock())
        module = types.SimpleNamespace(claim=lambda _socket: held, run=callback,
                                       NotDelivered=type('NotDelivered', (Exception,), {}))
        self.args.warm_socket = 'fake-socket'
        return module, held

    def test_visible_warm_stderr_prevents_cold_retry(self):
        def run(_held, _request, _stdout, stderr):
            stderr(b'e' * 65536)
            stderr(b'e' * 65536)
            return 255
        module, held = self.fake_warm_pool(run)
        stream = CountingStream()
        with mock.patch.dict(sys.modules, {'warm_pool': module}), \
             mock.patch.object(tool, 'run_attempt') as cold, mock.patch.object(tool.sys, 'stderr', stream):
            self.assertEqual(tool.route(self.ctx, str(self.mount), ['x']), 255)
            cold.assert_not_called()
        held.close.assert_called()
        self.assertEqual(stream.count, 131072)

    def test_small_missing_tool_and_capacity_messages_keep_retry_behavior(self):
        stdout, stderr = Stream(), Stream()
        command = [sys.executable, '-c', 'import sys; sys.stderr.write('
                   + repr(tool.missing_message('rg').decode()) + '); raise SystemExit(127)']
        with mock.patch.object(tool.sys, 'stdout', stdout), mock.patch.object(tool.sys, 'stderr', stderr):
            status, emitted, captured = tool.run_attempt(command,
                tool.OutputRewriter(self.old, self.new, False), self.ctx)
        self.assertEqual(status, 127)
        self.assertFalse(emitted)
        self.assertEqual(captured, tool.missing_message('rg'))
        self.assertEqual(stderr.buffer.getvalue(), b'')
        self.args.control_path = 'fake-mux'
        with mock.patch.object(tool, 'run_attempt', side_effect=[
            (255, False, b'mux: session open refused: no more sessions'), (0, False, b'')]) as attempts, \
             mock.patch.object(tool, 'stop_master') as stop, mock.patch.object(tool.sys, 'stderr', Stream()):
            self.assertEqual(tool.route(self.ctx, str(self.mount), ['x']), 0)
            self.assertEqual(attempts.call_count, 2)
            stop.assert_not_called()
        with mock.patch.object(tool, 'run_attempt', return_value=(127, False, captured)), \
             mock.patch.object(tool.sys, 'stderr', Stream()), self.assertRaises(tool.ToolMissing):
            tool.route(self.ctx, str(self.mount), ['x'])

    def test_warm_missing_tool_is_detected_and_visible_stdout_does_not_retry(self):
        def missing(_held, _request, _stdout, stderr):
            stderr(tool.missing_message('rg'))
            return 127
        module, _ = self.fake_warm_pool(missing)
        with mock.patch.dict(sys.modules, {'warm_pool': module}), \
             mock.patch.object(tool, 'run_attempt') as cold, self.assertRaises(tool.ToolMissing):
            tool.route(self.ctx, str(self.mount), ['x'])
        cold.assert_not_called()
        def partial(_held, _request, stdout, _stderr):
            stdout(b'partial output')
            return 255
        module, _ = self.fake_warm_pool(partial)
        with mock.patch.dict(sys.modules, {'warm_pool': module}), \
             mock.patch.object(tool, 'run_attempt') as cold, \
             mock.patch.object(tool.sys, 'stdout', Stream()), mock.patch.object(tool.sys, 'stderr', Stream()):
            self.assertEqual(tool.route(self.ctx, str(self.mount), ['x']), 255)
            cold.assert_not_called()


if __name__ == '__main__':
    unittest.main()
