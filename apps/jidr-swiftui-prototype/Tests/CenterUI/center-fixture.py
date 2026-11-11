#!/usr/bin/env python3
import json,sys,os
from pathlib import Path
home=Path(os.environ["JIDR_HOME"])
(home/'data').mkdir(parents=True,exist_ok=True)
state=home/'data/ui-preview-devices.json'
prefs={"language":1,"appearance":1,"tile_url":""}
settings={"default_root_mode":"adb","quick_boot":True,"budget_percent":80,"auto_hibernate_minutes":30}
def device(i,name,state):
 return {"id":f"00000000-0000-4000-8000-{i:012d}","name":name,"status":{"state":state},"image":{"api":35,"tag":"google_apis"},"root":{"mode":"none","health":"ok"},"runtime":{"adb_serial":"emulator-5554","pid":12345,"console_port":5554,"grpc_port":8554,"started_at":"2026-11-11T01:00:00Z"} if state=="running" else None,"profile":"pixel_7","sdk_root":"/Volumes/External/Android/SDK","launch":{"audio":True,"quick_boot":True,"camera_back":"none","camera_front":"none"},"auto_hibernate_minutes":30}
devices=[device(1,"日常测试 · Android 15","running"),device(2,"长名称布局测试：工作应用与游戏兼容性验证设备 Android 15 Google APIs","stopped"),device(3,"异常退出设备","crashed")]
if state.exists(): devices=json.loads(state.read_text())
noop_used=False
for line in sys.stdin:
 r=json.loads(line);m=r["method"];p=r.get("params",{});d=next((d for d in devices if d["id"]==p.get("device")),None)
 if m=="device.delete":
  if d is None:
   print(json.dumps({"id":r["id"],"type":"error","message":"No such preview device"}),flush=True);continue
  # Fault injection verifies that the UI never trusts a false success reply.
  if p.get("device")!=os.environ.get("JIDR_UI_DELETE_NOOP") or noop_used:
   devices.remove(d);state.write_text(json.dumps(devices))
  else: noop_used=True
  value={"deleted":d["id"],"name":d["name"]}
 elif m=="device.details" and d is None:
  print(json.dumps({"id":r["id"],"type":"error","message":"No such preview device"}),flush=True);continue
 elif m=="center.prefs.set":
  prefs.update(p);(home/'data/gui-prefs.json').write_text(json.dumps(prefs));value=prefs
 elif m=="settings.set": settings.update(p);value=settings
 else:
  values={"center.prefs.get":prefs,"center.paths":{"data":str(home/'data'),"cache":str(home/'cache'),"logs":str(home/'logs'),"tools":{"android_sdk":"/Volumes/External/Android/SDK","jdk_home":None}},"center.about":{"version":"0.3.1","repository":"https://github.com/hbdzh/JIdr-plus"},"device.list":devices,"device.details":{"device":d,"config":{"hw.cpu.ncore":"4","hw.ramSize":"4096","hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"420"},"disk_usage":2147483648},"app.list":{"apps":[{"package":"com.example.test","name":"示例应用","icon":None},{"package":"com.example.long","name":"用于检查长名称是否截断的测试应用程序","icon":None}]},"jobs.list":[],"settings.get":settings,"sdk.status":{"tools_sdk":"/Volumes/External/Android/SDK","private_sdk":None},"profile.list":[{"id":"pixel_7","name":"Phone 6.1 FHD+","ram_mb":4096,"cpus":4,"data_mb":8192,"audio":True}],"image.list":[{"api":35,"tag":"google_apis","abi":"arm64-v8a","installed_in":"/Volumes/External/Android/SDK"}],"cache.list":[],"snapshot.list":{"device_root_mode":"none","snapshots":[{"name":"日常测试保存点","id":"one","quick_boot":False,"restorable":True,"root_mode":"none","created_at":"2026-11-11T01:00:00Z","size_bytes":536870912},{"name":"用于检查长名称与拒绝恢复原因的快照记录","id":"two","quick_boot":False,"restorable":False,"root_mode":"magisk","magisk_version":"30.7","created_at":"2026-11-10T02:00:00Z","size_bytes":1073741824},{"name":"default_boot","id":"quick","quick_boot":True,"restorable":True,"root_mode":None,"size_bytes":1048576}]},"battery.get":{"level":75,"charger":"ac"},"network.get":{"wifi":True,"mobile":True,"profile":"full"},"dev.get":{"show_taps":False,"pointer_location":False,"layout_bounds":False,"animation_scale":1.0},"root.cacert.list":{"certificates":[]},"commands.list":[],"center.quit":None}
  if m not in values and m!="sdk.licenses":
   print(json.dumps({"id":r["id"],"type":"error","message":"UI preview: this operation requires a real device connection."}),flush=True);continue
  value=values.get(m)
 if m=="sdk.licenses": value=[{"id":"fixture-test-licence", "sha256":"0"*64, "text":"Synthetic UI test licence. No Google SDK licence is accepted by this fixture.\n"*12}]
 if m=="jobs.list" and os.environ.get("JIDR_UI_TASKS")=="1":
  value=[{"id":"fixture-download", "kind":"image.install", "device":None, "progress":0.42, "message":"Downloading system image", "bytes":{"done":420000000,"total":1000000000}, "state":"running", "error":None, "created_at":"2026-11-11T01:00:00Z"}, {"id":"fixture-complete", "kind":"device.start", "device":devices[0]["id"] if devices else None, "progress":1, "message":"Boot completed", "state":"succeeded", "error":None, "created_at":"2026-11-11T00:59:00Z"}]
 print(json.dumps({"id":r["id"],"type":"result","result":value}),flush=True)
