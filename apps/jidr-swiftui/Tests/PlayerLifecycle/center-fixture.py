#!/usr/bin/env python3
"""Only serves lifecycle-test fixtures; never opens a daemon or an SDK."""
import json
import os
from pathlib import Path
import sys

home = Path(os.environ["JIDR_HOME"])
device = {
    "id": "00000000-0000-4000-8000-000000000001", "name": "Lifecycle fixture",
    "root": {"mode": "none", "health": None}, "runtime": None,
    "profile": "test", "sdk_root": "/unused", "launch": {},
    "auto_hibernate_minutes": None, "status": {"state": "running"},
    "image": {"api": 31, "tag": "default"},
}
responses = {
    "center.paths": {"data": str(home / "data")},
    "center.prefs.get": {"language": 0}, "device.list": [device], "jobs.list": [],
    "device.details": {"device": device, "config": {"hw.lcd.width": "480", "hw.lcd.height": "640"}, "disk_usage": 0},
    "app.list": {"apps": []},
}
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({"id": request["id"], "type": "result",
                      "result": responses.get(request["method"], {})}), flush=True)
