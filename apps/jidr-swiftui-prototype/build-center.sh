#!/bin/bash
# Build a separate device-center development preview; never replace installed Jidr.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
cargo build -p jidr-swiftui-bridge --bin jidr-center-bridge
app="$root/target/swiftui-center/JidrSwiftUICenter.app"
mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS" "$root/target/swiftui-center/module-cache"
swiftc -module-cache-path "$root/target/swiftui-center/module-cache" \
  apps/jidr-swiftui-prototype/Sources/FrameDecoder.swift apps/jidr-swiftui-prototype/Sources/KeyMapping.swift apps/jidr-swiftui-prototype/Sources/WindowQuality.swift apps/jidr-swiftui-prototype/Sources/GameWindowState.swift apps/jidr-swiftui-prototype/Sources/DeviceCreation.swift apps/jidr-swiftui-prototype/Sources/SDKInstallPlan.swift apps/jidr-swiftui-prototype/Sources/OperationMessages.swift apps/jidr-swiftui-prototype/Sources/AppListLoader.swift apps/jidr-swiftui-prototype/Sources/LogFilter.swift apps/jidr-swiftui-prototype/Sources/LogStream.swift apps/jidr-swiftui-prototype/Sources/GameWindow.swift apps/jidr-swiftui-prototype/Center/DeviceModel.swift apps/jidr-swiftui-prototype/Center/MCPConfiguration.swift apps/jidr-swiftui-prototype/Center/AdvancedTools.swift apps/jidr-swiftui-prototype/Center/DeviceViews.swift apps/jidr-swiftui-prototype/Center/main.swift -o "$app/Contents/MacOS/JidrSwiftUICenter"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj"
cp apps/jidr-swiftui-prototype/Resources/en.lproj/Localizable.strings "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/jidr-swiftui-prototype/Resources/zh-Hans.lproj/Localizable.strings "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp crates/jidr-ui/ui/assets/device-list-generated.png "$app/Contents/Resources/device-list.png"
cp crates/jidr-ui/ui/assets/device-detail-generated.png "$app/Contents/Resources/device-detail.png"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleDevelopmentRegion</key><string>zh-Hans</string><key>CFBundleExecutable</key><string>JidrSwiftUICenter</string><key>CFBundleIdentifier</key><string>local.jidr.swiftui.center</string><key>CFBundleName</key><string>Jidr SwiftUI Center</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
printf 'Built %s\n' "$app"
