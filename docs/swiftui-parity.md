# SwiftUI parity matrix

Status: **M2 implemented, real-device verification pending** (2026-11-11, baseline `master` @ `ba69547`).
Plan, gates and tooling: [docs/swiftui-migration.md](swiftui-migration.md).
Full evidence:
[68-scene mapping](swiftui-parity-scenes.md) and
[localization gaps](swiftui-localization.md).

## Golden-scene coverage (behaviour level)

68 scenes = 204 PNGs (dark/light/rtl). Judged per scene: the scene's main UI **and**
behaviour must exist.

| State | Scenes |
|---|---:|
| Entry exists (only detail differences) | 7 |
| Partial (entry exists, ≥1 visible/behavioural element missing) | 49 |
| Missing (no entry, or the state is unreachable) | 12 |

Missing scenes: `launcher-tasks`, `palette`, `palette-filtered`, `edit-device-data`,
`player-fullscreen-reveal`, `player-overlay`, `player-booting`, `player-stopped`,
`root-awaiting-grant`, `root-devtools-failed`, `root-devtools-no-auto-grant`,
`launcher-reconnecting`. `player-booting`/`player-stopped` stay missing until M2-B adds those
states to the standalone player window.

An earlier count of 55 "entry points" measured screens, not behaviour; this table is the
binding one. M2 implemented the whole missing list except `edit-device-data` (the device
form still lacks a data page): palette, task list, player booting/stopped, overlay,
fullscreen reveal, root awaiting-grant and no-auto-grant. A fresh scene audit runs in M4.

## Structural findings (these outweigh individual scenes)

1. **Device window form (decided; implemented in M2).** Slint shows the device screen inside the main
   workbench as a device tab; this migration keeps **standalone device windows** and does not
   port the tab. The consequence is functional: the player window must handle the booting,
   stopped and disconnected states itself (`player-booting`/`player-stopped`), tracked in M2-B.
2. **Widget panels are separate windows** in SwiftUI instead of the docked panel beside the
   device screen; discoverability and persistence differ.
3. **Cross-cutting infrastructure (implemented in M2)**: daemon reconnect with bounded
   backoff, background task list/cancel, command palette and global shortcuts, toasts.
   RTL is not required (decided 2026-11-11).
4. **Root flow (implemented in M2)**: 5-step timeline, recent steps and log tail,
   stop-and-revert, Play Store guided grant with countdown and the unverified branch.
5. **Localization**: M2 fixed the 13 baseline rows it touched; the gate now baselines 34
   known leaks (down from 47), listed in `Tests/i18n_allowlist.txt`. The visual English
   walkthrough is still pending (M3).

## Module matrix

Legend — Impl.: ❌ not started · 🟡 skeleton · ✅ complete. Verified: ⬜ none · 🧪 offline
(unit/binary tests; not module-level acceptance) · 📱 real emulator/game. M2 modules have offline
evidence (unit tests, fixtures, screenshots); real-device verification runs in M3/M4.

