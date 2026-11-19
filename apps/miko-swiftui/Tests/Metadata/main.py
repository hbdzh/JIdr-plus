#!/usr/bin/env python3
"""Exercise actual plist generation and reject missing/default app branding."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[4]
script = root / "apps/miko-swiftui/app-metadata.py"
with tempfile.TemporaryDirectory(prefix="miko-metadata-test-") as directory:
    app = Path(directory) / "miko simulator.app"
    contents = app / "Contents"
    (contents / "Resources").mkdir(parents=True)
    (contents / "MacOS").mkdir()
    executable = contents / "MacOS/Miko"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    icon = contents / "Resources/Miko.icns"
    shutil.copy2(root / "apps/miko-swiftui/Resources/Miko.icns", icon)
    plist = contents / "Info.plist"

    def verify(passes):
        result = subprocess.run([sys.executable, str(script), "--check", str(app)], capture_output=True, text=True)
        assert (result.returncode == 0) == passes, result.stdout + result.stderr

    for mode in [[], ["--development"]]:
        subprocess.run([sys.executable, str(script), str(plist), *mode], check=True)
        original = plistlib.loads(plist.read_bytes())
        assert original["CFBundleName"] == original["CFBundleDisplayName"] == "miko simulator"
        assert original["CFBundleExecutable"] == original["CFBundleIconFile"] == "Miko"
        assert original["CFBundleIdentifier"] == ("local.miko.swiftui.center" if mode else "ly.miko.Miko")
        assert "@VERSION@" not in original.values()
        verify(True)
        for key, wrong in [("CFBundleName", "Miko SwiftUI Center"), ("CFBundleDisplayName", "Untitled"),
                           ("CFBundleIconFile", None), ("CFBundleExecutable", "MikoSwiftUICenter")]:
            broken = original.copy()
            if wrong is None:
                broken.pop(key)
            else:
                broken[key] = wrong
            plist.write_bytes(plistlib.dumps(broken))
            verify(False)
        plist.write_bytes(plistlib.dumps(original))
    for locale, name in [("en", "miko simulator"), ("zh-Hans", "miko 模拟器")]:
        text = (root / f"apps/miko-swiftui/Resources/{locale}.lproj/InfoPlist.strings").read_text()
        assert f'"CFBundleName" = "{name}";' in text
        assert f'"CFBundleDisplayName" = "{name}";' in text
    icon.unlink()
    verify(False)
print("App name and icon regressions passed")
