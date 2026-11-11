#!/bin/bash
# Build an isolated prototype; never replace the installed Jidr application.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui-prototype/swift-target.sh"
cargo build -p jidr-swiftui-bridge
out="${JIDR_PROTOTYPE_OUT:-$root/target/swiftui-prototype}"
app="$out/JidrSwiftUIPrototype.app"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj" "$app/Contents/MacOS" "$out/module-cache"
CLANG_MODULE_CACHE_PATH="$out/module-cache" \
  swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/*.swift \
  apps/jidr-swiftui-prototype/Player/main.swift \
  -o "$app/Contents/MacOS/JidrSwiftUIPrototype"
cp apps/jidr-swiftui-prototype/Resources/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/jidr-swiftui-prototype/Resources/zh-Hans.lproj/Localizable.strings "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
mkdir -p "$app/Contents/Resources/fonts"
cp apps/jidr-gui/assets/fonts/*.ttf "$app/Contents/Resources/fonts/"
cp apps/jidr-swiftui-prototype/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $jidr_minimum_macos" "$app/Contents/Info.plist"
python3 "$root/apps/jidr-swiftui-prototype/check-deployment.py" "$app/Contents/MacOS/JidrSwiftUIPrototype" "$app/Contents/Info.plist"
printf 'Built %s\n' "$app"
