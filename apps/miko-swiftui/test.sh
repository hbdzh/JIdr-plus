#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/target/swiftui-tests"
mkdir -p "$out/module-cache"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/PacketLoss.swift \
  apps/miko-swiftui/Tests/PacketLoss/main.swift -o "$out/packet-loss-tests"
"$out/packet-loss-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/DeviceBudget.swift \
  apps/miko-swiftui/Tests/DeviceBudget/main.swift -o "$out/device-budget-tests"
"$out/device-budget-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/FrameDecoder.swift \
  apps/miko-swiftui/Tests/main.swift -o "$out/frame-decoder-tests"
"$out/frame-decoder-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/KeyMapping.swift \
  apps/miko-swiftui/Tests/Mapping/main.swift -o "$out/key-mapping-tests"
"$out/key-mapping-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/WindowQuality.swift \
  apps/miko-swiftui/Tests/Quality/main.swift -o "$out/window-quality-tests"
"$out/window-quality-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/GameWindowState.swift \
  apps/miko-swiftui/Tests/WindowState/main.swift -o "$out/window-state-tests"
"$out/window-state-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/DeviceOverviewPrimaryAction.swift \
  apps/miko-swiftui/Tests/DeviceOverview/main.swift -o "$out/device-overview-action-tests"
"$out/device-overview-action-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/DeviceCreation.swift \
  apps/miko-swiftui/Tests/Creation/main.swift -o "$out/device-creation-tests"
"$out/device-creation-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/SDKInstallPlan.swift \
  apps/miko-swiftui/Sources/OperationMessages.swift \
  apps/miko-swiftui/Tests/SDK/main.swift -o "$out/sdk-install-plan-tests"
"$out/sdk-install-plan-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/MCPConfiguration.swift \
  apps/miko-swiftui/Tests/MCP/main.swift -o "$out/mcp-configuration-tests"
"$out/mcp-configuration-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/AppListLoader.swift \
  apps/miko-swiftui/Tests/AppList/main.swift -o "$out/app-list-tests"
"$out/app-list-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/LogFilter.swift \
  apps/miko-swiftui/Sources/LogStream.swift \
  apps/miko-swiftui/Tests/LogFilter/main.swift -o "$out/log-filter-tests"
"$out/log-filter-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/CenterRequestWriter.swift \
  apps/miko-swiftui/Tests/CenterRequestWriter/main.swift -o "$out/center-request-writer-tests"
"$out/center-request-writer-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/DeviceAppSearch.swift \
  apps/miko-swiftui/Tests/DeviceAppSearch/main.swift -o "$out/device-app-search-tests"
"$out/device-app-search-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/PlayerInput.swift \
  apps/miko-swiftui/Tests/PlayerInput/main.swift -o "$out/player-input-tests"
"$out/player-input-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/PlayerSession.swift \
  apps/miko-swiftui/Sources/GameShortcuts.swift \
  apps/miko-swiftui/Tests/GameShortcuts/main.swift -o "$out/game-shortcut-tests"
"$out/game-shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/PlayerSession.swift \
  apps/miko-swiftui/Tests/PlayerSession/main.swift -o "$out/player-session-tests"
"$out/player-session-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/SyncHub.swift \
  apps/miko-swiftui/Tests/Sync/main.swift -o "$out/sync-hub-tests"
"$out/sync-hub-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/Reconnect.swift \
  apps/miko-swiftui/Tests/Reconnect/main.swift -o "$out/reconnect-tests"
"$out/reconnect-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/Shortcuts.swift \
  apps/miko-swiftui/Tests/Shortcuts/main.swift -o "$out/shortcut-tests"
"$out/shortcut-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/CommandPalette.swift \
  apps/miko-swiftui/Tests/Palette/main.swift -o "$out/palette-tests"
"$out/palette-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/TaskCenter.swift \
  apps/miko-swiftui/Tests/Tasks/main.swift -o "$out/task-center-tests"
"$out/task-center-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/RootSteps.swift \
  apps/miko-swiftui/Tests/RootFlow/main.swift -o "$out/root-flow-tests"
"$out/root-flow-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/PanelCoordinator.swift \
  apps/miko-swiftui/Tests/PanelCoordinator/main.swift -o "$out/panel-coordinator-tests"
"$out/panel-coordinator-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Center/SnapshotData.swift \
  apps/miko-swiftui/Tests/SnapshotDialogs/main.swift -o "$out/snapshot-data-tests"
"$out/snapshot-data-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/OperationMessages.swift \
  apps/miko-swiftui/Sources/PlayerSession.swift \
  apps/miko-swiftui/Sources/WindowQuality.swift \
  apps/miko-swiftui/Sources/KeyMapping.swift \
  apps/miko-swiftui/Sources/LogFilter.swift \
  apps/miko-swiftui/Sources/LogStream.swift \
  apps/miko-swiftui/Tests/LocalizationEnglish/main.swift -o "$out/localization-english-tests"
"$out/localization-english-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/DeviceSettingsSave.swift \
  apps/miko-swiftui/Sources/DevicePolicies.swift \
  apps/miko-swiftui/Sources/DeviceCameraDraft.swift \
  apps/miko-swiftui/Sources/RoutePlaybackState.swift \
  apps/miko-swiftui/Sources/DevicePresentation.swift \
  apps/miko-swiftui/Sources/WindowQuality.swift \
  apps/miko-swiftui/Tests/SettingsSave/main.swift -o "$out/device-settings-save-tests"
"$out/device-settings-save-tests"
swiftc -module-cache-path "$out/module-cache" \
  apps/miko-swiftui/Sources/DeviceToolOperations.swift \
  apps/miko-swiftui/Tests/DeviceTools/main.swift -o "$out/device-tool-tests"
"$out/device-tool-tests"
# Localization gate: mechanisms (a) .strings keys, (b) t()/model.text(),
# (c) inline language switches, plus the AppKit sinks, dynamic strings, error
# text and both Rust bridges. --self-test proves the rules catch violations
# before the real tree is checked; the baseline allowlist lives in
# Tests/i18n_allowlist.txt.
python3 apps/miko-swiftui/Tests/localization_coverage.py --self-test
python3 apps/miko-swiftui/Tests/Deployment/main.py
python3 apps/miko-swiftui/Tests/Metadata/main.py

python3 apps/miko-swiftui/Tests/CenterUI/contrast.py
