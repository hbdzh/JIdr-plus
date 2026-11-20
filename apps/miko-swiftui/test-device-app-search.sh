#!/bin/bash
# Real center model with an isolated four-device bridge fixture.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-device-app-search"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] || center_sources+=("$file")
done
swiftc -O -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/miko-swiftui/Sources/*.swift "${center_sources[@]}" \
  "$root/apps/miko-swiftui/Tests/DeviceAppSearchIntegration/main.swift" -o "$out/device-app-search-integration"
test_home="$(mktemp -d "${TMPDIR:-/tmp}/miko-device-app-search.XXXXXX")"
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/data"
cp "$root/apps/miko-swiftui/Tests/DeviceAppSearchIntegration/fixture.py" "$test_home/fixture"
chmod +x "$test_home/fixture"
MIKO_HOME="$test_home" "$out/device-app-search-integration" "$test_home/fixture"
