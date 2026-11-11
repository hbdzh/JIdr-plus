#!/usr/bin/env python3
"""Check the actual Mach-O deployment target against the app's declared minimum."""
import plistlib
from pathlib import Path
import re
import subprocess
import sys


def check(binary: Path, plist: Path) -> None:
    with plist.open("rb") as stream:
        minimum = plistlib.load(stream)["LSMinimumSystemVersion"]
    build = subprocess.run(
        ["xcrun", "vtool", "-show-build", str(binary)],
        check=True, capture_output=True, text=True,
    ).stdout
    targets = re.findall(r"^\s*minos\s+(\S+)", build, re.MULTILINE)
    expected = tuple(int(part) for part in minimum.split("."))
    expected = (expected + (0, 0))[:3]
    if not targets or any(
        (tuple(int(part) for part in target.split(".")) + (0, 0))[:3] != expected
        for target in targets
    ):
        raise SystemExit(f"Deployment mismatch: {binary}: minos={targets}, declared={minimum}")
    print(f"Deployment check passed: {binary.name}: macOS {minimum}")


if __name__ == "__main__":
    check(Path(sys.argv[1]), Path(sys.argv[2]))
