#!/usr/bin/env python3
"""Only serves lifecycle-test fixtures; never opens a daemon or an SDK."""
import json
import copy
import os
from pathlib import Path
import sys
import time

home = Path(os.environ["JIDR_HOME"])
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
    if request["method"] == "device.start" and (home / "block-start").exists():
        (home / "start-started").touch()
        while not (home / "start-release").exists():
            time.sleep(0.01)
    result = responses.get(request["method"], {})
    if request["method"] == "device.details" and request.get("params", {}).get("device") == second_device["id"]:
        result = {"device": second_device, "config": {"hw.lcd.width": "720", "hw.lcd.height": "1280", "hw.ramSize": "4096", "hw.cpu.ncore": "4", "hw.lcd.density": "420"}, "disk_usage": 0}
    print(json.dumps({"id": request["id"], "type": "result", "result": result}), flush=True)
