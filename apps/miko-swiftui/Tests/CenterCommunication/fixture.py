#!/usr/bin/env python3
import sys,json,time,os
for line in sys.stdin:
 r=json.loads(line); m=r['method']; p=r.get('params',{}); i=r['id']
 with open(os.path.join(os.environ['MIKO_HOME'],'requests.log'),'a') as f: f.write(json.dumps({'pid':os.getpid(),'method':m,'seq':p.get('seq')})+'\n')
 if m=='test.disconnect': os._exit(0)
 if m=='test.hold': continue
 result={'device.list':[], 'jobs.list':[], 'sync.status':{'session':None}, 'center.paths':{'data':os.path.join(os.environ['MIKO_HOME'], 'data')}, 'center.prefs.get':{'language':1,'appearance':0,'record_audio':True}}.get(m, {'seq':p.get('seq')})
 print(json.dumps({'id':i,'type':'result','result':result}),flush=True)
 if m=='test.pause': time.sleep(0.5)
