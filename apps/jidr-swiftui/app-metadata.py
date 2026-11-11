#!/usr/bin/env python3
"""Render development metadata from the production template; verify app branding."""
import os
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def metadata(development=False):
    with (ROOT / "packaging/swiftui/Jidr-Info.plist.in").open("rb") as stream:
        value = plistlib.load(stream)
    package = (ROOT / "Cargo.toml").read_text().split("[workspace.package]", 1)[1].split("\n[", 1)[0]
    match = re.search(r'^version\s*=\s*"([^\"]+)"', package, re.MULTILINE)
    if match is None:
        raise ValueError("Cargo.toml is missing workspace.package.version")
    version = match.group(1)
    for key in ["CFBundleVersion", "CFBundleShortVersionString"]:
        value[key] = version
    if development:
        value["CFBundleIdentifier"] = "local.jidr.swiftui.center"
    return value


def check(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    expected = metadata()
    for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable",
                "CFBundleIconFile", "CFBundleVersion", "CFBundleShortVersionString"]:
        if value.get(key) != expected[key]:
            raise ValueError(f"{key}: expected {expected[key]!r}, got {value.get(key)!r}")
    icon = app / "Contents/Resources" / (value["CFBundleIconFile"] + ".icns")
    with icon.open("rb") as stream:
        if stream.read(4) != b"icns":
            raise ValueError(f"Invalid app icon: {icon}")
    executable = app / "Contents/MacOS" / value["CFBundleExecutable"]
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"Missing app executable: {executable}")
    print(f"App branding check passed: {app.name}: {value['CFBundleDisplayName']}, {icon.name}")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--check":
            check(Path(sys.argv[2]))
        else:
            destination = Path(sys.argv[1])
            destination.write_bytes(plistlib.dumps(metadata("--development" in sys.argv), sort_keys=False))
    except (OSError, ValueError) as error:
        sys.exit(f"App metadata error: {error}")
