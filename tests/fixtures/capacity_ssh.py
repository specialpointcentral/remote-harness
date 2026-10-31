#!/usr/bin/env python3
"""Controlled external SSH boundary; broker sockets/pipes/gateway remain real in tests."""
import base64
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

args = sys.argv[1:]
control = next(arg.split('=', 1)[1] for arg in args if arg.startswith('ControlPath='))
root = Path(os.environ['POOL_FIXTURE'])
mode = (root / 'mode').read_text().strip()

def event(kind):
    import fcntl
    with (root / 'events').open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps({'event': kind, 'pid': os.getpid(), 'time': time.monotonic()}) + '\n')

if '-O' in args:
    raise SystemExit(0)
if '-N' in args:
    event('master-start')
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(control)
    listener.listen(16)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        while True:
            time.sleep(10)
    finally:
        listener.close()
        try:
            os.unlink(control)
        except FileNotFoundError:
            pass

event('opening')
mux_only = 'ProxyCommand=false' in args
if not mux_only:
    event('fresh-connection-allowed')
if mode == 'capacity' or not Path(control).exists():
    if mux_only:
        event('capacity-refused')
        sys.stderr.write('mux_client_request_session: session request failed: Session open refused by peer\n')
        raise SystemExit(255)
    event('hidden-fresh-connection')
if mode == 'early-stderr-eof':
    # stderr ends first; a descendant keeps stdout open after this ssh itself exits.
    os.close(2)
    if os.fork() == 0:
        time.sleep(3)
        os._exit(0)
    time.sleep(.3)
    raise SystemExit(255)
if mode == 'hang-opening':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(10)
if mode in ('loss-ack', 'acked-drop'):
    print('RH_WAIT_READY', flush=True)
    request = sys.stdin.buffer.readline()
    if mode == 'acked-drop':
        print('RH_WAIT_GOT', flush=True)
    command = base64.b64decode(request.split()[3]).decode()
    subprocess.run(['/bin/sh', '-c', command], check=True)
    raise SystemExit(255 if mode == 'acked-drop' else 0)
if mode == 'delay-ready':
    time.sleep(.12)
env = dict(os.environ, SSH_ORIGINAL_COMMAND='remote-harness-wait', SHELL='/bin/sh')
os.execve(str(root / 'gateway' / 'bin' / 'project-host-gateway.sh'),
          ['project-host-gateway.sh', 'capacity'], env)
