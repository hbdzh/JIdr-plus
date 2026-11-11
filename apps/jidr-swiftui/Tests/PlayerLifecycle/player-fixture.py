#!/usr/bin/env python3
"""Emit a diagnostic while the test deliberately holds its main queue busy."""
import json
import os
from pathlib import Path
import sys
import time

print("JIDR_RECORD:" + json.dumps({"state": "recording", "message": "Recording started"}),
      file=sys.stderr, flush=True)
(Path(os.environ["JIDR_HOME"]) / "recording-diagnostic-ready").write_text("ready")
time.sleep(10)
