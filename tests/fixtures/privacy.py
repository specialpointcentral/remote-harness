"""Synthetic policy: never copy machine identifiers into test output."""
import json
import base64
import subprocess
import tempfile
from pathlib import Path
import sys


def policy(session, timezone='Asia/Seoul'):
    path = session / 'privacy.json'
    path.write_text(json.dumps({'version': 2, 'timezone': timezone,
                               'project': {'hostname': 'project-kr.example', 'ipv4': '192.0.2.80',
                                           'timezone': timezone, 'country': 'KR', 'region': 'kr-local'},
                               'identifiers': {'203.0.113.45': '192.0.2.80',
                                               'agent-hk-private.example': 'project-kr.example'},
                               'deny_paths': ['/etc/localtime', '/etc/timezone', '/etc/hostname', '/proc']}))
    path.chmod(0o600)
    manifest = session / 'presentation-policy.json'
    if manifest.exists():
        manifest.write_text(json.dumps({'version': 1, 'presentation_policy': 2}))
    return path


def bind_v3(session, home, project='/project', presentation_id=None, agent='claude'):
    """Run the actual project-owned adapter before a freshly injected fixture starts its agent."""
    scripts = Path(__file__).resolve().parents[2] / 'scripts'
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    from session_privacy import (Policy, private_json, profile_lines, select_presentation, bind_presentation)
    cache = session / 'privacy.json'
    if presentation_id:
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            select_presentation(cache, home, presentation_id, agent)
    identity = private_json(cache)['presentation_id']
    gateway = Path(tempfile.mkdtemp(prefix='project-gateway-', dir=home))
    profile = base64.b64encode(profile_lines(Policy(cache).project).encode()).decode()
    summary = subprocess.check_output(['bash', str(scripts / 'project-session-info.sh'), 'prepare',
        str(gateway), str(home / 'project-tables'), str(project), identity, profile], text=True).strip()
    bind_presentation(cache, home, summary)
    return identity, gateway


def pre_policy_snapshot(session):
    """Immutable released source bytes, used only as identity evidence, never executed."""
    impl = session / 'impl'
    impl.mkdir(mode=0o700, exist_ok=True)
    impl.chmod(0o700)
    for path in (session / 'privacy.json', session / 'presentation-policy.json', impl / 'session_privacy.py'):
        path.unlink(missing_ok=True)
    injector = impl / 'inject-rule.sh'
    if injector.exists():
        injector.chmod(0o600)
    injector.write_bytes(Path(__file__).with_name('pre-policy-injector.txt').read_bytes())
    injector.chmod(0o500)
