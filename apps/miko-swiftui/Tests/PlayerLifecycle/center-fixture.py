#!/usr/bin/env python3
"""Only serves lifecycle-test fixtures; never opens a daemon or an SDK."""
import json
import copy
import os
from pathlib import Path
import sys
import threading
import time

home = Path(os.environ["MIKO_HOME"])
device = {
    "id": "00000000-0000-4000-8000-000000000001", "name": "Lifecycle fixture",
    "root": {"mode": "none", "health": None}, "runtime": None,
    "profile": "test", "sdk_root": "/unused", "launch": {},
    "auto_hibernate_minutes": None, "status": {"state": "running"},
    "image": {"api": 31, "tag": "default"},
}
second_device = copy.deepcopy(device)
second_device["id"] = "00000000-0000-4000-8000-000000000002"
second_device["name"] = "Second fixture"
responses = {
    "center.paths": {"data": str(home / "data")},
    "center.prefs.get": {"language": 0}, "device.list": [device, second_device], "jobs.list": [],
    "device.details": {"device": device, "config": {"hw.lcd.width": "480", "hw.lcd.height": "640", "hw.ramSize": "2048", "hw.cpu.ncore": "2", "hw.lcd.density": "320"}, "disk_usage": 0},
    "app.list": {"apps": []},
}
start_request = None
for line in sys.stdin:
    request = json.loads(line)
    device["status"]["state"] = "stopped" if (home / "fixture-stopped").exists() else "running"
    responses["device.details"]["config"]["hw.ramSize"] = "3072" if (home / "hardware-updated").exists() else "2048"
    with (home / "requests.jsonl").open("a") as log:
        log.write(json.dumps(request) + "\n")
    if request["method"] == "test.block":
        (home / "block-started").touch()
        while not (home / "block-release").exists():
            time.sleep(0.01)
    if request["method"] == "device.stop" and (home / "block-stop").exists():
        (home / "stop-started").touch()
        while not (home / "stop-release").exists():
            time.sleep(0.01)
    if request["method"] == "device.stop" and (home / "fail-stop").exists():
        print(json.dumps({"id": request["id"], "type": "error", "message": "fixture snapshot failed", "code": "sdk", "data": {"operation": "quick_boot_save"}}), flush=True)
        continue
    if request["method"] == "device.start" and (home / "block-start").exists():
        (home / "start-started").touch()
        start_request = request["id"]
        def report_start(request_id):
            while not (home / "boot-progress").exists():
                time.sleep(0.01)
            print(json.dumps({"type": "device_event", "event": {"topic": "device.boot", "data": {"device": device["id"], "progress": 0.3}}}), flush=True)
            print(json.dumps({"id": request_id, "type": "progress", "job": "boot-job", "message": "", "progress": 0.01}), flush=True)
            while not (home / "start-release").exists():
                time.sleep(0.01)
            print(json.dumps({"id": request_id, "type": "progress", "job": "boot-job", "message": "", "progress": None}), flush=True)
        threading.Thread(target=report_start, args=(start_request,), daemon=True).start()
        continue
    if request["method"] == "jobs.cancel" and request.get("params", {}).get("job") == "boot-job":
        print(json.dumps({"id": request["id"], "type": "result", "result": {}}), flush=True)
        print(json.dumps({"id": start_request, "type": "error", "message": "cancelled"}), flush=True)
        continue
    result = responses.get(request["method"], {})
    if request["method"] == "device.details" and request.get("params", {}).get("device") == second_device["id"]:
        result = {"device": second_device, "config": {"hw.lcd.width": "720", "hw.lcd.height": "1280", "hw.ramSize": "4096", "hw.cpu.ncore": "4", "hw.lcd.density": "420"}, "disk_usage": 0}
    print(json.dumps({"id": request["id"], "type": "result", "result": result}), flush=True)
