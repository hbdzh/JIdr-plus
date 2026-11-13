#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/target/swiftui-tests"
mkdir -p "$out/module-cache"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/FrameDecoder.swift \
  apps/jidr-swiftui/Tests/main.swift -o "$out/frame-decoder-tests"
"$out/frame-decoder-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/KeyMapping.swift \
  apps/jidr-swiftui/Tests/Mapping/main.swift -o "$out/key-mapping-tests"
"$out/key-mapping-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/WindowQuality.swift \
  apps/jidr-swiftui/Tests/Quality/main.swift -o "$out/window-quality-tests"
"$out/window-quality-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/GameWindowState.swift \
  apps/jidr-swiftui/Tests/WindowState/main.swift -o "$out/window-state-tests"
"$out/window-state-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/DeviceCreation.swift \
  apps/jidr-swiftui/Tests/Creation/main.swift -o "$out/device-creation-tests"
"$out/device-creation-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/SDKInstallPlan.swift \
  apps/jidr-swiftui/Sources/OperationMessages.swift \
  apps/jidr-swiftui/Tests/SDK/main.swift -o "$out/sdk-install-plan-tests"
"$out/sdk-install-plan-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/MCPConfiguration.swift \
  apps/jidr-swiftui/Tests/MCP/main.swift -o "$out/mcp-configuration-tests"
"$out/mcp-configuration-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/AppListLoader.swift \
  apps/jidr-swiftui/Tests/AppList/main.swift -o "$out/app-list-tests"
"$out/app-list-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/LogFilter.swift \
  apps/jidr-swiftui/Sources/LogStream.swift \
  apps/jidr-swiftui/Tests/LogFilter/main.swift -o "$out/log-filter-tests"
"$out/log-filter-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/PlayerInput.swift \
  apps/jidr-swiftui/Tests/PlayerInput/main.swift -o "$out/player-input-tests"
"$out/player-input-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/PlayerSession.swift \
  apps/jidr-swiftui/Sources/GameShortcuts.swift \
  apps/jidr-swiftui/Tests/GameShortcuts/main.swift -o "$out/game-shortcut-tests"
"$out/game-shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/PlayerSession.swift \
  apps/jidr-swiftui/Tests/PlayerSession/main.swift -o "$out/player-session-tests"
"$out/player-session-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/Reconnect.swift \
  apps/jidr-swiftui/Tests/Reconnect/main.swift -o "$out/reconnect-tests"
"$out/reconnect-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/Shortcuts.swift \
  apps/jidr-swiftui/Tests/Shortcuts/main.swift -o "$out/shortcut-tests"
"$out/shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/CommandPalette.swift \
  apps/jidr-swiftui/Tests/Palette/main.swift -o "$out/palette-tests"
"$out/palette-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/TaskCenter.swift \
  apps/jidr-swiftui/Tests/Tasks/main.swift -o "$out/task-center-tests"
"$out/task-center-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/RootSteps.swift \
  apps/jidr-swiftui/Tests/RootFlow/main.swift -o "$out/root-flow-tests"
"$out/root-flow-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Center/SnapshotData.swift \
  apps/jidr-swiftui/Tests/SnapshotDialogs/main.swift -o "$out/snapshot-data-tests"
"$out/snapshot-data-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/OperationMessages.swift \
  apps/jidr-swiftui/Sources/PlayerSession.swift \
  apps/jidr-swiftui/Sources/WindowQuality.swift \
  apps/jidr-swiftui/Sources/KeyMapping.swift \
  apps/jidr-swiftui/Sources/LogFilter.swift \
  apps/jidr-swiftui/Sources/LogStream.swift \
  apps/jidr-swiftui/Tests/LocalizationEnglish/main.swift -o "$out/localization-english-tests"
"$out/localization-english-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/DeviceSettingsSave.swift \
  apps/jidr-swiftui/Sources/DevicePolicies.swift \
  apps/jidr-swiftui/Sources/DeviceCameraDraft.swift \
  apps/jidr-swiftui/Sources/RoutePlaybackState.swift \
  apps/jidr-swiftui/Sources/DevicePresentation.swift \
  apps/jidr-swiftui/Sources/WindowQuality.swift \
  apps/jidr-swiftui/Tests/SettingsSave/main.swift -o "$out/device-settings-save-tests"
"$out/device-settings-save-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/jidr-swiftui/Sources/DeviceToolOperations.swift \
  apps/jidr-swiftui/Tests/DeviceTools/main.swift -o "$out/device-tool-tests"
"$out/device-tool-tests"
# Localization gate: mechanisms (a) .strings keys, (b) t()/model.text(),
# (c) inline language switches, plus the AppKit sinks, dynamic strings, error
# text and both Rust bridges. --self-test proves the rules catch violations
# before the real tree is checked; the baseline allowlist lives in
# Tests/i18n_allowlist.txt.
python3 apps/jidr-swiftui/Tests/localization_coverage.py --self-test
python3 apps/jidr-swiftui/Tests/Deployment/main.py
python3 apps/jidr-swiftui/Tests/Metadata/main.py

python3 apps/jidr-swiftui/Tests/CenterUI/contrast.py
