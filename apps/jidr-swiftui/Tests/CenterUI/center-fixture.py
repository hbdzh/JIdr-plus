#!/usr/bin/env python3
import json,sys,os,time
from pathlib import Path
home=Path(os.environ["JIDR_HOME"])
(home/'data').mkdir(parents=True,exist_ok=True)
state=home/'data/ui-preview-devices.json'
prefs={"language":1,"appearance":1,"tile_url":"","record_audio":True}
settings={"default_root_mode":"adb","quick_boot":True,"budget_percent":80,"auto_hibernate_minutes":30}
def device(i,name,state):
 return {"id":f"00000000-0000-4000-8000-{i:012d}","name":name,"status":{"state":state},"image":{"api":35,"tag":"google_apis"},"root":{"mode":"none","health":"ok"},"runtime":{"adb_serial":"emulator-5554","pid":12345,"console_port":5554,"grpc_port":8554,"started_at":"2026-11-11T01:00:00Z"} if state=="running" else None,"profile":"pixel_7","sdk_root":"/Volumes/External/Android/SDK","launch":{"audio":True,"quick_boot":True,"camera_back":"none","camera_front":"none"},"auto_hibernate_minutes":30}
devices=[device(1,"日常测试 · Android 15","running"),device(2,"长名称布局测试：工作应用与游戏兼容性验证设备 Android 15 Google APIs","stopped"),device(3,"异常退出设备","crashed")]
if os.environ.get("JIDR_UI_ROOT")=="magisk":
 for d in devices: d['root']={"mode":"magisk","health":"ok","magisk_version":"30.7"}
if os.environ.get("JIDR_UI_ROOT") in ("adb", "adb-writable"):
 for d in devices: d['root']={"mode":"adb","health":"ok","writable_system":os.environ.get("JIDR_UI_ROOT")=="adb-writable"}
