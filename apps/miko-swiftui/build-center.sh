#!/bin/bash
# Build the native app with its real Rust helpers; never replace installed Miko.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
cargo build -p miko -p miko-swiftui-bridge
cargo xtask helper --arch aarch64
out="${MIKO_CENTER_OUT:-$root/target/swiftui-center}"
app="$out/miko simulator.app"
mkdir -p "$app/Contents/Resources/helper/aarch64"
cp "$root/target/miko-helper/aarch64/miko-helper" "$app/Contents/Resources/helper/aarch64/miko-helper"
mkdir -p "$app/Contents/Resources/licenses" "$app/Contents/MacOS" "$app/Contents/Helpers" "$out/module-cache"
for helper in miko miko-center-bridge miko-swiftui-bridge; do
  cp "$root/target/debug/$helper" "$app/Contents/Helpers/$helper"
done
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/*.swift \
  apps/miko-swiftui/Center/*.swift \
  -o "$app/Contents/MacOS/Miko"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj"
cp apps/miko-swiftui/Resources/en.lproj/InfoPlist.strings "$app/Contents/Resources/en.lproj/InfoPlist.strings"
cp apps/miko-swiftui/Resources/zh-Hans.lproj/InfoPlist.strings "$app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
cp apps/miko-swiftui/Resources/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/miko-swiftui/Resources/zh-Hans.lproj/Localizable.strings "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp apps/miko-swiftui/Resources/device-list-generated.png "$app/Contents/Resources/device-list.png"
cp apps/miko-swiftui/Resources/device-detail-generated.png "$app/Contents/Resources/device-detail.png"
cp apps/miko-swiftui/Resources/device-stopped.png "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/fonts"
cp apps/miko-swiftui/Resources/fonts/*.ttf "$app/Contents/Resources/fonts/"
cp apps/miko-swiftui/Resources/fonts/OFL-*.txt "$app/Contents/Resources/licenses/"
cp LICENSE-APACHE LICENSE-MUSL NOTICE apps/miko-swiftui/LICENSE-GPL "$app/Contents/Resources/licenses/"
cp apps/miko-swiftui/Resources/Miko.icns "$app/Contents/Resources/"
python3 "$root/apps/miko-swiftui/app-metadata.py" "$app/Contents/Info.plist" --development
printf 'APPL????' > "$app/Contents/PkgInfo"
python3 "$root/apps/miko-swiftui/check-deployment.py" "$app/Contents/MacOS/Miko" "$app/Contents/Info.plist"
python3 "$root/apps/miko-swiftui/app-metadata.py" --check "$app"
printf 'Built %s\n' "$app"
