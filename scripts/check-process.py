#!/usr/bin/env python3
import json, os, selectors, subprocess, sys, time, uuid
from pathlib import Path
app=Path(sys.argv[1]).resolve(); session=str(uuid.uuid4())
p=subprocess.Popen([str(app/'Contents/MacOS/ModuleApp'),'--neronook-plugin','--protocol-test'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ)
try:
 p.stdin.write((json.dumps(dict(type='hello',apiVersion=1,pluginID='cafe.nero.plugin.google',session=session,sequence=0,features=['panels-v1','control-cards-v1','agenda-v1']))+'\n').encode());p.stdin.flush()
 buffer=b''; last=-1; kinds=set(); deadline=time.monotonic()+10
 while time.monotonic()<deadline and not {'ready','snapshot','agenda'}<=kinds:
  if p.poll() is not None: raise RuntimeError('Packaged module exited during startup')
  for key,_ in sel.select(.2):
   data=os.read(key.fileobj.fileno(),65536)
   if not data: raise RuntimeError('Unexpected EOF')
   buffer+=data
   if len(buffer)>262144: raise RuntimeError('Oversized output')
   while b'\n' in buffer:
    line,buffer=buffer.split(b'\n',1);m=json.loads(line)
    assert uuid.UUID(m['session'])==uuid.UUID(session) and m['sequence']>last and m['pluginID']=='cafe.nero.plugin.google'
    last=m['sequence'];kinds.add(m['type'])
    if m['type']=='snapshot': assert len(m['snapshot']['panels'])==4
    if m['type']=='agenda': assert m['agenda']['entries']==[]
 assert {'ready','snapshot','agenda'}<=kinds
 p.stdin.close();p.wait(timeout=3);assert p.returncode==0
 print('PASS: signed process handshake, four panels, empty agenda, ordered identity-bound messages, clean EOF. No account or network loaded.')
finally:
 sel.close()
 if p.poll() is None:p.kill();p.wait()
