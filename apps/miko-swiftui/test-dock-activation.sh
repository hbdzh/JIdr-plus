#!/bin/bash
# Regression test for Dock reopen window selection. Requires a GUI session.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-tests"
mkdir -p "$out/module-cache"
swiftc -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root/apps/miko-swiftui/Center/DockWindowActivation.swift" \
  "$root/apps/miko-swiftui/Tests/DockActivation/main.swift" -o "$out/dock-activation-tests"
"$out/dock-activation-tests"
