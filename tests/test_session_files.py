#!/usr/bin/env python3
"""Check private session creation and cleanup without SSH or a real project mount."""
import base64
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'


def encoded(value):
    return base64.b64encode(str(value).encode()).decode()


class SessionFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-private-', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.rh = self.home / '.remote-harness'
        self.sessions = self.rh / '.sessions'
        self.project = self.home / 'project'
        self.project.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RH_') and key not in ('BASH_ENV', 'ENV')}
        self.env.update(HOME=str(self.home), RH_HOME=str(self.rh), RH_WARM_MAX='0',
                        RH_COMMON=str(SCRIPTS / '_common.sh'))

    def run_shell(self, body, **env):
        result = subprocess.run(['bash', '-uc', 'umask 000; ' + body],
                                env=dict(self.env, **env), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assert_private(self, path, mode):
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode, str(path))

    def metadata(self, directory, **values):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'session.env').write_text(''.join(
            f'{key}={encoded(value)}\n' for key, value in values.items()))

    def owner(self, directory, live=False):
        start = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='],
                                        text=True).strip()
        (directory / 'owner.env').write_text(
            f'OWNER_PID={os.getpid() if live else 999999999}\nOWNER_START={encoded(start)}\n')

    def age(self, path, days=10):
        old = time.time() - days * 86400
        os.utime(path, (old, old))

    def reaper(self, *args, **env):
        result = subprocess.run([str(SCRIPTS / 'session-reaper.sh'), *map(str, args)],
                                env=dict(self.env, **env), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def local_library(self):
        library = self.home / 'laptop-library.sh'
        library.write_text((SCRIPTS / 'laptop-setup.sh').read_text().split('# OS vars (OS/PLAT/IS_WSL)')[0])
        return 'set -- --port 25292; . ' + shlex.quote(str(library)) + '; '

    def test_tunnel_state_is_private_during_key_generation_and_on_reuse(self):
        bindir = self.home / 'bin'
        bindir.mkdir()
        keygen = bindir / 'ssh-keygen'
        keygen.write_text(f'''#!{sys.executable}
import json, os, pathlib, stat, sys
key = pathlib.Path(sys.argv[sys.argv.index('-f') + 1])
paths = [key.parent, key.parent / 'ssh_config', key.parent / 'runtime']
pathlib.Path(os.environ['MODE_REPORT']).write_text(json.dumps([stat.S_IMODE(p.stat().st_mode) for p in paths]))
key.write_text('private key')
pathlib.Path(str(key) + '.pub').write_text('public key')
''')
        keygen.chmod(0o700)
        cfg = self.sessions / 'transport' / 'ssh_config'
        report = self.home / 'modes.json'
        command = shlex.join([str(SCRIPTS / 'setup-tunnel.sh'), '--config', str(cfg),
                              '--alias', 'fixture', '--user', 'fixture', '--port', '25292', '--gen-key'])
        self.run_shell(command, PATH=str(bindir) + os.pathsep + self.env['PATH'], MODE_REPORT=str(report))
        self.assertEqual(json.loads(report.read_text()), [0o700, 0o600, 0o700])
        known = cfg.parent / 'runtime' / 'known_hosts_fixture'
        known.write_text('host key')
        for path in (cfg, cfg.parent / 'id_ed25519', cfg.parent / 'id_ed25519.pub', known):
            path.chmod(0o666)
        cfg.parent.chmod(0o777)
        self.sessions.chmod(0o777)
        (cfg.parent / 'runtime').chmod(0o777)
        self.run_shell(command)
        for path in (cfg, cfg.parent / 'id_ed25519', cfg.parent / 'id_ed25519.pub', known):
            self.assert_private(path, 0o600)
        self.assert_private(cfg.parent / 'runtime', 0o700)
        self.assert_private(cfg.parent, 0o700)
        self.assert_private(self.sessions, 0o700)

    def test_custom_config_and_unrelated_parent_permissions_are_preserved(self):
        for parent in (self.home / 'user-configs', self.sessions / 'custom' / 'nested'):
            with self.subTest(parent=parent):
                parent.mkdir(parents=True, mode=0o775)
                parent.chmod(0o775)
                sentinel = parent / 'unrelated'
                sentinel.write_text('unchanged')
                sentinel.chmod(0o644)
                # A reused default identity still belongs to the configured harness, while its
                # custom parent is not a direct-child harness transport directory.
                (parent / 'id_ed25519').write_text('existing default key')
                cfg = parent / 'ssh_config'
                self.run_shell(shlex.join([str(SCRIPTS / 'setup-tunnel.sh'), '--config', str(cfg),
                                           '--alias', 'fixture', '--user', 'fixture', '--port', '25292']))
                self.assert_private(parent, 0o775)
                self.assert_private(sentinel, 0o644)
                self.assertEqual(sentinel.read_text(), 'unchanged')

    def test_setup_rejects_symlinks_without_touching_the_target(self):
        transport = self.sessions / 'transport'
        transport.mkdir(parents=True)
        sentinel = self.home / 'user-config'
        sentinel.write_text('keep this')
        sentinel.chmod(0o644)
        cfg = transport / 'ssh_config'
        cfg.symlink_to(sentinel)
        result = subprocess.run([str(SCRIPTS / 'setup-tunnel.sh'), '--config', str(cfg),
                                 '--alias', 'fixture', '--user', 'fixture', '--port', '25292'],
                                env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'keep this')
        self.assert_private(sentinel, 0o644)

    def test_explicit_user_identity_symlink_is_read_only(self):
        identity = self.home / 'user-keys' / 'identity'
        identity.parent.mkdir(mode=0o755)
        identity.write_text('user private key')
        identity.chmod(0o640)
        link = identity.parent / 'selected-key'
        link.symlink_to(identity)
        cfg = self.sessions / 'transport' / 'ssh_config'
        self.run_shell(shlex.join([str(SCRIPTS / 'setup-tunnel.sh'), '--config', str(cfg),
                                   '--alias', 'fixture', '--user', 'fixture', '--port', '25292',
                                   '--identity', str(link), '--gen-key']))
        self.assertEqual(identity.read_text(), 'user private key')
        self.assert_private(identity, 0o640)
        self.assert_private(identity.parent, 0o755)
        self.assertTrue(link.is_symlink())

    def test_injection_and_launcher_preserve_private_records_and_agent_umask(self):
        cfg = self.sessions / 'transport' / 'ssh_config'
        cfg.parent.mkdir(parents=True)
        cfg.write_text('Host fixture\n')
        result = self.run_shell(shlex.join([str(SCRIPTS / 'inject-rule.sh'), 'on', 'codex',
                                            '/project', 'fixture', str(self.project), 'normal', str(cfg), 'one']))
        values = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        session = Path(values['RH_SESSION_DIR'])
        self.assert_private(self.sessions, 0o700)
        for path in session.rglob('*'):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode) & 0o077, 0, str(path))
        self.assert_private(session, 0o700)
        # Keep this launcher test independent of watcher timing and transport health.
        reaper = session / 'impl' / 'session-reaper.sh'
        reaper.chmod(0o700)
        reaper.write_text('#!/bin/sh\nexit 0\n')
        artifact = self.project / 'normal-project-file'
        agent = ('import json,os,pathlib,subprocess; '
                 'mask=os.umask(0); os.umask(mask); '
                 f'pathlib.Path({str(artifact)!r}).write_text("normal"); '
                 'print(json.dumps({"pid":os.getpid(), "mask":mask, '
                 '"start":subprocess.check_output(["ps","-p",str(os.getpid()),"-o","lstart="],text=True).strip()}))')
        launched = self.run_shell(shlex.join([str(session / 'bin' / 'rh-session'), sys.executable, '-c', agent]))
        observed = json.loads(launched.stdout)
        owner = dict(line.split('=', 1) for line in (session / 'owner.env').read_text().splitlines())
        self.assertEqual(int(owner['OWNER_PID']), observed['pid'])
        self.assertEqual(base64.b64decode(owner['OWNER_START']).decode(), observed['start'])
        self.assertEqual(observed['mask'], 0)
        self.assert_private(artifact, 0o666)
        self.assert_private(session / 'owner.env', 0o600)

    def test_runtime_privacy_failure_cleans_partial_injection(self):
        cfg = self.sessions / 'transport' / 'ssh_config'
        cfg.parent.mkdir(parents=True)
        cfg.write_text('Host fixture\n')
        outside = self.home / 'user-runtime'
        outside.mkdir(mode=0o755)
        (cfg.parent / 'runtime').symlink_to(outside, target_is_directory=True)
        result = subprocess.run([str(SCRIPTS / 'inject-rule.sh'), 'on', 'codex', '/project',
                                 'fixture', str(self.project), 'normal', str(cfg), 'bad'],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        # Every launch also starts the session GC, detached; it may still hold its lock here.
        lock, deadline = self.sessions / '.resources.lock', time.monotonic() + 10
        while lock.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(list(self.sessions.iterdir()), [cfg.parent])
        self.assert_private(outside, 0o755)

    def test_reaper_library_writes_privately_without_leaking_umask(self):
        session = self.sessions / 'disconnected'
        self.metadata(session, AGENT='codex', MOUNTPOINT='/project')
        script = shlex.quote(str(SCRIPTS / 'session-reaper.sh'))
        body = (f'RH_REAPER_LIBRARY=1 . {script}; resource_lock; '
                'register_mount_lease example /project /config /config fixture; '
                f'mark_disconnected {shlex.quote(str(session))} heartbeat; '
                'printf "MASK=%s\\n" "$(umask)"; '
                'python3 -c ' + shlex.quote('import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))') +
                ' "$RESOURCE_LOCK/owner"; resource_unlock')
        result = self.run_shell(body)
        self.assertIn('MASK=0000', result.stdout)
        self.assertIn('600', result.stdout)
        for directory in (self.sessions, self.sessions / 'lease.example', self.sessions / '.mounts', self.sessions / '.resume'):
            self.assert_private(directory, 0o700)
        for path in (self.sessions / 'lease.example' / 'lease.env',
                     *list((self.sessions / '.mounts').iterdir()), *list((self.sessions / '.resume').iterdir())):
            self.assert_private(path, 0o600)

    def test_gc_reclaims_dead_state_and_owned_temps_but_preserves_live_shared_state(self):
        cfg = self.sessions / 'shared-transport' / 'ssh_config'
        cfg.parent.mkdir(parents=True)
        cfg.write_text('Host fixture\n')
        shared_temp = cfg.parent / '.rh-cfg.shared'
        shared_temp.write_text('still used')
        live = self.sessions / 'live'
        dead = self.sessions / 'dead'
        for session in (live, dead):
            self.metadata(session, SSH_CONFIG=cfg)
            (session / 'warm.log').write_text('session diagnostics')
        self.owner(live, live=True)
        self.owner(dead)
        orphan = self.sessions / 'orphan-transport'
        orphan.mkdir()
        orphan_cfg = orphan / 'ssh_config'
        orphan_cfg.write_text('Host orphan\n')
        self.age(orphan_cfg)
        self.age(cfg)
        owned_names = ('.rh-strip.old', '.rh-cfg.old', 'ssh_config.rh-strip.123', 'ssh_config.rh-new.123')
        for name in owned_names:
            (orphan / name).write_text('private old config')
        sentinel = orphan / 'unrelated'
        sentinel.write_text('keep')
        outside = self.home / 'outside'
        outside.write_text('outside')
        (orphan / '.rh-cfg.link').symlink_to(outside)
        resume = self.sessions / '.resume'
        resume.mkdir()
        (resume / 'old').write_text('old marker')
        (resume / 'fresh').write_text('fresh marker')
        self.age(resume / 'old')
        self.reaper('gc')
        self.assertFalse(dead.exists())
        self.assertTrue((live / 'warm.log').exists())
        self.assertTrue(cfg.exists())
        self.assertTrue(shared_temp.exists())
        self.assertFalse(orphan_cfg.exists())
        for name in owned_names:
            self.assertFalse((orphan / name).exists())
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertEqual(outside.read_text(), 'outside')
        self.assertFalse((resume / 'old').exists())
        self.assertTrue((resume / 'fresh').exists())

    def test_held_implementation_survives_failed_mount_release_then_is_reclaimed(self):
        session = self.sessions / 'held'
        cfg = self.sessions / 'held-transport' / 'ssh_config'
        cfg.parent.mkdir(parents=True)
        cfg.write_text('Host fixture\n')
        self.metadata(session, MOUNTPOINT=self.project, SSH_CONFIG=cfg)
        self.owner(session)
        impl = session / 'impl'
        impl.mkdir()
        tool = impl / 'mount-project.sh'
        tool.write_text('#!/bin/sh\n[ "${FAIL_UNMOUNT:-0}" != 1 ] || exit 1\nprintf "STATUS=unmounted\\n"\n')
        tool.chmod(0o700)
        script = shlex.quote(str(SCRIPTS / 'session-reaper.sh'))
        self.run_shell(f'RH_REAPER_LIBRARY=1 . {script}; resource_lock; '
                       'private_session_dirs "$SESSIONS/.mounts"; '
                       f'record=$(mount_record {shlex.quote(str(self.project))}); '
                       f'printf "MOUNTPOINT=%s\\nSSH_CONFIG=%s\\nIMPLEMENTATION=%s\\n" '
                       f'{encoded(self.project)} {encoded(cfg)} {encoded(impl)} > "$record"; resource_unlock')
        self.reaper('gc', FAIL_UNMOUNT='1')
        self.assertTrue(tool.exists())
        self.assertTrue(cfg.exists())
        self.reaper('gc')
        self.assertFalse(session.exists())
        self.assertFalse(cfg.exists())

    def test_local_records_and_resume_sweep_respect_live_and_shared_sessions(self):
        library = self.local_library()
        body = (library + 'private_local_dirs "$HOME/.remote-harness/.sessions"; '
                'LOCAL_SESSION_DIR="$HOME/.remote-harness/.sessions/rev.writer"; '
                'private_local_dirs "$LOCAL_SESSION_DIR"; '
                'for field in $RESOURCE_FIELDS; do printf -v "$field" %s ""; done; '
                'TARGET=fixture BOX_SSH_CONFIG=/remote/config; write_local_resource_record; '
                'printf "MASK=%s\\n" "$(umask)"')
        self.assertIn('MASK=0000', self.run_shell(body).stdout)
        self.assert_private(self.sessions / 'rev.writer' / 'resources.env', 0o600)
        self.assert_private(self.sessions, 0o700)
        resume = self.sessions / '.resume'
        resume.mkdir()
        for name in ('old', 'fresh'):
            (resume / name).write_text('marker')
        self.age(resume / 'old')
        # The current test process is the live launcher; dead/shared state keeps its record when
        # the remote release answer says another session still owns the transport.
        for name, live in (('live', True), ('shared', False), ('dead', False)):
            directory = self.sessions / f'rev.{name}'
            directory.mkdir()
            start = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='], text=True).strip()
            (directory / 'resources.env').write_text(
                f'OWNER_PID={os.getpid() if live else 999999999}\nOWNER_START={encoded(start)}\n'
                f'TARGET={encoded(name)}\nBOX_SSH_CONFIG={encoded("/config")}\n')
            (directory / 'inject.err').write_text('diagnostic')
        self.run_shell(library + '''
remote_config_usage() { [ "$TARGET" = dead ] && return 1; return 0; }
cleanup_reverse_authorized_key() { return 0; }
tunnel_state_path() { printf '%s' "$HOME/no-tunnel-state"; }
sweep_local_resources
''')
        self.assertTrue((self.sessions / 'rev.live' / 'inject.err').exists())
        self.assertTrue((self.sessions / 'rev.shared' / 'inject.err').exists())
        self.assertFalse((self.sessions / 'rev.dead').exists())
        self.assertFalse((resume / 'old').exists())
        self.assertTrue((resume / 'fresh').exists())

    def test_local_record_follows_every_change_of_a_reused_encoding(self):
        # Each value's encoding is reused while it stays the same; every change must reach the record.
        body = self.local_library() + r'''
LOCAL_SESSION_DIR="$HOME/.remote-harness/.sessions/rev.changes"
private_local_dirs "$HOME/.remote-harness/.sessions" "$LOCAL_SESSION_DIR"
for field in $RESOURCE_FIELDS; do printf -v "$field" %s ""; done
record="$LOCAL_SESSION_DIR/resources.env"
show() {
  local $RESOURCE_FIELDS
  load_resource_record "$record"
  [ "$LOCAL_SSHD_CFG" = "$expected" ] && same=yes || same=no
  printf '%s|%s|%s|%s\n' "$TARGET" "$TUNNEL_PID" "$(resource_value "$record" TUNNEL_PID)" "$same"
}
expected=""
TARGET=box TUNNEL_PID=100; write_local_resource_record; show
TUNNEL_PID=200; write_local_resource_record; show
expected=$'it\'s 50% "done"\nnext line'
TUNNEL_PID="" LOCAL_SSHD_CFG=$expected; write_local_resource_record; show
TUNNEL_PID=100; write_local_resource_record; show
'''
        self.assertEqual(self.run_shell(body).stdout.splitlines(),
                         ['box|100|100|yes', 'box|200|200|yes', 'box|||yes', 'box|100|100|yes'])
        self.assert_private(self.sessions / 'rev.changes' / 'resources.env', 0o600)

    def test_warm_broker_restricts_existing_files_and_refuses_symlink_targets(self):
        directory = self.home / 'warm'
        directory.mkdir()
        log = directory / 'warm.log'
        sock = directory / 'pool'
        lock = directory / 'pool.lock'
        command = [sys.executable, str(SCRIPTS / 'warm_pool.py'), 'serve',
                   '--socket', str(sock), '--control-path', str(directory / 'mux'),
                   '--ssh-config', str(directory / 'ssh_config'), '--alias', 'fixture',
                   '--owner-pid', '999999999', '--session-dir', str(directory), '--log', str(log)]
        for path in (log, lock):
            path.write_text('old')
            path.chmod(0o666)
        result = subprocess.run(command, env=dict(self.env, RH_WARM_MAX='1'),
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private(log, 0o600)
        self.assert_private(lock, 0o600)
        sentinel = self.home / 'user-file'
        sentinel.write_text('unchanged')
        sentinel.chmod(0o644)
        for path in (log, lock):
            with self.subTest(path=path.name):
                path.unlink()
                path.symlink_to(sentinel)
                result = subprocess.run(command, env=dict(self.env, RH_WARM_MAX='1'),
                                        capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sentinel.read_text(), 'unchanged')
                self.assert_private(sentinel, 0o644)
                path.unlink()
                path.write_text('owned')

    def test_wizard_cache_setup_does_not_change_the_callers_umask(self):
        library = self.home / 'wizard-library.sh'
        library.write_text((SCRIPTS / 'simple-laptop-setup.sh').read_text().split('\nVIA="" LAUNCH=')[0])
        result = self.run_shell('. ' + shlex.quote(str(library)) + '; '
                                'VIA=fixture PROJECT_DIR=/project REMOTE_MP=/mount LAUNCH=codex '
                                'APPROVAL=normal LOCAL_SSHD=system; cache_save; '
                                'printf "MASK=%s\\n" "$(umask)"')
        self.assertIn('MASK=0000', result.stdout)
        self.assert_private(self.rh, 0o700)
        self.assert_private(self.rh / 'simple-cache.env', 0o600)


if __name__ == '__main__':
    unittest.main()
