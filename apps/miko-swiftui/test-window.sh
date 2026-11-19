#!/bin/bash
# Regression test for the AppKit game-window lifecycle. Requires a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-tests"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/*.swift \
  "${center_sources[@]}" \
  apps/miko-swiftui/Tests/Window/main.swift -o "$out/window-lifecycle-tests"
"$out/window-lifecycle-tests"
