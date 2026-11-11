#!/usr/bin/env python3
"""Exercise the real bridge and a disposable Android input fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import threading
import time

ROOT=Path(__file__).resolve().parents[1]
PACKAGE='local.jidr.inputprobe'


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device',required=True);p.add_argument('--apk',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    home=Path(os.environ.get('JIDR_HOME',''))
    if not home.is_absolute() or not home.name.startswith('jidr-perf.'):
        p.error('requires the baseline runner disposable JIDR_HOME')
    args.out.mkdir(parents=True,exist_ok=False)
    cli=ROOT/'target/release/jidr';bridge=ROOT/'target/release/jidr-swiftui-bridge'
    def call(command,params):
        value=json.loads(subprocess.check_output([str(cli),'--json','call',command,json.dumps(params)],text=True))
        if not value['ok']: raise RuntimeError(value['error'])
        return value['result']
    # The token is used only inside the normal bridge. Never persist connect_info.
    info=call('device.connect_info',{'device':args.device})
    adb=info['adb_path'];serial=info['adb_serial']
    def android(*cmd,check=True):
        return subprocess.run([adb,'-s',serial,*cmd],capture_output=True,text=True,check=check,timeout=20)
    def read(name):
        value=android('shell','run-as',PACKAGE,'cat','files/'+name,check=False)
        return value.stdout if value.returncode==0 else None
    def events():
        value=read('events.jsonl') or '';result=[]
        for line in value.splitlines():
            try: result.append(json.loads(line))
            except ValueError: pass # A concurrent append may leave the final line partial.
        return result
    def wait(test,message,seconds=8):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            value=test()
            if value: return value
            time.sleep(.1)
        raise RuntimeError('timed out: '+message)
    report={'device':args.device,'scheduler':'fifo','apk_sha256':hashlib.sha256(args.apk.read_bytes()).hexdigest(),
            'checks':[],'complete':False}
    process=None;frames=[];diagnostics=[];frame_errors=[]
    def record(name): report['checks'].append(name);print('PASS',name,flush=True)
    try:
        android('install','-r',str(args.apk));android('shell','am','start','-n',PACKAGE+'/.MainActivity')
        def layout():
            try: return json.loads(read('layout.json') or 'null')
            except ValueError: return None
        field=wait(layout,'input fixture layout')
        wait(lambda:read('ready.txt')=='ready','focused Android input window')
        env=dict(os.environ,JIDR_PLAYER_INPUT_SCHEDULER='fifo',JIDR_PLAYER_FRAME_TRANSPORT='shared')
        process=subprocess.Popen([str(bridge),args.device,'1080','2400','1'],env=env,
                                 stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def exact(n):
            data=b''
            while len(data)<n:
                part=process.stdout.read(min(65536,n-len(data)))
                if not part: return None
                data+=part
            return data
        def drain_frames():
            while True:
                header=exact(20)
                if header is None: return
                magic,w,h,q,n=struct.unpack('>4sIIII',header)
                if magic!=b'JFR1' or not (0<w<=8192 and 0<h<=8192 and n==w*h*4 and n<=32*1024*1024):
                    frame_errors.append('invalid frame boundary');return
                # Drain in small chunks without assembling/copying a whole frame.
                left=n
                while left:
                    part=process.stdout.read(min(65536,left))
                    if not part:return
                    left-=len(part)
                frames.append((w,h,q))
                if len(frames)>10000: del frames[:1000]
        def drain_errors():
            for line in process.stderr:
                diagnostics.append(line.decode('utf-8',errors='replace').rstrip())
        threading.Thread(target=drain_frames,daemon=True).start()
        threading.Thread(target=drain_errors,daemon=True).start()
        wait(lambda:len(frames)>2,'real screenshot frames')
        def send(**cmd):
            process.stdin.write((json.dumps(cmd,ensure_ascii=False)+'\n').encode());process.stdin.flush()
        def key(value,down): send(type='key',key=value,down=down)
        send(type='touch',x=field['x']/1080,y=field['y']/2400,down=True)
        send(type='touch',x=field['x']/1080,y=field['y']/2400,down=False)
        wait(lambda:any(e['kind']=='touch' and e['action']==1 for e in events()),'initial point delivered to Android')
        key('Shift',True);key('a',True);time.sleep(.2);key('a',False);key('Shift',False)
        wait(lambda:read('text.txt')=='A','ordered Shift+A input')
        record('real modifier/long-press down-up order')
        text='中文日本語🙂'
        send(type='select_all');send(type='paste',text=text)
        wait(lambda:read('text.txt')==text,'Unicode paste')
        record('real Unicode paste replaces selection')
        key('b',True);key('b',False)
        wait(lambda:read('text.txt')==text+'b','ASCII after Unicode paste')
        send(type='select_all');send(type='copy',request_id=71)
        def copied(request,text):
            for line in list(diagnostics):
                if line.startswith('JIDR_CLIPBOARD:'):
                    value=json.loads(line.split(':',1)[1])
                    if value.get('request_id')==request and value.get('text')==text:return True
            return False
        wait(lambda:copied(71,text+'b'),'fresh Android copy result')
        record('real copy waits for fresh clipboard content')
        key('c',True);key('c',False)
        wait(lambda:read('text.txt')=='c','replace selection after copy')
        send(type='select_all');send(type='cut',request_id=72)
        wait(lambda:copied(72,'c') and read('text.txt')=='','cut result and empty field')
        record('real cut updates clipboard and removes text')
        before=len(events())
        send(type='touch',x=.3,y=.7,down=True)
        send(type='mapped_touch',id=3,x=.6,y=.7,down=True)
        send(type='touch',x=.35,y=.72,down=True)
        send(type='mapped_touch',id=3,x=.65,y=.72,down=True)
        send(type='mapped_touch',id=3,x=.65,y=.72,down=False)
        send(type='touch',x=.35,y=.72,down=False)
        wait(lambda:any(e['kind']=='touch' and len(e['pointers'])==2 for e in events()[before:])
             and any(e['kind']=='touch' and e['action']==1 for e in events()[before:]),'two-finger gesture')
        record('real two-finger gesture and final up')
        # Stop with keys and both fingers deliberately held. The OS signal
        # must reach the actual production shutdown path, not fixture code.
        before=len(events())
        key('Shift',True);key('a',True)
        send(type='touch',x=.3,y=.7,down=True);send(type='mapped_touch',id=3,x=.6,y=.7,down=True)
        wait(lambda:any(e['kind']=='touch' and len(e['pointers'])==2 for e in events()[before:]),'held fingers before shutdown')
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=8)
        if process.returncode!=0: raise RuntimeError('bridge did not gracefully exit on SIGTERM')
        def released():
            tail=events()[before:]
            ups={e['name'] for e in tail if e['kind']=='key' and e['action']==1}
            return {'KEYCODE_A','KEYCODE_SHIFT_LEFT'}<=ups and any(e['kind']=='touch' and e['action']==1 for e in tail)
        wait(released,'held keys and touches released after SIGTERM')
        record('real SIGTERM releases held keys and two fingers')
        if frame_errors: raise RuntimeError(frame_errors)
        report['complete']=True;report['frames_received']=len(frames)
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=8)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        (args.out/'events.json').write_text(json.dumps(events(),ensure_ascii=False,indent=2)+'\n')
        for name in ['text.txt','layout.json','ready.txt']:
            (args.out/name).write_text(read(name) or '')
        (args.out/'bridge-stderr.log').write_text('\n'.join(diagnostics)+'\n')
        android('uninstall',PACKAGE,check=False)
        (args.out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
