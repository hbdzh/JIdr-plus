#!/usr/bin/env python3
"""Catch untranslated literal labels in the device-center SwiftUI views."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
translations = (root / "Resources/en.lproj/Localizable.strings").read_text()
keys = set(re.findall(r'^"([^"\n]+)"\s*=', translations, re.MULTILINE))
literal = re.compile(
    r'(?:Text|Button|Section|Picker|TextField|Label|LabeledContent|Toggle|\.help)'
    r'\(\s*"([^"\n]*[\u4e00-\u9fff][^"\n]*)"'
)
missing = []
for source in sorted((root / "Center").glob("*.swift")):
    for match in literal.finditer(source.read_text()):
        if match.group(1) not in keys:
            missing.append(f"{source.name}: {match.group(1)}")
if missing:
    raise SystemExit("Missing English translations:\n" + "\n".join(missing))
print("Device-center localization coverage passed")
