#!/bin/bash
# Render the deterministic SwiftUI preview snapshots and compare them with the
# baselines in apps/miko-swiftui/Tests/golden. The bridge binaries run
# in fixture mode (environment variable, per process), so no daemon or emulator
# is needed. Requires Xcode, the workspace Rust toolchain and a GUI session.
set -euo pipefail
# Refuse an accidental full matrix before even compiling the renderer.
snapshot_has_scope=false
snapshot_has_list=false
for argument in "$@"; do
  case "$argument" in
    --all|--only) snapshot_has_scope=true ;;
    --list) snapshot_has_list=true ;;
  esac
done
if [[ "$snapshot_has_scope" != true && "$snapshot_has_list" != true ]]; then
  echo 'Choose --only CASE (repeatable) for a local change, or --all for the full matrix; --list shows cases.' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
cargo build -p miko-swiftui-bridge --bin miko-center-bridge --bin miko-swiftui-bridge
out="$root/target/swiftui-snapshot"
mkdir -p "$out/module-cache"
# Same source set as build-center.sh, but without Center/main.swift: this
# executable has its own top-level entry point in Tests/Snapshot/main.swift.
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == "main.swift" ]] && continue
  center_sources+=("$file")
done
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/miko-swiftui/Sources/*.swift \
  "${center_sources[@]}" \
  "$root"/apps/miko-swiftui/Tests/Snapshot/main.swift \
  -o "$out/miko-snapshot"
# These checks only parse CLI arguments / reject unsafe implicit invocations.
# They exit before creating NSApplication and never render any page.
python3 "$root/apps/miko-swiftui/Tests/Snapshot/runner-tests.py" "$out/miko-snapshot"
# Bundle.main for a bare executable is the executable's own directory: stage the
# localized string tables and the generated device art the packaged preview
# ships, so the EN cases resolve the real translations instead of falling back
# to the Chinese keys (and the device art is present, as in the app bundle).
mkdir -p "$out/en.lproj" "$out/zh-Hans.lproj"
cp "$root/apps/miko-swiftui/Resources/en.lproj/Localizable.strings" "$out/en.lproj/"
cp "$root/apps/miko-swiftui/Resources/zh-Hans.lproj/Localizable.strings" "$out/zh-Hans.lproj/"
cp "$root/apps/miko-swiftui/Resources/device-list-generated.png" "$out/device-list.png"
cp "$root/apps/miko-swiftui/Resources/device-detail-generated.png" "$out/device-detail.png"
cp "$root/apps/miko-swiftui/Resources/device-stopped.png" "$out/"
# The snapshots never touch the user's Miko data; the fixtures do not look at
# MIKO_HOME at all, but an isolated home keeps any accidental path usage local.
home="$(mktemp -d "${TMPDIR:-/tmp}/miko-snapshot-home.XXXXXX")"
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/data"
cp "$root/apps/miko-swiftui/Tests/CenterUI/center-fixture.py" "$home/ui-fixture"
chmod +x "$home/ui-fixture"
MIKO_HOME="$home" "$out/miko-snapshot" \
  --center-bridge "$root/target/debug/miko-center-bridge" \
  --player-bridge "$root/target/debug/miko-swiftui-bridge" \
  --ui-fixture "$home/ui-fixture" \
  --golden "$root/apps/miko-swiftui/Tests/golden" \
  --fonts "$root/apps/miko-swiftui/Resources/fonts" \
  "$@"
