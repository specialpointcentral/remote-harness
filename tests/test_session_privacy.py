#!/usr/bin/env python3
"""Privacy at stream/result boundaries; project data and process semantics remain intact."""
import json
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import signal
import unittest
import shutil
import io
import contextlib
import uuid
import hashlib
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from fixtures.privacy import policy

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from session_privacy import (Policy, validate_timezone, validate_effective_timezone, validate_profile, project_identity, capture, center_profile,
    profile_lines, PROFILE_FIELDS, private_json, bind_presentation, select_presentation,
    activate_presentation, presentation_for_conversation)


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='rh-privacy-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.path = policy(self.root)
        self.policy = Policy(self.path)

    def test_all_chunk_boundaries_and_nonmatches(self):
        original = b'\xff\x00203.0.113.45 agent-hk-private.example\n203.0.113.450 HK Asia/Hong_Kong +08:00\n'
        expected = b'\xff\x00192.0.2.80 project-kr.example\n203.0.113.450 HK Asia/Hong_Kong +08:00\n'
        for size in range(1, len(original) + 1):
            stream = self.policy.stream(source='agent')
            output = b''.join(stream.feed(original[i:i+size]) for i in range(0, len(original), size))
            output += stream.feed(b'', final=True)
            self.assertEqual(output, expected, size)
        self.assertEqual(self.policy.clean_bytes(expected), expected)

    def test_structured_values_preserve_schema_and_status(self):
        self.assertEqual(self.policy.clean({'server_ip': '203.0.113.45', 'exit_code': 17,
                                           'interrupted': False, 'content': ['hostname=agent-hk-private.example']}),
                         {'server_ip': '192.0.2.80', 'exit_code': 17,
                          'interrupted': False, 'content': ['hostname=project-kr.example']})

    def test_timestamp_conversion_preserves_instant_across_midnight(self):
        from datetime import datetime
        original = '2026-11-14T23:30:00+08:00'
        converted = self.policy.clean({'host_time': original, 'timezone': 'Asia/Hong_Kong',
                                       'utc_offset': '+08:00', 'timezone_abbr': 'HKT', 'country': 'HK'})
        self.assertEqual(converted, {'host_time': '2026-11-15T00:30:00+09:00', 'timezone': 'Asia/Seoul',
                                     'utc_offset': '+09:00', 'timezone_abbr': 'KST', 'country': 'KR'})
        self.assertEqual(datetime.fromisoformat(original).timestamp(),
                         datetime.fromisoformat(converted['host_time']).timestamp())
        self.assertEqual(self.policy.clean({'host_time': '2026-11-14 23:30:00'}),
                         {'host_time': '2026-11-14 23:30:00'})

    def test_project_data_and_unknown_prose_remain_unchanged(self):
        value = {'hostname': 'agent-hk-private.example', 'server_ip': '203.0.113.45', 'country': 'HK',
                 'host_time': '2026-11-14T23:30:00+08:00', 'timezone': 'Asia/Hong_Kong'}
        self.assertEqual(self.policy.clean(value, source='project'), value)
        text = 'build failed; email=agent-hk-private.example@example.com; HK KR +08:00 Asia/Hong_Kong'
        self.assertEqual(self.policy.clean(text), text)

    def test_only_registered_agent_metadata_sources_are_transformed(self):
        result = {'content': 'hostname=agent-hk-private.example\nhost_time=2026-11-14T23:30:00+08:00'}
        event = {'tool_name': 'Read', 'tool_input': {'file_path': '/proc/fixture'}, 'tool_response': result}
        changed = self.policy.tool_result(event)
        self.assertIn('project-kr.example', changed['content'])
        self.assertIn('2026-11-15T00:30:00+09:00', changed['content'])
        for name, path in (('Read', str(self.root / 'business.txt')), ('Bash', '/proc/fixture'),
                           ('mcp_external', '/proc/fixture')):
            event.update(tool_name=name, tool_input={'file_path': path})
            self.assertEqual(self.policy.tool_result(event), result)
        embedded = json.dumps({'hostname': 'agent-hk-private.example',
                               'host_time': '2026-11-14T23:30:00+08:00'})
        self.assertEqual(json.loads(self.policy.clean(embedded)),
                         {'hostname': 'project-kr.example', 'host_time': '2026-11-15T00:30:00+09:00'})

    def test_missing_identity_is_not_invented_and_interfaces_are_not_collapsed(self):
        metadata = {'machine_id': '0123456789abcdef', 'interfaces': [{'ipv4': '203.0.113.45'},
                                                                  {'ipv4': '203.0.113.46'}]}
        self.assertEqual(self.policy.clean(metadata), metadata)
        for endpoint in ('203.0.113.45:22', '203.0.113.45,203.0.113.46'):
            self.assertEqual(self.policy.clean({'server_ip': endpoint}), {'server_ip': endpoint})
        original = 'a' * 32
        config = json.loads(self.path.read_text())
        config['project']['machine_id'] = 'b' * 32
        config['identifiers'][original] = 'b' * 32
        self.path.write_text(json.dumps(config))
        self.assertEqual(Policy(self.path).clean({'machine_id': original}), {'machine_id': 'b' * 32})

    def test_country_and_region_are_not_inferred_from_timezone(self):
        config = json.loads(self.path.read_text())
        config['project'].pop('country')
        config['project'].pop('region')
        self.path.write_text(json.dumps(config))
        privacy = Policy(self.path)
        self.assertEqual(privacy.clean({'country': 'HK', 'region': 'ap-east-1'}),
                         {'country': 'HK', 'region': 'ap-east-1'})

    def test_project_launcher_collects_its_identity_without_external_geolocation(self):
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'hostname').write_text('#!/bin/sh\nprintf project-kr.example')
        (bin_dir / 'ip').write_text('#!/bin/sh\ncase " $* " in *" -6 "*) exit 1;; esac\nprintf "route src 192.0.2.80\\n"')
        for path in bin_dir.iterdir():
            path.chmod(0o700)
        env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'], TZ='Asia/Seoul',
                   RH_SESSION_TZ='Asia/Seoul', RH_SESSION_COUNTRY='KR', RH_SESSION_REGION='kr-local')
        result = subprocess.run(['bash', '-uc', '. "$1"; project_identity_b64', 'fixture',
                                 str(ROOT / 'scripts/_common.sh')], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = project_identity(result.stdout, 'Asia/Seoul')
        self.assertEqual(identity['hostname'], 'project-kr.example')
        self.assertEqual(identity['ipv4'], '192.0.2.80')
        self.assertEqual(identity['country'], 'KR')
        self.assertEqual(identity['region'], 'kr-local')
        mismatch = base64.b64encode(json.dumps({'timezone': 'Asia/Hong_Kong'}).encode()).decode()
        with self.assertRaises(ValueError):
            project_identity(mismatch, 'Asia/Seoul')

    def test_endpoint_ports_and_urls_are_filtered(self):
        data = b'https://agent-hk-private.example:443/ 203.0.113.45:22 agent-hk-private.example.org'
        expected = b'https://project-kr.example:443/ 192.0.2.80:22 agent-hk-private.example.org'
        for cut in range(len(data)):
            stream = self.policy.stream(source='agent')
            self.assertEqual(stream.feed(data[:cut]) + stream.feed(data[cut:], final=True), expected)

    def test_ipv6_equivalent_spellings_and_ports(self):
        config = json.loads(self.path.read_text())
        config['identifiers']['2001:db8::45'] = '2001:db8::80'
        self.path.write_text(json.dumps(config))
        privacy = Policy(self.path)
        data = b'[2001:0DB8:0:0::0045]:22 [2001:db8::46]:22'
        for size in range(1, len(data)):
            stream = privacy.stream(source='agent')
            output = b''.join(stream.feed(data[i:i+size]) for i in range(0, len(data), size))
            self.assertEqual(output + stream.feed(b'', final=True), b'[2001:db8::80]:22 [2001:db8::46]:22')

    def test_missing_or_public_policy_fails(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            Policy(self.path)
        self.path.unlink()
        with self.assertRaises(OSError):
            Policy(self.path)

    def test_timezone_and_daemon_environment(self):
        for invalid in ('../etc/passwd', '/etc/localtime', 'Asia/Seoul\n', 'Asia/Seoul;id', 'Unknown/Test'):
            with self.assertRaises(ValueError):
                validate_timezone(invalid)
        env = self.policy.environment({'TZ': 'Asia/Hong_Kong', 'TZDIR': '/tmp/zones',
                                       'HOSTNAME': 'private', 'SSH_CONNECTION': 'private',
                                       'SSH_CLIENT': 'private', 'LANG': 'en_US.UTF-8'})
        self.assertEqual(env, {'TZ': 'Asia/Seoul', 'SSH_CONNECTION': '0.0.0.0 0 0.0.0.0 0',
                               'HOSTNAME': 'project-kr.example', 'HOST': 'project-kr.example',
                               'SSH_CLIENT': '0.0.0.0 0 0', 'LANG': 'en_US.UTF-8'})
        inherited = Policy(policy(self.root, timezone=''))
        self.assertEqual(inherited.environment({'TZ': 'Custom/Zone', 'TZDIR': '/custom/zones'}),
                         {'TZ': 'Custom/Zone', 'TZDIR': '/custom/zones',
                          'HOSTNAME': 'project-kr.example', 'HOST': 'project-kr.example'})

    def test_local_search_rejects_metadata_alias_and_ancestors(self):
        alias = self.root / 'innocent'
        alias.symlink_to('/etc/localtime')
        for args, cwd in ((['x', str(alias)], str(self.root)), (['x', '/etc'], str(self.root)),
                          (['x'], '/proc'), (['-L', 'x'], str(self.root)),
                          (['-nL', 'x'], str(self.root)), (['-f/etc/localtime'], str(self.root))):
            self.assertFalse(self.policy.local_search_allowed(args, cwd))
        self.assertTrue(self.policy.local_search_allowed(['x', '.'], str(self.root)))

    def guard(self, source, path=None):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/channel-guard.py'),
                               '--privacy-policy', str(path or self.path), '--',
                               sys.executable, '-c', source], capture_output=True, timeout=10)

    def test_project_stream_preserves_both_streams_and_failure(self):
        result = self.guard("import os; os.write(1,b'203.0.'); os.write(2,b'agent-hk-'); "
                            "os.write(1,b'113.45\\n'); os.write(2,b'private.example\\n'); raise SystemExit(17)")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, b'203.0.113.45\n')
        self.assertEqual(result.stderr, b'agent-hk-private.example\n')

    def test_filter_startup_failure_prevents_command(self):
        marker = self.root / 'executed'
        result = self.guard(f'open({str(marker)!r}, "w").close()', self.root / 'missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_progress_lines_stream_and_cancel_keeps_signal_exit(self):
        command = [sys.executable, str(ROOT / 'scripts/channel-guard.py'), '--privacy-policy',
                   str(self.path), '--', sys.executable, '-c',
                   'import sys; print("203.0.113.45 ready", flush=True); sys.stdin.read()']
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            try:
                import select
                self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'progress line was buffered')
                self.assertEqual(child.stdout.readline(), b'203.0.113.45 ready\n')
                child.send_signal(signal.SIGTERM)
                out, err = child.communicate(timeout=7)
                self.assertEqual(child.returncode, 128 + signal.SIGTERM)
                self.assertEqual(out + err, b'')
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate(timeout=3)


class CenterPresentationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='rh-center-profile-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / 'center'
        self.home.mkdir(mode=0o700)
        self.gateway = self.root / 'gateway'
        self.gateway.mkdir(mode=0o700)
        self.project = self.root / 'project'
        self.project.mkdir()
        self.profile = dict.fromkeys(PROFILE_FIELDS, '')
        self.profile.update(hostname='center-real.example', ipv4='203.0.113.11',
                            machine_id='c' * 32, timezone='Asia/Seoul', effective_tz='Asia/Seoul')
        self.encoded = base64.b64encode(profile_lines(self.profile).encode()).decode()
        self.cache = self.home / 'privacy.json'
        env = {k: v for k, v in os.environ.items() if not k.startswith('RH_')}
        with patch.dict(os.environ, dict(env, RH_CENTER_PROFILE_B64=self.encoded), clear=True):
            capture(self.cache, '', str(self.project))
        self.identity = private_json(self.cache)['presentation_id']
        self.env = dict(env, TZ='Asia/Hong_Kong')

    def prepare(self, identity=None, encoded=None):
        return subprocess.run(['bash', str(ROOT / 'scripts/project-session-info.sh'), 'prepare',
            str(self.gateway), str(self.root / 'tables'), str(self.project), identity or self.identity,
            encoded or self.encoded], capture_output=True, text=True, env=self.env)

    def bind(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        bind_presentation(self.cache, self.home, result.stdout.strip())
        return result.stdout.strip()

    def test_project_owns_exact_table_and_center_cache_has_only_target_and_digests(self):
        self.bind()
        result = subprocess.run([str(self.gateway / 'session-info')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        view = json.loads(result.stdout)
        self.assertEqual(view['view'], 'session')
        self.assertEqual(view['identity']['hostname'], self.profile['hostname'])
        self.assertEqual(view['identity']['timezone'], self.profile['timezone'])
        self.assertIsNone(view['identity']['country'])
        self.assertFalse(view['capabilities']['timestamp_conversion'])
        table = next((self.root / 'tables').glob('*/table'))
        self.assertIn('SOURCE_TIMEZONE=Asia/Hong_Kong', table.read_text())
        self.assertEqual(table.stat().st_mode & 0o777, 0o600)
        self.assertEqual(table.parent.stat().st_mode & 0o777, 0o700)
        for file in self.home.rglob('*'):
            if file.is_file():
                self.assertNotIn('SOURCE_', file.read_text())
                self.assertNotIn('Asia/Hong_Kong', file.read_text())

    def test_untrusted_json_and_all_business_streams_are_byte_identical(self):
        policy = Policy(self.cache)
        value = {'schema_version': 3, 'view': 'session', 'hostname': 'project-real.example',
                 'timezone': 'Asia/Hong_Kong', 'business_time': '2020-07-01T00:00:00+08:00'}
        payload = (json.dumps(value) + '\nHK KR +08:00 test@example.com ' +
                   'https://203.0.113.11:8443/path token=test-secret').encode() + b'\xff\0'
        for source in ('project', 'agent', 'unknown'):
            stream = policy.stream(source)
            self.assertEqual(stream.feed(payload[:13]) + stream.feed(payload[13:], final=True), payload)
        self.assertEqual(policy.clean(value), value)
        self.assertIs(policy.clean(value), value)
        event = {'tool_name': 'Read', 'tool_input': {'file_path': '/etc/hostname'}, 'tool_response': value}
        self.assertEqual(policy.tool_result(event), value)

    def test_direct_profile_validation_preserves_ascii_types_and_control_checks(self):
        original = json.loads(self.cache.read_text())
        for field, value in (('ipv6', 'fe80::1%网卡'), ('hostname', 42),
                             ('effective_tz', None), ('region', 'region\n')):
            with self.subTest(field=field, value=value):
                config = json.loads(json.dumps(original))
                config['target_profile'][field] = value
                with self.assertRaises(ValueError):
                    validate_profile(config['target_profile'])
                config['center_profile_digest'] = hashlib.sha256(
                    profile_lines(config['target_profile']).encode()).hexdigest()
                self.cache.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    Policy(self.cache)

    def test_large_binary_project_streams_preserve_both_channels_and_exit(self):
        # Larger than a pipe buffer on each fd, with every byte value and no text decoding.
        block = bytes(range(256)) * 4096
        command = ("import os; block=bytes(range(256))*4096; "
                   "os.write(1,block); os.write(2,block[::-1]); raise SystemExit(17)")
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/channel-guard.py'),
            '--privacy-policy', str(self.cache), '--', sys.executable, '-c', command],
            capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(result.stdout, block)
        self.assertEqual(result.stderr, block[::-1])

    def test_combined_launcher_environment_quotes_raw_timezone_and_requires_policy(self):
        target = dict(self.profile, effective_tz='<+03>-3', effective_tzdir='/center/zones')
        encoded = base64.b64encode(profile_lines(target).encode()).decode()
        cache = self.home / 'launcher.json'
        with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': encoded}, clear=True):
            capture(cache, '')
        command = [sys.executable, str(ROOT / 'scripts/session_privacy.py'), 'launcher-env', str(cache)]
        emitted = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        result = subprocess.run(['bash', '-uc', emitted.stdout +
            '\nprintf "%s|%s|%s" "$project_hostname" "$TZ" "$TZDIR"'], capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout),
                         (0, 'center-real.example|<+03>-3|/center/zones'))
        cache.unlink()
        failed = subprocess.run(command, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed.stdout, b'')

    def test_concurrent_prepare_resume_and_new_logical_identity(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.prepare(), range(4)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, results[0].stdout)
        summary = self.bind()
        activate_presentation(self.cache, self.home, 'claude')
        original = next((self.root / 'tables').glob('*/table')).read_bytes()
        self.assertEqual(self.prepare().stdout.strip(), summary)
        self.assertEqual(next((self.root / 'tables').glob('*/table')).read_bytes(), original)
        self.assertNotEqual(self.prepare('11111111-1111-4111-8111-111111111111').returncode, 0)
        self.gateway = self.root / 'new-gateway'
        self.gateway.mkdir(mode=0o700)
        self.assertNotEqual(self.prepare('11111111-1111-4111-8111-111111111111').stdout.strip(), summary)
        other = self.home / 'other.json'
        with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': self.encoded}):
            capture(other, '', str(self.project))
        with contextlib.redirect_stdout(io.StringIO()):
            select_presentation(other, self.home, self.identity, 'claude')
        self.assertEqual(private_json(other)['presentation_id'], self.identity)
        self.assertEqual(presentation_for_conversation(self.home, self.identity), self.identity)

    def test_conflicting_concurrent_gateway_prepares_never_rebind(self):
        identities = [self.identity, '11111111-1111-4111-8111-111111111111']
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.prepare, identities))
        self.assertEqual(sorted(result.returncode for result in results), [0, 125])
        first = (self.gateway / 'session-info').read_bytes()
        winner = identities[next(i for i, result in enumerate(results) if result.returncode == 0)]
        self.assertEqual(self.prepare(winner).returncode, 0)
        self.assertEqual((self.gateway / 'session-info').read_bytes(), first)

    def test_copied_localtime_does_not_trust_stale_timezone_label(self):
        original_read_text = Path.read_text
        original_read_bytes = Path.read_bytes
        def read_text(path, *args, **kwargs):
            if str(path) == '/etc/timezone':
                return 'Europe/London'
            return original_read_text(path, *args, **kwargs)
        def read_bytes(path):
            if str(path) == '/etc/localtime':
                return b'copied different localtime fixture'
            return original_read_bytes(path)
        original_realpath = os.path.realpath
        def realpath(path, *args, **kwargs):
            return '/etc/localtime' if str(path) == '/etc/localtime' else original_realpath(path, *args, **kwargs)
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, 'read_text', read_text), \
                patch.object(Path, 'read_bytes', read_bytes), patch('os.path.realpath', realpath):
            profile = center_profile()
        self.assertEqual(profile['timezone'], '')
        self.assertEqual(profile['effective_tz'], ':/etc/localtime')

    def test_disconnect_marker_names_exact_conversation_among_two_same_mounts(self):
        session_parent = self.home / '.sessions'
        session_parent.mkdir(mode=0o700)
        second = '11111111-1111-4111-8111-111111111111'
        sessions = []
        for label, identity in (('A', self.identity), ('B', second)):
            session = session_parent / label
            session.mkdir(mode=0o700)
            mount = base64.b64encode(str(self.project).encode()).decode()
            agent = base64.b64encode(b'claude').decode()
            (session / 'session.env').write_text(f'MOUNTPOINT={mount}\nAGENT={agent}\n')
            (session / 'presentation-resume.env').write_text(
                f'PRESENTATION_ID={identity}\nCONVERSATION_ID={identity}\n')
            sessions.append(session)
        body = '. "$1"; mark_disconnected "$2" heartbeat'
        env = dict(os.environ, RH_HOME=str(self.home), RH_REAPER_LIBRARY='1')
        # B starts later, then A disconnects last. The marker must name A explicitly.
        for session in reversed(sessions):
            subprocess.run(['sh', '-c', body, 'fixture', str(ROOT / 'scripts/session-reaper.sh'),
                str(session)], env=env, check=True)
        result = subprocess.check_output(['sh', str(ROOT / 'scripts/session-reaper.sh'),
            'resume-take', str(sessions[0])], env=dict(env, RH_REAPER_LIBRARY='0'), text=True)
        self.assertIn('PRESENTATION_ID=' + self.identity, result)
        self.assertIn('CONVERSATION_ID=' + self.identity, result)
        self.assertNotIn(second, result)

    def test_local_only_disconnect_record_retains_one_exact_pair_and_rejects_symlink(self):
        marker = self.root / 'local-resume'
        body = '. "$1"; write_local_resume_marker "$2" 1794500000 "$3" "$4"; read_local_resume_marker "$2"'
        conversation = '11111111-1111-4111-8111-111111111111'
        result = subprocess.run(['bash', '-c', body, 'fixture', str(ROOT / 'scripts/_common.sh'),
            str(marker), self.identity, conversation], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f'VERSION=3\nTIME=1794500000\nPRESENTATION_ID={self.identity}\nCONVERSATION_ID={conversation}\n')
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        marker.unlink()
        marker.symlink_to(self.cache)
        result = subprocess.run(['bash', '-c', body, 'fixture', str(ROOT / 'scripts/_common.sh'),
            str(marker), self.identity, conversation], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_changed_center_corrupt_table_permissions_and_symlink_fail(self):
        self.bind()
        changed = dict(self.profile, hostname='other-center.example')
        encoded = base64.b64encode(profile_lines(changed).encode()).decode()
        self.assertNotEqual(self.prepare(encoded=encoded).returncode, 0)
        table = next((self.root / 'tables').glob('*/table'))
        original = table.read_bytes()
        for mode, data in ((0o644, original), (0o600, original[:25]),
                           (0o600, original.replace(b'TARGET_HOSTNAME=center', b'TARGET_HOSTNAME=other'))):
            table.write_bytes(data)
            table.chmod(mode)
            result = subprocess.run([str(self.gateway / 'session-info')], capture_output=True)
            self.assertEqual(result.stdout, b'')
            self.assertNotEqual(result.returncode, 0)
        table.unlink()
        table.symlink_to(self.cache)
        self.assertNotEqual(self.prepare().returncode, 0)

    def test_center_process_retains_real_hostname_and_custom_effective_timezone(self):
        import socket
        zones = self.root / 'zones'
        (zones / 'Custom').mkdir(parents=True)
        shutil.copyfile('/usr/share/zoneinfo/Asia/Seoul', zones / 'Custom/Zone')
        with patch.dict(os.environ, {'TZ': 'Custom/Zone', 'TZDIR': str(zones)}, clear=True):
            profile = center_profile()
        self.assertEqual(profile['hostname'], socket.gethostname())
        self.assertEqual(profile['timezone'], '')
        encoded = base64.b64encode(profile_lines(profile).encode()).decode()
        cache = self.home / 'custom.json'
        with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': encoded}, clear=True):
            capture(cache, '')
        after = Policy(cache).environment({'TZ': 'UTC', 'TZDIR': '/wrong', 'HOSTNAME': 'daemon-wrong'})
        script = 'import time,socket; print(time.strftime("%z")); print(socket.gethostname())'
        before = subprocess.check_output([sys.executable, '-c', script],
            env=dict(os.environ, TZ='Custom/Zone', TZDIR=str(zones)))
        actual = subprocess.check_output([sys.executable, '-c', script], env=dict(os.environ, **after))
        self.assertEqual(actual, before)
        self.assertEqual(after['HOSTNAME'], socket.gethostname())

    def test_legacy_shared_configuration_rejected_by_v3(self):
        with patch.dict(os.environ, {'RH_SESSION_TZ': 'Asia/Hong_Kong'}):
            with self.assertRaises(ValueError):
                capture(self.home / 'legacy.json', '')
        result = subprocess.run(['bash', str(ROOT / 'scripts/simple-dispatch.sh'), '--mode', 'reverse',
            '--session-timezone', 'Asia/Seoul'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--project-timezone', result.stderr)

    def test_posix_and_named_timezones_keep_raw_values_and_real_process_offsets(self):
        valid = ('<+03>-3', ':<+03>-3', ':UTC0', 'UTC-3:3', 'UTC-3:03:3',
                 'EST5EDT,M3.2.0/2:3,M11.1.0/2', 'EST5EDT,M3.2.0/2,M11.1.0/2',
                 'CET-1CEST,M3.5.0/2,M10.5.0/3', 'NZ-CHAT', 'GB-Eire', 'W-SU')
        script = 'import time; print(time.strftime("%z",time.localtime(1704067200)),time.strftime("%z",time.localtime(1719792000)))'
        for index, value in enumerate(valid):
            with self.subTest(value=value):
                validate_effective_timezone(value)
                shell = subprocess.run(['bash', '-uc', '. "$1"; validate_effective_timezone "$2"',
                    'fixture', str(ROOT / 'scripts/_common.sh'), value], capture_output=True)
                self.assertEqual(shell.returncode, 0, shell.stderr)
                target = dict(self.profile, timezone='', effective_tz=value)
                encoded = base64.b64encode(profile_lines(target).encode()).decode()
                cache = self.home / f'posix-{index}.json'
                with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': encoded}, clear=True):
                    capture(cache, '')
                after = Policy(cache).environment({'TZ': 'UTC0', 'TZDIR': '/daemon/wrong'})
                self.assertEqual(after['TZ'], value)
                before = subprocess.check_output([sys.executable, '-c', script], env=dict(os.environ, TZ=value))
                actual = subprocess.check_output([sys.executable, '-c', script], env=dict(os.environ, **after))
                self.assertEqual(actual, before)
                if value in ('<+03>-3', ':<+03>-3'):
                    self.assertEqual(actual.strip(), b'+0300 +0300')
                if value.startswith('EST5EDT,'):
                    self.assertEqual(actual.strip(), b'-0500 -0400')
                self.gateway = self.root / f'posix-gateway-{index}'
                self.gateway.mkdir(mode=0o700)
                self.env['TZ'] = value
                result = self.prepare(str(uuid.uuid4()), encoded)
                self.assertEqual(result.returncode, 0, result.stderr)
                view = json.loads(subprocess.check_output([str(self.gateway / 'session-info')]))
                self.assertEqual(view['identity']['effective_tz'], value)
                self.assertIsNone(view['identity']['timezone'])
                self.assertTrue(any(f'SOURCE_EFFECTIVE_TZ={value}\n' in p.read_text()
                                    for p in (self.root / 'tables').glob('*/table')))

    def test_malformed_posix_timezones_are_rejected_on_both_hosts(self):
        invalid = ('<A>-3', '<+03>-99', 'EST5EDT,M13.1.0,M11.1.0',
                   'EST5EDT,M3.0.0,M11.1.0', 'EST5EDT,J0,J365', 'EST5EDT,366,1',
                   'EST5EDT,M3.1.0/168,M11.1.0', 'EST5EDT,M3.1.0/2:60,M11.1.0',
                   'UTC0;touch marker', 'UTC0\n', 'UTC0\x00', r'UTC\060')
        for value in invalid:
            with self.subTest(value=repr(value)):
                with self.assertRaises(ValueError):
                    validate_effective_timezone(value)
                if '\x00' not in value:
                    result = subprocess.run(['bash', '-uc', '. "$1"; validate_effective_timezone "$2"',
                        'fixture', str(ROOT / 'scripts/_common.sh'), value], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                target = dict(self.profile, timezone='', effective_tz=value)
                encoded = base64.b64encode(profile_lines(target).encode()).decode()
                self.assertNotEqual(self.prepare(str(uuid.uuid4()), encoded).returncode, 0)
        target = dict(self.profile, effective_tzdir='/zones<unsafe>')
        with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': base64.b64encode(profile_lines(target).encode()).decode()}, clear=True):
            with self.assertRaises(ValueError):
                capture(self.home / 'invalid-dir.json', '')

    def test_custom_tzdir_single_filename_keeps_its_real_offset(self):
        zones = self.root / 'zones'
        zones.mkdir()
        shutil.copyfile('/usr/share/zoneinfo/Etc/GMT-3', zones / 'custom.v1')
        with patch.dict(os.environ, {'TZ': 'custom.v1', 'TZDIR': str(zones)}, clear=True):
            target = center_profile()
        self.assertEqual(target['timezone'], '')
        self.assertEqual(target['effective_tz'], 'custom.v1')
        self.assertEqual(target['effective_tzdir'], str(zones))
        encoded = base64.b64encode(profile_lines(target).encode()).decode()
        with patch.dict(os.environ, {'RH_CENTER_PROFILE_B64': encoded}, clear=True):
            capture(self.home / 'single-custom.json', '')
        after = Policy(self.home / 'single-custom.json').environment({'TZ': 'UTC0', 'TZDIR': '/wrong'})
        output = subprocess.check_output([sys.executable, '-c', 'import time; print(time.strftime("%z"))'],
                                         env=dict(os.environ, **after))
        self.assertEqual(output.strip(), b'+0300')
        self.env.update(TZ='custom.v1', TZDIR=str(zones))
        result = self.prepare(str(uuid.uuid4()), encoded)
        self.assertEqual(result.returncode, 0, result.stderr)
        view = json.loads(subprocess.check_output([str(self.gateway / 'session-info')]))
        self.assertEqual(view['identity']['effective_tz'], 'custom.v1')
        self.assertEqual(view['identity']['effective_tzdir'], str(zones))

    def test_native_legacy_requires_known_frozen_evidence_and_v3_never_downgrades(self):
        from fixtures.privacy import pre_policy_snapshot
        from orca_native import session_presentation, OrcaError
        pre_policy_snapshot(self.home)
        self.assertEqual(session_presentation(self.home, {}).version, 0)
        injector = self.home / 'impl' / 'inject-rule.sh'
        original = injector.read_bytes()
        injector.chmod(0o600)
        with self.assertRaises(OrcaError):
            session_presentation(self.home, {})
        injector.write_bytes(original + b'\n# changed\n')
        injector.chmod(0o500)
        with self.assertRaises(OrcaError):
            session_presentation(self.home, {})
        pre_policy_snapshot(self.home)
        marker = self.home / 'presentation-policy.json'
        marker.write_text('{"version":1,"presentation_policy":3}')
        marker.chmod(0o600)
        for content in (None, '{invalid}', '{"version":2,"timezone":""}'):
            self.cache.unlink(missing_ok=True)
            if content is not None:
                self.cache.write_text(content)
                self.cache.chmod(0o600)
            with self.assertRaises((OSError, ValueError, KeyError)):
                session_presentation(self.home, {'presentation_policy': 3})
        with self.assertRaises(OrcaError):
            session_presentation(self.home, {'presentation_policy': 2})


if __name__ == '__main__':
    unittest.main()
