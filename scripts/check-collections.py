#!/usr/bin/env python3
"""Accountless production-process check for collection negotiation and day selection."""
import json, os, selectors, subprocess, sys, time, uuid
from pathlib import Path
app = Path(sys.argv[1]).resolve()
session = str(uuid.uuid4())
p = subprocess.Popen([str(app/'Contents/MacOS/ModuleApp'), '--neronook-plugin', '--protocol-test'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
sel = selectors.DefaultSelector(); sel.register(p.stdout, selectors.EVENT_READ)
buffer = b''; last = -1

def send(**fields):
    fields.update(apiVersion=1, pluginID='cafe.nero.plugin.google', session=session, sequence=0)
    p.stdin.write((json.dumps(fields)+'\n').encode()); p.stdin.flush()

def snapshots():
    global buffer, last
    deadline = time.monotonic()+10
    while time.monotonic() < deadline:
        if p.poll() is not None: raise RuntimeError('Module exited')
        for key, _ in sel.select(.2):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data: raise RuntimeError('Unexpected EOF')
            buffer += data
            assert len(buffer) <= 262144
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1); m = json.loads(line)
                assert uuid.UUID(m['session']) == uuid.UUID(session)
                assert m['pluginID'] == 'cafe.nero.plugin.google' and m['sequence'] > last
                last = m['sequence']
                if m['type'] == 'snapshot': yield m['snapshot']
    raise RuntimeError('Collection response timed out')
try:
    send(type='hello', features=['panels-v1', 'collections-v1', 'agenda-v1'])
    first = next(snapshots())
    assert [p['collection']['layout'] for p in first['panels']] == ['calendar','inbox','tasks','files']
    assert all(not p['collection']['items'] for p in first['panels'])
    calendar = first['panels'][0]['collection']; assert len(calendar['days']) == 42
    target = calendar['days'][0]
    send(type='action', action=target['action']['id'])
    for snapshot in snapshots():
        if snapshot['panels'][0]['collection']['selectedDate'] == target['date']: break
    p.stdin.close(); p.wait(timeout=3); assert p.returncode == 0
    print('PASS: four semantic layouts, 42-day calendar, date action and clean EOF; no account/network loaded.')
finally:
    sel.close()
    if p.poll() is None: p.kill(); p.wait()
