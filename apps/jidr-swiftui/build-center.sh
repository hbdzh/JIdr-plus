#!/bin/bash
# Build the native app with its real Rust helpers; never replace installed Jidr.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
cargo build -p jidr -p jidr-swiftui-bridge
out="${JIDR_CENTER_OUT:-$root/target/swiftui-center}"
app="$out/Jidr.app"
mkdir -p "$app/Contents/Resources/licenses" "$app/Contents/MacOS" "$app/Contents/Helpers" "$out/module-cache"
for helper in jidr jidr-center-bridge jidr-swiftui-bridge; do
  cp "$root/target/debug/$helper" "$app/Contents/Helpers/$helper"
done
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/*.swift \
  apps/jidr-swiftui/Center/*.swift \
  -o "$app/Contents/MacOS/Jidr"
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
python3 "$root/apps/jidr-swiftui/app-metadata.py" "$app/Contents/Info.plist" --development
printf 'APPL????' > "$app/Contents/PkgInfo"
python3 "$root/apps/jidr-swiftui/check-deployment.py" "$app/Contents/MacOS/Jidr" "$app/Contents/Info.plist"
python3 "$root/apps/jidr-swiftui/app-metadata.py" --check "$app"
printf 'Built %s\n' "$app"
