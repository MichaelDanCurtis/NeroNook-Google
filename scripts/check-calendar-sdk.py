#!/usr/bin/env python3
"""Accountless check of the signed calendar action adapter and clean EOF."""
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

def until(predicate):
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
                if predicate(m): return m
    raise RuntimeError('Calendar adapter response timed out')

try:
    send(type='hello', features=['panels-v1', 'agenda-v1', 'actions-v1'])
    ready = until(lambda m: m['type'] == 'ready')
    assert ready['sequence'] == 0 and 'actions-v1' in ready['features']
    registration = until(lambda m: m['type'] == 'bus' and m['bus']['operation'] == 'register')['bus']['registration']
    actions = {a['id']: a for a in registration['actions']}
    assert set(actions) == {'list_calendar_events', 'read_calendar_event'}
    for action in actions.values():
        assert action['effect'] == 'readOnly' and action['cancellable'] and action['timeoutSeconds'] == 60
    assert [f['name'] for f in actions['list_calendar_events']['input']['fields']] == ['start', 'end', 'offset']
    assert [f['name'] for f in actions['read_calendar_event']['input']['fields']] == ['reference']
    request = str(uuid.uuid4())
    send(type='bus', bus=dict(operation='execute', requestID=request, address=dict(plugin='cafe.nero.plugin.google', name='list_calendar_events'), values=dict(start=1791846000, end=1791932400, offset=0)))
    result = until(lambda m: m['type'] == 'bus' and m['bus']['operation'] == 'update' and uuid.UUID(m['bus']['requestID']) == uuid.UUID(request))
    assert result['bus']['update']['phase'] == 'failed'  # test mode never loads credentials/network
    p.stdin.close(); p.wait(timeout=3); assert p.returncode == 0
    print('PASS: negotiated two read-only calendar actions, accountless execution refused, ordered messages and clean EOF.')
finally:
    sel.close()
    if p.poll() is None: p.kill(); p.wait()
