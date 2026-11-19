#!/bin/bash
# Requires a GUI session; uses only fixture responses and a temporary home.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cargo build -p miko-swiftui-bridge --bin miko-swiftui-bridge
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-player-lifecycle"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/miko-swiftui/Sources/*.swift \
  "${center_sources[@]}" \
  "$root/apps/miko-swiftui/Tests/PlayerLifecycle/main.swift" -o "$out/lifecycle-tests"
miko_test_home="$(mktemp -d "${TMPDIR:-/tmp}/miko-player-lifecycle.XXXXXX")"
trap 'rm -rf "$miko_test_home"' EXIT
# Process expects an executable bridge. Copy the fixture into our own temp
# directory so a source checkout does not need its executable bit changed.
cp "$root/apps/miko-swiftui/Tests/PlayerLifecycle/center-fixture.py" "$miko_test_home/center-fixture"
cp "$root/apps/miko-swiftui/Tests/PlayerLifecycle/player-fixture.py" "$miko_test_home/player-fixture"
chmod +x "$miko_test_home/center-fixture" "$miko_test_home/player-fixture"
MIKO_HOME="$miko_test_home" MIKO_PROTOTYPE_TEST_PASTEBOARD="miko.lifecycle.$$" \
  "$out/lifecycle-tests" "$miko_test_home/center-fixture" "$miko_test_home/player-fixture" \
  "$root/target/debug/miko-swiftui-bridge"
