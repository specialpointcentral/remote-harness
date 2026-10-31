#!/usr/bin/env python3
"""Behavior checks for project-host command cancellation and capture timeouts."""
import base64
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / 'scripts/run-on-project-host.sh'


def encoded(value):
    return base64.b64encode(str(value).encode()).decode()


def processes():
    result = subprocess.run(['ps', '-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'stat='],
                            text=True, capture_output=True, check=True)
    return {int(pid): (int(parent), state) for pid, parent, state in
            (line.split() for line in result.stdout.splitlines())}


def active(pid):
    row = processes().get(pid)
    return row is not None and not row[1].startswith('Z')


def descendants(pid):
    rows = processes()
    found = {pid}
    while True:
        more = {child for child, (parent, _) in rows.items() if parent in found}
        if more <= found:
            return found - {pid}
        found |= more


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class DispatchLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rh-dispatch-lifecycle-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.pids = set()
        self.addCleanup(self.stop_remaining)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('RH_') and key not in ('BASH_ENV', 'ENV')}
        self.env.update(SHELL='/bin/sh', HOME=str(self.path))
        self.worker = self.path / 'worker.py'
        self.worker.write_text('''import os, signal, sys, time
from pathlib import Path
if sys.argv[1] == "detached":
    os.setsid()
if sys.argv[1] in ("ignore", "detached"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[2]).write_text(str(os.getpid()))
if sys.argv[1] == "normal":
    while not Path(sys.argv[3]).exists():
        time.sleep(0.01)
else:
    time.sleep(60)
''')

    def stop_remaining(self):
        for pid in self.pids:
            if active(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def worker_command(self, mode, marker, *args):
        return shlex.join([sys.executable, str(self.worker), mode, str(marker), *map(str, args)])

    def watched(self, command):
        proc = subprocess.Popen(['sh', str(DISPATCHER), '--dispatch', encoded(self.path),
                                 encoded('.'), encoded(command), 'watch'],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=self.env)
        self.pids.add(proc.pid)
        self.addCleanup(self.close_process, proc)
        return proc

    def close_process(self, proc):
        if proc.poll() is None:
            self.pids.update(descendants(proc.pid))
            proc.kill()
            proc.wait(timeout=5)
        for pipe in (proc.stdin, proc.stdout, proc.stderr):
            if pipe and not pipe.closed:
                pipe.close()

    def await_markers(self, *markers):
        self.assertTrue(wait_for(lambda: all(marker.exists() and marker.stat().st_size
                                            for marker in markers)),
                        'worker did not become ready')
        for marker in markers:
            self.pids.add(int(marker.read_text()))

    def assert_workers_stopped(self, *markers):
        for marker in markers:
            self.assertFalse(active(int(marker.read_text())),
                             f'worker {marker.name} survived runner completion')

    def test_channel_close_finishes_kill_escalation_after_root_exits(self):
        ordinary, detached = self.path / 'ordinary.pid', self.path / 'detached.pid'
        command = (self.worker_command('ignore', ordinary) + ' & '
                   + self.worker_command('detached', detached) + ' & wait')
        proc = self.watched(command)
        self.await_markers(ordinary, detached)
        self.pids.update(descendants(proc.pid))
        proc.stdin.close()
        self.assertEqual(proc.wait(timeout=9), 143)
        self.assert_workers_stopped(ordinary, detached)
        self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                        'watchdog or channel reader survived cancellation')

    def test_normal_completion_keeps_channel_open_status_and_no_reader(self):
        marker, release = self.path / 'normal.pid', self.path / 'release'
        proc = self.watched(self.worker_command('normal', marker, release)
                            + '; printf normal; exit 7')
        self.await_markers(marker)
        self.assertTrue(wait_for(lambda: len(descendants(proc.pid)) >= 3),
                        'watchdog and channel reader did not become ready')
        self.pids.update(descendants(proc.pid))
        release.touch()
        # stdin deliberately stays open: success must stop and reap the blocked channel reader.
        self.assertEqual(proc.wait(timeout=2), 7)
        self.assertEqual(proc.stdout.read(), 'normal')
        self.assertEqual(proc.stderr.read(), '')
        self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                        'watchdog or channel reader survived normal completion')

    def test_dispatcher_signal_finishes_cleanup_before_removing_claim_state(self):
        marker = self.path / 'signal.pid'
        proc = self.watched(self.worker_command('detached', marker) + ' & wait')
        self.await_markers(marker)
        self.pids.update(descendants(proc.pid))
        proc.terminate()
        self.assertEqual(proc.wait(timeout=9), 143)
        self.assert_workers_stopped(marker)
        self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                        'watchdog or channel reader survived dispatcher termination')

    def timeout_runner(self, command, seconds):
        # Exercise the actual timeout functions without waiting 30s for a shell snapshot capture.
        # These definitions are the exact prefix used by the real dispatcher; only dispatch setup
        # and snapshot selection are omitted, and the private guard directory is supplied here.
        definitions = DISPATCHER.read_text().split('# --- Login shell snapshot', 1)[0]
        guard = self.path / 'guard'
        guard.mkdir()
        marker = self.path / 'timed-out'
        script = definitions + '\nguard_path=$1; shift\nrun_with_timeout "$@"\n'
        proc = subprocess.Popen(['sh', '-c', script, 'test-timeout', str(guard), str(seconds),
                                 str(marker), '/bin/sh', '-c', command],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=self.env)
        self.pids.add(proc.pid)
        self.addCleanup(self.close_process, proc)
        return proc, marker, guard

    def test_timeout_finishes_kill_escalation_and_records_timeout(self):
        worker_pid = self.path / 'timeout.pid'
        proc, timeout_marker, guard = self.timeout_runner(
            self.worker_command('detached', worker_pid) + ' & wait', 1)
        self.await_markers(worker_pid)
        self.pids.update(descendants(proc.pid))
        self.assertEqual(proc.wait(timeout=9), 143)
        self.assertTrue(timeout_marker.exists())
        self.assert_workers_stopped(worker_pid)
        self.assertEqual(list(guard.iterdir()), [])
        self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                        'timeout helper survived escalation')

    def test_timeout_normal_completion_preserves_status_and_stops_timer(self):
        worker_pid, release = self.path / 'normal-timeout.pid', self.path / 'release'
        proc, marker, guard = self.timeout_runner(
            self.worker_command('normal', worker_pid, release) + '; printf fast; exit 7', 60)
        self.await_markers(worker_pid)
        self.assertTrue(wait_for(lambda: len(descendants(proc.pid)) >= 3),
                        'timeout helper and timer did not become ready')
        self.pids.update(descendants(proc.pid))
        started = time.monotonic()
        release.touch()
        self.assertEqual(proc.wait(timeout=2), 7)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(proc.stdout.read(), 'fast')
        self.assertFalse(marker.exists())
        self.assertEqual(list(guard.iterdir()), [])
        self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                        'timeout helper or timer survived normal completion')

    def test_helper_stop_signal_before_wait_does_not_lose_wakeup(self):
        definitions = DISPATCHER.read_text().split('# --- Login shell snapshot', 1)[0]
        for helper, child, claim in (('rw', 'reader', 'watch'), ('rwt', 'sleep', 'timeout')):
            with self.subTest(helper=helper):
                guard = self.path / helper
                guard.mkdir()
                original = f'if [ "$_{helper}_stopped" = 0 ]; then wait "$_{helper}_{child}" || true; fi'
                # Force the narrow scheduling window without adding production test hooks: the
                # branch has been chosen, then TERM arrives immediately before wait starts. The
                # completion claim prevents the caller from masking the bug with a second TERM.
                injected = f'''if [ "$_{helper}_stopped" = 0 ]; then
      mkdir "$_{helper}_claim"
      kill -s TERM "$(/bin/sh -c 'printf %s "$PPID"')"
      : > "$guard_path/signal-injected"
      wait "$_{helper}_{child}" || true
    fi'''
                self.assertIn(original, definitions)
                functions = definitions.replace(original, injected, 1)
                command = '/bin/sh -c \'while [ ! -f "$1/signal-injected" ]; do sleep 0.01; done; exit 7\' test "$guard_path"'
                invocation = 'run_watched ' if claim == 'watch' else 'run_with_timeout 60 "$guard_path/timed-out" '
                script = functions + '\nguard_path=$1\n' + invocation + command + '\n'
                proc = subprocess.Popen(['sh', '-c', script, 'pre-wait-test', str(guard)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.env)
                self.pids.add(proc.pid)
                self.addCleanup(self.close_process, proc)
                self.assertTrue(wait_for(lambda: (guard / 'signal-injected').exists()))
                self.pids.update(descendants(proc.pid))
                self.assertEqual(proc.wait(timeout=2), 7)
                self.assertEqual(proc.stderr.read(), '')
                self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                                'pre-wait stop left a helper child alive')

    def test_repeated_fast_completion_stops_readers_and_timers(self):
        definitions = DISPATCHER.read_text().split('# --- Login shell snapshot', 1)[0]
        guard = self.path / 'repeat'
        guard.mkdir()
        script = definitions + '''
guard_path=$1
i=0
# The pre-wait and inherited-TERM tests force both known race windows; keep a short
# scheduling smoke test here without repeating full stress validation in every suite run.
while [ "$i" -lt 10 ]; do
  status=0
  run_watched /bin/sh -c "exit 7" || status=$?
  [ "$status" = 7 ] || exit 90
  status=0
  run_with_timeout 60 "$guard_path/timed-out" /bin/sh -c "exit 7" || status=$?
  [ "$status" = 7 ] || exit 91
  i=$((i + 1))
done
printf done
'''
        proc = subprocess.Popen(['sh', '-c', script, 'repeat-test', str(guard)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=self.env)
        self.pids.add(proc.pid)
        self.addCleanup(self.close_process, proc)
        self.assertEqual(proc.wait(timeout=10), 0)
        self.assertEqual(proc.stdout.read(), 'done')
        self.assertEqual(proc.stderr.read(), '')
        self.assertEqual(list(guard.iterdir()), [])

    def test_helper_children_with_inherited_ignored_term_are_stopped(self):
        definitions = DISPATCHER.read_text().split('# --- Login shell snapshot', 1)[0]
        for helper in ('watch', 'timeout'):
            with self.subTest(helper=helper):
                guard = self.path / ('ignored-' + helper)
                guard.mkdir()
                # A signal during fork/exec can meet the child shells inherited disposition.
                # Make that startup outcome deterministic while keeping the real relay/timer.
                if helper == 'watch':
                    original = 'cat <&3 >/dev/null 2>&1 &'
                    replacement = '/bin/sh -c \'trap "" TERM; : > "$1/helper-ready"; exec cat\' test "$guard_path" <&3 >/dev/null 2>&1 &'
                    invocation = 'run_watched '
                else:
                    original = 'sleep "$_rwt_seconds" &'
                    replacement = '/bin/sh -c \'trap "" TERM; : > "$1/helper-ready"; exec sleep "$2"\' test "$guard_path" "$_rwt_seconds" &'
                    invocation = 'run_with_timeout 60 "$guard_path/timed-out" '
                self.assertIn(original, definitions)
                functions = definitions.replace(original, replacement, 1)
                command = '/bin/sh -c \'while [ ! -f "$1/helper-ready" ]; do sleep 0.01; done; exit 7\' test "$guard_path"'
                script = functions + '\nguard_path=$1\n' + invocation + command + '\n'
                proc = subprocess.Popen(['sh', '-c', script, 'ignored-term-test', str(guard)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.env)
                self.pids.add(proc.pid)
                self.addCleanup(self.close_process, proc)
                self.assertTrue(wait_for(lambda: (guard / 'helper-ready').exists()))
                self.pids.update(descendants(proc.pid))
                self.assertEqual(proc.wait(timeout=2), 7)
                self.assertEqual(proc.stderr.read(), '')
                self.assertTrue(wait_for(lambda: not any(active(pid) for pid in self.pids)),
                                'private relay or timer survived inherited TERM disposition')


if __name__ == '__main__':
    unittest.main()