if state.exists(): devices=json.loads(state.read_text())
managed_images=[
 {"api":35,"tag":"google_apis","abi":"arm64-v8a","package":"system-images;android-35;google_apis;arm64-v8a","source":"private","root":"/Users/Shared/Jidr/sdk","size_bytes":2147483648,"used_by":[{"id":devices[0]["id"],"name":devices[0]["name"]}] if devices else [],"can_delete":not devices},
 {"api":36,"tag":"google_apis_ps16k","abi":"arm64-v8a","package":"system-images;android-36;google_apis_ps16k;arm64-v8a","source":"custom","root":"/Volumes/External/Jidr SDK","size_bytes":1879048192,"used_by":[],"can_delete":True},
 {"api":35,"tag":"google_apis","abi":"arm64-v8a","package":"system-images;android-35;google_apis;arm64-v8a","source":"external","root":"/Volumes/External/Android/SDK","size_bytes":2147483648,"used_by":[],"can_delete":False},
]
noop_used=False
packet_loss=0.0
dns_mode="normal"
dns_delay=None
for line in sys.stdin:
 r=json.loads(line);m=r["method"];p=r.get("params",{});d=next((d for d in devices if d["id"]==p.get("device")),None)
 with (home/'requests.jsonl').open('a') as log: log.write(json.dumps({"method":m,"device":p.get("device")})+'\n')
 if m=="sdk.install" and os.environ.get("JIDR_UI_SDK_PROGRESS")=="1":
  print(json.dumps({"id":r["id"],"type":"progress","message":"Downloading emulator","progress":0.42}),flush=True)
 if m=="device.details" and (home/'drop-details').exists(): continue
 if m=="device.details" and (home/'fail-details').exists():
  print(json.dumps({"id":r["id"],"type":"error","message":"Synthetic detail read failed"}),flush=True);continue
 if m=="root.cacert.list" and d and d['status']['state']!='running':
  print(json.dumps({"id":r["id"],"type":"error","message":d['name']+" is not running; start it first"}),flush=True);continue
 if m=="app.list" and os.environ.get("JIDR_UI_MANY_CONTENT")=="1":
  apps=[{"package":f"com.example.app{i}","name":f"示例应用 {i}","icon":None} for i in range(1,17)]
  print(json.dumps({"id":r["id"],"type":"result","result":{"apps":apps}}),flush=True);continue
 if m=="snapshot.list" and (home/'slow-snapshot-list').exists(): time.sleep(0.6)
 if m=="snapshot.list" and os.environ.get("JIDR_UI_MANY_CONTENT")=="1":
  snapshots=[{"name":f"测试快照 {i}","id":f"snap{i}","quick_boot":False,"restorable":True,"root_mode":"none","created_at":"2026-11-11T01:00:00Z","size_bytes":1048576} for i in range(1,9)]
  print(json.dumps({"id":r["id"],"type":"result","result":{"device_root_mode":"none","snapshots":snapshots}}),flush=True);continue
 if m=="snapshot.list" and os.environ.get("JIDR_UI_INCOMPLETE_QUICK_BOOT")=="1":
  snapshots=[{"name":"default_boot","id":"quick","quick_boot":True,"restorable":False,"root_mode":None,"created_at":"2026-11-15T16:01:00Z","size_bytes":11}]
  print(json.dumps({"id":r["id"],"type":"result","result":{"device_root_mode":"none","snapshots":snapshots}}),flush=True);continue
 if m=="snapshot.list" and os.environ.get("JIDR_UI_EMPTY_SNAPSHOTS")=="1":
  print(json.dumps({"id":r["id"],"type":"result","result":{"device_root_mode":"none","snapshots":[]}}),flush=True);continue
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
 elif m=="sdk.install" and os.environ.get("JIDR_UI_SDK_SUCCESS")=="1":
  value={"installed":["synthetic-emulator"]}
 elif m=="image.inventory":
  value=[] if os.environ.get("JIDR_UI_NO_MANAGED_IMAGES")=="1" else managed_images
 elif m=="file.sync.list":
  value=[]
 elif m=="image.remove":
  item=next((item for item in managed_images if item["package"]==p.get("image") and item["source"]==p.get("source") and item["root"]==p.get("root")),None)
  if item is None or not item["can_delete"]:
   print(json.dumps({"id":r["id"],"type":"error","message":"Synthetic image cannot be removed"}),flush=True);continue
  managed_images.remove(item);value={"removed":item["package"]}
 elif m in ("network.shaping.get", "network.shaping.set"):
  if m=="network.shaping.set":
   if "loss_pct" in p: packet_loss=float(p["loss_pct"])
   if "dns" in p: dns_mode=p["dns"]
   dns_delay=p.get("dns_delay_ms",dns_delay) if dns_mode=="slow" else None
  value={"loss_pct":packet_loss,"dns":dns_mode,"dns_delay_ms":dns_delay,"interfaces":[{"name":"wlan0","qdisc":"netem" if packet_loss else "noqueue","loss_pct":packet_loss}]}
 else:
  values={"center.prefs.get":prefs,"center.paths":{"data":str(home/'data'),"cache":str(home/'cache'),"logs":str(home/'logs'),"tools":{"android_sdk":"/Volumes/External/Android/SDK","jidr_sdk":None}},"center.about":{"version":"0.3.1","repository":"https://github.com/hbdzh/JIdr-plus"},"device.list":devices,"device.details":{"device":d,"config":{"hw.cpu.ncore":"4","hw.ramSize":"4096","hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"420"},"disk_usage":2147483648},"app.list":{"apps":[{"package":"com.example.test","name":"示例应用","icon":None},{"package":"com.example.long","name":"用于检查长名称是否截断的测试应用程序","icon":None}]},"jobs.list":[],"settings.get":settings,"sdk.status":{"tools_sdk":"/Volumes/External/Android/SDK","studio_sdk":"/Volumes/External/Android/SDK","private_sdk":None,"install_sdk":"/Users/Shared/Jidr/sdk","custom_sdk":None},"profile.list":[{"id":"pixel_7","name":"Phone 6.1 FHD+","ram_mb":4096,"cpus":4,"data_mb":8192,"audio":True}],"image.list":[{"api":35,"tag":"google_apis","abi":"arm64-v8a","installed_in":"/Volumes/External/Android/SDK"}],"cache.list":[],"snapshot.list":{"device_root_mode":"none","snapshots":[{"name":"日常测试保存点","id":"one","quick_boot":False,"restorable":True,"root_mode":"none","created_at":"2026-11-11T01:00:00Z","size_bytes":536870912},{"name":"用于检查长名称与拒绝恢复原因的快照记录","id":"two","quick_boot":False,"restorable":False,"root_mode":"magisk","magisk_version":"30.7","created_at":"2026-11-10T02:00:00Z","size_bytes":1073741824},{"name":"default_boot","id":"quick","quick_boot":True,"restorable":True,"root_mode":None,"size_bytes":1048576}]},"battery.get":{"level":75,"charger":"ac"},"network.get":{"wifi":True,"mobile":True,"profile":"full"},"dev.get":{"show_taps":False,"pointer_location":False,"layout_bounds":False,"animation_scale":1.0},"root.cacert.list":{"certificates":[]},"commands.list":[],"center.quit":None}
  if m=="profile.list":
   values[m]=[
    {"id":"phone-standard","name":"Phone 6.1 FHD+","form_factor":"phone","width":1080,"height":2400,"ram_mb":4096,"cpus":4,"data_mb":8192,"audio":True},
    {"id":"phone-large","name":"Phone 6.7 QHD+","form_factor":"phone","width":1440,"height":3120,"ram_mb":6144,"cpus":6,"data_mb":12288,"audio":True},
    {"id":"tablet","name":"Tablet 11","form_factor":"tablet","width":1600,"height":2560,"ram_mb":4096,"cpus":4,"data_mb":8192,"audio":True},
    {"id":"phone-small","name":"Small phone 5","form_factor":"phone","width":720,"height":1280,"ram_mb":2048,"cpus":2,"data_mb":4096,"audio":False},
    {"id":"phone-lean","name":"Lean phone 720p","form_factor":"phone","width":720,"height":1600,"ram_mb":2048,"cpus":2,"data_mb":4096,"audio":True},
   ]
  if m=="image.list" and p.get("available") and os.environ.get("JIDR_UI_NO_IMAGES")!="1":
   values[m].append({"api":36,"tag":"google_apis","abi":"arm64-v8a","installed_in":None})
  if m=="image.list" and os.environ.get("JIDR_UI_NO_IMAGES")=="1": values[m]=[]
  if m=="sdk.status" and os.environ.get("JIDR_UI_NO_TOOLS")=="1": values[m]["tools_sdk"]=None
  if m=="commands.list": values[m]={"commands":[{"id":name} for name in ("root.cacert.install","device.props.get","root.writable_system","audio.inject","audio.stop")]}
  if m=="host.budget":
   active=[d for d in devices if d['status']['state']=='running']
   values[m]={"total_mb":32768,"available_mb":16000,"budget_percent":80,"budget_mb":26214,"used_mb":len(active)*6144,"devices":[{"id":item['id'],"name":item['name'],"expected_mb":6144,"measured_mb":5900} for item in active]}
  if m=="root.status": values[m]={"root":d['root'] if d else {"mode":"none"}}
  if m=="device.props.get": values[m]={"props":{}}
  if m=="camera.get": values[m]={"back":d['launch']['camera_back'],"front":d['launch']['camera_front']}
  if m not in values and m not in ("sdk.licenses", "sdk.license_details"):
   print(json.dumps({"id":r["id"],"type":"error","message":"UI preview: this operation requires a real device connection."}),flush=True);continue
  value=values.get(m)
 if m in ("sdk.licenses", "sdk.license_details"):
  value=[{"id":"fixture-test-licence", "sha256":"0"*64, "text":"Synthetic UI test licence. No Google SDK licence is accepted by this fixture.\n"*12, "accepted":m=="sdk.license_details"}]
 if m=="jobs.list" and os.environ.get("JIDR_UI_TASKS")=="1":
  value=[{"id":"fixture-download", "kind":"image.install", "device":None, "progress":0.42, "message":"Downloading system image", "bytes":{"done":420000000,"total":1000000000}, "state":"running", "error":None, "created_at":"2026-11-11T01:00:00Z"}, {"id":"fixture-complete", "kind":"device.start", "device":devices[0]["id"] if devices else None, "progress":1, "message":"Boot completed", "state":"succeeded", "error":None, "created_at":"2026-11-11T00:59:00Z"}]
 print(json.dumps({"id":r["id"],"type":"result","result":value}),flush=True)
