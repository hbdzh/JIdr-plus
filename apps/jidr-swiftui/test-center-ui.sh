#!/bin/bash
# Actual AppKit hosting, focus and auxiliary-window regressions. Fake bridge only.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
out="$root/target/swiftui-center-ui"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/jidr-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/jidr-swiftui/Sources/*.swift "${center_sources[@]}" \
  "$root/apps/jidr-swiftui/Tests/CenterUI/main.swift" -o "$out/center-ui-tests"
mkdir -p "$out/en.lproj" "$out/zh-Hans.lproj"
cp "$root/apps/jidr-swiftui/Resources/en.lproj/Localizable.strings" "$out/en.lproj/"
cp "$root/apps/jidr-swiftui/Resources/zh-Hans.lproj/Localizable.strings" "$out/zh-Hans.lproj/"
jidr_ui_home="$(mktemp -d "${TMPDIR:-/tmp}/jidr-center-ui.XXXXXX")"
trap 'rm -rf "$jidr_ui_home"' EXIT
mkdir -p "$jidr_ui_home/data"
cp "$root/apps/jidr-swiftui/Tests/CenterUI/center-fixture.py" "$jidr_ui_home/fixture"
chmod +x "$jidr_ui_home/fixture"
python3 "$root/apps/jidr-swiftui/Tests/CenterUI/fixture-tests.py"
JIDR_HOME="$jidr_ui_home" JIDR_UI_DELETE_NOOP="00000000-0000-4000-8000-000000000002" \
  "$out/center-ui-tests" "$jidr_ui_home/fixture"