| # | Module | Slint reference | SwiftUI entry | Impl. | Verified | Remaining |
|---|---|---|---|---|---|---|
| 1 | Device center (list/search/details/lifecycle/delete) | `launcher/mod.rs`, `launcher-*` | `Center/DeviceViews.swift`, `DeviceModel.swift`, `Reconnect.swift` | ✅ | ⬜ | real-device walkthrough |
| 2 | Create/edit device | `device_form/mod.rs`, `edit-device-*` | `NewDeviceView`, `EditDeviceView` | 🟡 | 🧪 validation | five-page form, data page missing, error copy localized |
| 3 | First-run SDK setup | `wizard/mod.rs`, `setup-*` | `InstallSDKView` | 🟡 | 🧪 plan/cancel | step bar, detection, licence scroll, per-download rows |
| 4 | Settings (+MCP, cache, update, storage preflight) | `settings/mod.rs`, `settings-*` | `SettingsView`, `MCPConfiguration.swift` | 🟡 | ⬜ | agents page, item walkthrough |
| 5 | Snapshots | `snapshots/mod.rs`, `snapshots-*` | `SnapshotsView`, `SnapshotData.swift`, `SnapshotDialogs.swift` | ✅ | ⬜ | real-device save/load/refusal walkthrough |
| 6 | Root (modes/verify/revert/modules/props/certs/auto-grant) | `root/mod.rs`, `root-*` | `RootFlow.swift`, `RootSteps.swift`, `RootDevTools.swift` | ✅ | ⬜ | real-device root cycle and Play Store grant |
| 7 | Widget panels | `widgets/*`, `widgets-*` | `AdvancedTools.swift` (6 tabs) | ✅ | ⬜ | real-device widgets; separate-window form accepted; sensor presets thin |
| 8 | Game window (frame/input/IME/clipboard/recording/screenshot/drop/pixel-perfect/fullscreen/sidebar/on-top/state) | `player/*`, `player-*` | `GameWindow.swift`, `PlayerWindowView.swift`, `PlayerSession.swift` | ✅ | ⬜ | real-device input/recording/gesture semantics |
| 9 | Key mapping and shortcuts | `player/keymap.rs`, `game_shortcuts.rs`, `edit_shortcuts.rs` | `KeyMapping.swift`, `GameShortcuts.swift` | ✅ | 🧪 | real-device shortcut and multi-touch verification |
| 10 | App/game library | `game_library.rs`, `launcher-game-list` | center app list | 🟡 | ⬜ | daemon copy, empty state, real device |
| 11 | Command palette | `palette/mod.rs`, `palette-*` | `CommandPalette.swift`, `PaletteView.swift` | ✅ | 🧪 | real UI run |
| 12 | Background task list | `app.rs` tasks, `launcher-tasks` | `TaskCenter.swift`, `Overlays.swift` | ✅ | 🧪 | real jobs/cancel on a device |
| 13 | Menu bar/Dock/single instance/window restore/activation/quit | `macos_dock.rs` | `MenuBar.swift`, `SingleInstance.swift`, `main.swift` | ✅ | 🧪 | real click-through needs accessibility permission |
| 14 | Design tokens/Lucide icons | `docs/design/tokens.json`, `ui/icons` | `generate-tokens.sh`, `DesignTokens.swift`, `DesignTokenData.swift` | ✅ | 🧪 | 903 Wb* sites, 69 WbIcon constants; fonts bundled and resolved |
| 15 | Localization EN/ZH | `i18n.rs`, `zh_CN.po` | coded bridge/Swift errors + `.strings` + CI gate | ✅ | 🧪 | baseline 0; English corpus test; EN screenshot variants |
| 16 | Test assets | 130 unit tests, 204 goldens | 14 logic test groups, SwiftUI screenshot harness | 🟡 | 🧪 | regenerate baselines, real-device tests |
| 17 | Release chain/CI | `xtask/release.rs`, `packaging/macos`, CI | package-test.sh + swift-macos CI job + token-drift check | 🟡 | ⬜ | release branch, signing/notarization (M5) |
| 18 | Decisions/licence/docs | D2/D15/D18/D20, ADRs | ADR-0003 accepted + D44 | ✅ | — | D18 wording at M6 |
| 19 | Config compatibility | `window-state/*.json`, `keymaps/*`, `gui-prefs.json` | same paths, display id added, legacy readers tested | ✅ | 🧪 | covered by tests; real rollback run in M4 |
| 20 | Performance | ADR-0001, `display-performance.md` | not measured | ❌ | ⬜ | baseline A/B (M4) |
| 21 | Daemon reconnect (center bridge) | `src/bridge.rs` reconnect | `Reconnect.swift`, `DeviceModel.swift` | ✅ | 🧪 | real daemon kill/restart verified; device soak in M4 |
| 22 | Global shortcuts | `ui/app.slint` key handling | `Shortcuts.swift`, `main.swift` monitor | ✅ | 🧪 | real keyboard end-to-end |
| 23 | RTL / layout direction (D33) | `theme.slint` rtl, mirrored goldens | — | — | — | **not required** (2026-11-11): Chinese/English only; semantic leading/trailing where free |

## Flows the goldens do not cover

| Flow | Slint reference | SwiftUI today |
|---|---|---|
| Job progress/cancel with a task list | `app.rs`, `launcher-tasks` | absent; SDK install only |
| Reconnect after bridge/daemon exit | `bridge.rs` reconnect, `player/session.rs` | player policy only; center loses state |
| Corrupt keymap/shortcut refused, original kept | `keymap.rs`, `game_shortcuts.rs` | implemented and unit-tested |
| Safe quit with a running device | `app.rs` quit flow | asks and stops; unverified on device |
| Multi-window / two devices | `player/mod.rs` per-device windows | opens windows; unverified |
| APK signature-conflict reinstall confirmation | `player/mod.rs` | missing |
| App uninstall entry | `player/mod.rs` | missing |
| Recording while closing the window | `player/game.rs` (does not block) | hard-blocks; daemon behaviour unverified |
| Localized dynamic errors | `i18n::device_label`, error maps | 36 reachable leaks; see localization doc |

## Priorities

- **P0 done in M2**: daemon reconnect; task list/cancel; player-window booting/stopped/
  reconnect states; Root timeline/stop-and-revert/Play Store wait; global shortcuts + palette.
  What remains before the switch is real-device verification, not new UI.
- **P1 (visible in goldens)**: palette, snapshot dialogs, five-page device form (data page),
  settings IA/agents page, fullscreen reveal, debug overlay, recording clock.
- **P2**: first-run wizard fidelity, docked widget panels, screenshot/recording semantics,
  Dock menu, toast styling.

## Deliberately not ported (proposal)

Self-drawn window decorations and traffic-light alignment; the Slint golden/offscreen/fixtures
pipeline (replace with a SwiftUI snapshot harness); `theme.slint` value copying (consume
`tokens.json`); the gettext `.po` pipeline (migrate strings, not the mechanism); MockScreen and
device art fixtures; dev-only env hooks; the second standalone player app (one entry point);
golden-only properties; pixel-copying the device tab form; Slint's `Theme.rtl ? … : …`
branches (implement semantically instead).
