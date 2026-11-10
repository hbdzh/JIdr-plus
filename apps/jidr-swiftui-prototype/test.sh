#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/target/swiftui-prototype"
mkdir -p "$out/module-cache"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/FrameDecoder.swift \
  apps/jidr-swiftui-prototype/Tests/main.swift -o "$out/frame-decoder-tests"
"$out/frame-decoder-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/KeyMapping.swift \
  apps/jidr-swiftui-prototype/Tests/Mapping/main.swift -o "$out/key-mapping-tests"
"$out/key-mapping-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/WindowQuality.swift \
  apps/jidr-swiftui-prototype/Tests/Quality/main.swift -o "$out/window-quality-tests"
"$out/window-quality-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/GameWindowState.swift \
  apps/jidr-swiftui-prototype/Tests/WindowState/main.swift -o "$out/window-state-tests"
"$out/window-state-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/DeviceCreation.swift \
  apps/jidr-swiftui-prototype/Tests/Creation/main.swift -o "$out/device-creation-tests"
"$out/device-creation-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/SDKInstallPlan.swift \
  apps/jidr-swiftui-prototype/Sources/OperationMessages.swift \
  apps/jidr-swiftui-prototype/Tests/SDK/main.swift -o "$out/sdk-install-plan-tests"
"$out/sdk-install-plan-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/MCPConfiguration.swift \
  apps/jidr-swiftui-prototype/Tests/MCP/main.swift -o "$out/mcp-configuration-tests"
"$out/mcp-configuration-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/AppListLoader.swift \
  apps/jidr-swiftui-prototype/Tests/AppList/main.swift -o "$out/app-list-tests"
"$out/app-list-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/LogFilter.swift \
  apps/jidr-swiftui-prototype/Sources/LogStream.swift \
  apps/jidr-swiftui-prototype/Tests/LogFilter/main.swift -o "$out/log-filter-tests"
"$out/log-filter-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/PlayerInput.swift \
  apps/jidr-swiftui-prototype/Tests/PlayerInput/main.swift -o "$out/player-input-tests"
"$out/player-input-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/PlayerSession.swift \
  apps/jidr-swiftui-prototype/Sources/GameShortcuts.swift \
  apps/jidr-swiftui-prototype/Tests/GameShortcuts/main.swift -o "$out/game-shortcut-tests"
"$out/game-shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Sources/PlayerSession.swift \
  apps/jidr-swiftui-prototype/Tests/PlayerSession/main.swift -o "$out/player-session-tests"
"$out/player-session-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/Reconnect.swift \
  apps/jidr-swiftui-prototype/Tests/Reconnect/main.swift -o "$out/reconnect-tests"
"$out/reconnect-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/Shortcuts.swift \
  apps/jidr-swiftui-prototype/Tests/Shortcuts/main.swift -o "$out/shortcut-tests"
"$out/shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/CommandPalette.swift \
  apps/jidr-swiftui-prototype/Tests/Palette/main.swift -o "$out/palette-tests"
"$out/palette-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/TaskCenter.swift \
  apps/jidr-swiftui-prototype/Tests/Tasks/main.swift -o "$out/task-center-tests"
"$out/task-center-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/RootSteps.swift \
  apps/jidr-swiftui-prototype/Tests/RootFlow/main.swift -o "$out/root-flow-tests"
"$out/root-flow-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui-prototype/Center/SnapshotData.swift \
  apps/jidr-swiftui-prototype/Tests/SnapshotDialogs/main.swift -o "$out/snapshot-data-tests"
"$out/snapshot-data-tests"
# Localization gate: mechanisms (a) .strings keys, (b) t()/model.text(),
# (c) inline language switches, plus the AppKit sinks, dynamic strings, error
# text and both Rust bridges. --self-test proves the rules catch violations
# before the real tree is checked; the baseline allowlist lives in
# Tests/i18n_allowlist.txt.
python3 apps/jidr-swiftui-prototype/Tests/localization_coverage.py --self-test
