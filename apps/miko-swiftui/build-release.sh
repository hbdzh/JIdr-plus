#!/bin/bash
# Build the SwiftUI device center for the release chain (`cargo xtask release`).
#
# The release build is optimised (`swiftc -O`) and writes only the executable:
# `cargo xtask release` assembles it into miko simulator.app next to the release Rust
# helpers and the production Resources. Run it directly when you only need to
# check that the optimised SwiftUI center compiles.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-center-release"
binary="$out/Miko"
mkdir -p "$out/module-cache"
CLANG_MODULE_CACHE_PATH="$out/module-cache" \
  swiftc -O -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/*.swift \
  apps/miko-swiftui/Center/*.swift \
  -o "$binary"
python3 "$root/apps/miko-swiftui/check-deployment.py" "$binary" "$root/packaging/swiftui/Miko-Info.plist.in"
printf 'Built %s\n' "$binary"
