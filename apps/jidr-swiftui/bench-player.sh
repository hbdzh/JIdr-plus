#!/bin/bash
# Build and run the native player measurement harness; never starts a device.
# --self-test is offline. Other arguments are passed to Tests/Bench/main.swift;
# use --help for panel size, quality, frame-rate and latency probe options.
# Live latency probes require a disposable running device with show_taps enabled.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
out="$root/target/swiftui-bench"
mkdir -p "$out/module-cache"
if [[ "${1:-}" != "--self-test" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
  cargo build -p jidr-swiftui-bridge --bin jidr-swiftui-bridge
fi
swiftc -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/FrameDecoder.swift \
  apps/jidr-swiftui/Tests/Bench/main.swift -o "$out/jidr-swiftui-bench"
exec "$out/jidr-swiftui-bench" --bridge "$root/target/debug/jidr-swiftui-bridge" "$@"
