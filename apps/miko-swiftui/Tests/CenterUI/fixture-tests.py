#!/usr/bin/env python3
"""Preview regressions. Uses only a disposable MIKO_HOME, never an SDK."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class FixtureTests(unittest.TestCase):
    def test_delete_is_stateful_and_unsupported_commands_never_succeed(self):
        fixture = Path(__file__).with_name("center-fixture.py")
        with tempfile.TemporaryDirectory(prefix="miko-preview-fixture-") as home:
            env = {**os.environ, "MIKO_HOME": home, "MIKO_UI_TASKS": "1"}
            env.pop("MIKO_UI_DELETE_NOOP", None)

            def launch():
                return subprocess.Popen([sys.executable, str(fixture)], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

            def call(process, method, **params):
                process.stdin.write(json.dumps({"id": 1, "method": method, "params": params}) + "\n")
                process.stdin.flush()
                return json.loads(process.stdout.readline())

            with launch() as process:
                devices = call(process, "device.list")["result"]
                self.assertEqual(call(process, "network.shaping.set", dns="slow", dns_delay_ms=1000)["result"]["dns"], "slow")
                self.assertEqual(call(process, "network.shaping.set", loss_pct=20)["result"]["dns_delay_ms"], 1000)
                self.assertEqual(call(process, "network.shaping.set", dns="normal")["result"]["loss_pct"], 20)
                self.assertEqual(call(process, "jobs.list")["result"][1]["device"], devices[0]["id"])
                images = call(process, "image.inventory")["result"]
                protected = next(image for image in images if not image["can_delete"])
                self.assertEqual(call(process, "image.remove", image=protected["package"], source=protected["source"], root=protected["root"])["type"], "error")
                removable = next(image for image in images if image["can_delete"])
                self.assertEqual(call(process, "image.remove", image=removable["package"], source=removable["source"], root=removable["root"])["type"], "result")
                self.assertNotIn(removable, call(process, "image.inventory")["result"])
                for method in ["device.restart", "file.install", "sdk.install", "not.a.command"]:
                    self.assertEqual(call(process, method)["type"], "error")
                for device in devices:
                    response = call(process, "device.delete", device=device["id"])
                    self.assertEqual(response["result"]["deleted"], device["id"])
                    self.assertNotIn(device["id"], [d["id"] for d in call(process, "device.list")["result"]])
                    self.assertEqual(call(process, "device.details", device=device["id"])["type"], "error")
                    self.assertEqual(call(process, "device.delete", device=device["id"])["type"], "error")
                self.assertIsNone(call(process, "jobs.list")["result"][1]["device"])
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
            with launch() as process:
                self.assertEqual(call(process, "device.list")["result"], [])
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)


if __name__ == "__main__":
    unittest.main()
