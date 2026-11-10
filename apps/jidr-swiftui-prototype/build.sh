#!/bin/bash
# Build an isolated prototype; never replace the installed Jidr application.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cargo build -p jidr-swiftui-bridge
app="$root/target/swiftui-prototype/JidrSwiftUIPrototype.app"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj" "$app/Contents/MacOS" "$root/target/swiftui-prototype/module-cache"
CLANG_MODULE_CACHE_PATH="$root/target/swiftui-prototype/module-cache" \
  swiftc -module-cache-path "$root/target/swiftui-prototype/module-cache" \
  apps/jidr-swiftui-prototype/Sources/FrameDecoder.swift apps/jidr-swiftui-prototype/Sources/KeyMapping.swift apps/jidr-swiftui-prototype/Sources/GameWindowState.swift apps/jidr-swiftui-prototype/Sources/GameWindow.swift apps/jidr-swiftui-prototype/Player/main.swift -o "$app/Contents/MacOS/JidrSwiftUIPrototype"
cp apps/jidr-swiftui-prototype/Resources/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/jidr-swiftui-prototype/Resources/zh-Hans.lproj/Localizable.strings "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp apps/jidr-swiftui-prototype/Info.plist "$app/Contents/Info.plist"
printf 'Built %s\n' "$app"
