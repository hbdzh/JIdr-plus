#!/usr/bin/env python3
"""Exercise the deployment gate with real compatible/incompatible Mach-O files."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[4]
checker = root / "apps/jidr-swiftui/check-deployment.py"
plist = root / "packaging/swiftui/Jidr-Info.plist.in"
with plist.open("rb") as stream:
    minimum = plistlib.load(stream)["LSMinimumSystemVersion"]
with tempfile.TemporaryDirectory(prefix="jidr-deployment-test-") as directory:
    temporary = Path(directory)
    source = temporary / "main.swift"
    source.write_text('print("deployment fixture")\n')
    for version, should_pass in [(minimum, True), (f"{int(minimum.split('.')[0]) + 1}.0", False)]:
        binary = temporary / f"fixture-{version}"
        subprocess.run(["swiftc", "-target", f"arm64-apple-macosx{version}",
                        "-module-cache-path", str(temporary / "module-cache"),
                        str(source), "-o", str(binary)], check=True)
        result = subprocess.run([sys.executable, str(checker), str(binary), str(plist)],
                                capture_output=True, text=True)
        assert (result.returncode == 0) == should_pass, result.stdout + result.stderr
        if not should_pass:
            assert "Deployment mismatch" in result.stderr, result.stderr
print("Mach-O deployment regression tests passed")
