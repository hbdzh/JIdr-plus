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
source "$root/apps/miko-swiftui/swift-compile.sh"
out="$root/target/swiftui-center-release"
binary="$out/Miko"
miko_compile_swift "$binary" "$out/module-cache" release
python3 "$root/apps/miko-swiftui/check-deployment.py" "$binary" "$root/packaging/swiftui/Miko-Info.plist.in"
printf 'Built %s\n' "$binary"
