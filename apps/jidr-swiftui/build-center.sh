#!/bin/bash
# Build the native app with its real Rust helpers; never replace installed Jidr.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
cargo build -p jidr -p jidr-swiftui-bridge
out="${JIDR_CENTER_OUT:-$root/target/swiftui-center}"
app="$out/JidrSwiftUICenter.app"
mkdir -p "$app/Contents/Resources/licenses" "$app/Contents/MacOS" "$app/Contents/Helpers" "$out/module-cache"
for helper in jidr jidr-center-bridge jidr-swiftui-bridge; do
  cp "$root/target/debug/$helper" "$app/Contents/Helpers/$helper"
done
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/*.swift \
  apps/jidr-swiftui/Center/*.swift \
  -o "$app/Contents/MacOS/JidrSwiftUICenter"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj"
cp apps/jidr-swiftui/Resources/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/jidr-swiftui/Resources/zh-Hans.lproj/Localizable.strings "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp apps/jidr-swiftui/Resources/device-list-generated.png "$app/Contents/Resources/device-list.png"
cp apps/jidr-swiftui/Resources/device-detail-generated.png "$app/Contents/Resources/device-detail.png"
mkdir -p "$app/Contents/Resources/fonts"
cp apps/jidr-swiftui/Resources/fonts/*.ttf "$app/Contents/Resources/fonts/"
cp apps/jidr-swiftui/Resources/fonts/OFL-*.txt "$app/Contents/Resources/licenses/"
cp LICENSE-APACHE NOTICE apps/jidr-swiftui/LICENSE-GPL "$app/Contents/Resources/licenses/"
cp apps/jidr-swiftui/Resources/Jidr.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleDevelopmentRegion</key><string>zh-Hans</string><key>CFBundleExecutable</key><string>JidrSwiftUICenter</string><key>CFBundleIdentifier</key><string>local.jidr.swiftui.center</string><key>CFBundleName</key><string>Jidr SwiftUI Center</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/><key>ATSApplicationFontsPath</key><string>fonts</string></dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $jidr_minimum_macos" "$app/Contents/Info.plist"
python3 "$root/apps/jidr-swiftui/check-deployment.py" "$app/Contents/MacOS/JidrSwiftUICenter" "$app/Contents/Info.plist"
printf 'Built %s\n' "$app"
