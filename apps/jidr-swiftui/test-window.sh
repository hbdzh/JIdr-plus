#!/bin/bash
# Regression test for the AppKit game-window lifecycle. Requires a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
out="$root/target/swiftui-tests"
mkdir -p "$out/module-cache"
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/*.swift \
  apps/jidr-swiftui/Tests/Window/main.swift -o "$out/window-lifecycle-tests"
"$out/window-lifecycle-tests"
