#!/bin/bash
# Build the SwiftUI device center for the release chain (`cargo xtask release --gui swiftui`).
#
# The release build is optimised (`swiftc -O`) and writes only the executable:
# `cargo xtask release` assembles it into Jidr.app next to the release Rust
# helpers and the production Resources. Run it directly when you only need to
# check that the optimised SwiftUI center compiles.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/target/swiftui-center-release"
binary="$out/JidrSwiftUICenter"
mkdir -p "$out/module-cache"
CLANG_MODULE_CACHE_PATH="$out/module-cache" \
  swiftc -O -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/*.swift \
  apps/jidr-swiftui-prototype/Center/*.swift \
  -o "$binary"
printf 'Built %s\n' "$binary"
