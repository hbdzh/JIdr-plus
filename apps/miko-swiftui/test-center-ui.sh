#!/bin/bash
# Actual AppKit hosting, focus and auxiliary-window regressions. Fake bridge only.
set -euo pipefail
# These focus/responder tests intentionally open windows. Never run them
# implicitly on a maintainer's working desktop; use an isolated CI session.
if [[ "$#" != 1 || "${1:-}" != --interactive ]]; then
  echo 'This suite opens visible windows and may take focus. Use --interactive in a dedicated GUI session.' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-center-ui"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/miko-swiftui/Sources/*.swift "${center_sources[@]}" \
  "$root/apps/miko-swiftui/Tests/CenterUI/main.swift" -o "$out/center-ui-tests"
mkdir -p "$out/en.lproj" "$out/zh-Hans.lproj"
cp "$root/apps/miko-swiftui/Resources/en.lproj/Localizable.strings" "$out/en.lproj/"
cp "$root/apps/miko-swiftui/Resources/zh-Hans.lproj/Localizable.strings" "$out/zh-Hans.lproj/"
miko_ui_home="$(mktemp -d "${TMPDIR:-/tmp}/miko-center-ui.XXXXXX")"
trap 'rm -rf "$miko_ui_home"' EXIT
mkdir -p "$miko_ui_home/data"
cp "$root/apps/miko-swiftui/Tests/CenterUI/center-fixture.py" "$miko_ui_home/fixture"
chmod +x "$miko_ui_home/fixture"
python3 "$root/apps/miko-swiftui/Tests/CenterUI/fixture-tests.py"
MIKO_HOME="$miko_ui_home" MIKO_UI_DELETE_NOOP="00000000-0000-4000-8000-000000000002" \
  "$out/center-ui-tests" "$miko_ui_home/fixture"
