#!/bin/bash
# Render the deterministic SwiftUI preview snapshots and compare them with the
# baselines in apps/jidr-swiftui-prototype/Tests/golden. The bridge binaries run
# in fixture mode (environment variable, per process), so no daemon or emulator
# is needed. Requires Xcode, the workspace Rust toolchain and a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui-prototype/swift-target.sh"
cargo build -p jidr-swiftui-bridge --bin jidr-center-bridge --bin jidr-swiftui-bridge
out="$root/target/swiftui-snapshot"
mkdir -p "$out/module-cache"
# Same source set as build-center.sh, but without Center/main.swift: this
# executable has its own top-level entry point in Tests/Snapshot/main.swift.
center_sources=()
for file in "$root"/apps/jidr-swiftui-prototype/Center/*.swift; do
  [[ "$(basename "$file")" == "main.swift" ]] && continue
  center_sources+=("$file")
done
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/jidr-swiftui-prototype/Sources/*.swift \
  "${center_sources[@]}" \
  "$root"/apps/jidr-swiftui-prototype/Tests/Snapshot/main.swift \
  -o "$out/jidr-snapshot"
# Bundle.main for a bare executable is the executable's own directory: stage the
# localized string tables and the generated device art the packaged preview
# ships, so the EN cases resolve the real translations instead of falling back
# to the Chinese keys (and the device art is present, as in the app bundle).
mkdir -p "$out/en.lproj" "$out/zh-Hans.lproj"
cp "$root/apps/jidr-swiftui-prototype/Resources/en.lproj/Localizable.strings" "$out/en.lproj/"
cp "$root/apps/jidr-swiftui-prototype/Resources/zh-Hans.lproj/Localizable.strings" "$out/zh-Hans.lproj/"
cp "$root/crates/jidr-ui/ui/assets/device-list-generated.png" "$out/device-list.png"
cp "$root/crates/jidr-ui/ui/assets/device-detail-generated.png" "$out/device-detail.png"
# The snapshots never touch the user's Jidr data; the fixtures do not look at
# JIDR_HOME at all, but an isolated home keeps any accidental path usage local.
home="$(mktemp -d "${TMPDIR:-/tmp}/jidr-snapshot-home.XXXXXX")"
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/data"
cp "$root/apps/jidr-swiftui-prototype/Tests/CenterUI/center-fixture.py" "$home/ui-fixture"
chmod +x "$home/ui-fixture"
JIDR_HOME="$home" "$out/jidr-snapshot" \
  --center-bridge "$root/target/debug/jidr-center-bridge" \
  --player-bridge "$root/target/debug/jidr-swiftui-bridge" \
  --ui-fixture "$home/ui-fixture" \
  --golden "$root/apps/jidr-swiftui-prototype/Tests/golden" \
  --fonts "$root/apps/jidr-gui/assets/fonts" \
  "$@"
