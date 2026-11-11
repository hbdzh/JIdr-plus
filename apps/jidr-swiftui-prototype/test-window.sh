#!/bin/bash
# Regression test for the AppKit game-window lifecycle. Requires a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui-prototype/swift-target.sh"
out="$root/target/swiftui-prototype"
mkdir -p "$out/module-cache"
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/*.swift \
  apps/jidr-swiftui-prototype/Tests/Window/main.swift -o "$out/window-lifecycle-tests"
"$out/window-lifecycle-tests"
