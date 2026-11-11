#!/bin/bash
# Requires a GUI session; uses only fixture responses and a temporary home.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cargo build -p jidr-swiftui-bridge --bin jidr-swiftui-bridge
source "$root/apps/jidr-swiftui-prototype/swift-target.sh"
out="$root/target/swiftui-player-lifecycle"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/jidr-swiftui-prototype/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/jidr-swiftui-prototype/Sources/*.swift \
  "${center_sources[@]}" \
  "$root/apps/jidr-swiftui-prototype/Tests/PlayerLifecycle/main.swift" -o "$out/lifecycle-tests"
jidr_test_home="$(mktemp -d "${TMPDIR:-/tmp}/jidr-player-lifecycle.XXXXXX")"
trap 'rm -rf "$jidr_test_home"' EXIT
# Process expects an executable bridge. Copy the fixture into our own temp
# directory so a source checkout does not need its executable bit changed.
cp "$root/apps/jidr-swiftui-prototype/Tests/PlayerLifecycle/center-fixture.py" "$jidr_test_home/center-fixture"
cp "$root/apps/jidr-swiftui-prototype/Tests/PlayerLifecycle/player-fixture.py" "$jidr_test_home/player-fixture"
chmod +x "$jidr_test_home/center-fixture" "$jidr_test_home/player-fixture"
JIDR_HOME="$jidr_test_home" JIDR_PROTOTYPE_TEST_PASTEBOARD="jidr.lifecycle.$$" \
  "$out/lifecycle-tests" "$jidr_test_home/center-fixture" "$jidr_test_home/player-fixture" \
  "$root/target/debug/jidr-swiftui-bridge"
