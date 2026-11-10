#!/bin/bash
# Regression test for the AppKit game-window lifecycle. Requires a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/target/swiftui-prototype"
mkdir -p "$out/module-cache"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/FrameDecoder.swift \
  apps/jidr-swiftui-prototype/Sources/KeyMapping.swift \
  apps/jidr-swiftui-prototype/Sources/GameWindowState.swift \
  apps/jidr-swiftui-prototype/Sources/GameWindow.swift \
  apps/jidr-swiftui-prototype/Tests/Window/main.swift -o "$out/window-lifecycle-tests"
"$out/window-lifecycle-tests"
