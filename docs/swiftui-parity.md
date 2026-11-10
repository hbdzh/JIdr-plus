# SwiftUI parity matrix

Status: **M0 audit complete** (2026-11-11, baseline `master` @ `b46a2f3` + M0 fixes).
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
`launcher-reconnecting`.

An earlier count of 55 "entry points" measured screens, not behaviour; this table is the
binding one.

## Structural findings (these outweigh individual scenes)

1. **Device window form differs.** Slint shows the device screen inside the main workbench as
   a device tab; the SwiftUI app only has a separate player window, so `player-booting` and
   `player-stopped` are unreachable. Open decision: keep the window model and accept a form
   difference, or add an in-window device view. Recommendation: functional parity first,
   decide the form separately.
2. **Widget panels are separate windows** in SwiftUI instead of the docked panel beside the
   device screen; discoverability and persistence differ.
3. **Missing cross-cutting infrastructure**: daemon reconnect, background task list/cancel,
   global keyboard shortcuts (⌘K/⌘L/⌘J/⌥⌘0/⌃⌘F/⌘N/⌘, /Esc), RTL/layout direction.
4. **Root is a coarse success/failure state**; the 5-step timeline, log tail, stop-and-revert
   and Play Store wait/countdown branches are missing.
5. **Localization architecture drifts from Slint**: Chinese-key reverse tables plus three
   mechanisms, with 36 reachable Chinese strings in English mode (screenshot/recording file
   names, player status bubbles, snapshot root tags, settings validation, keymap errors).

## Module matrix

Legend — Impl.: ❌ not started · 🟡 skeleton · ✅ complete. Verified: ⬜ none · 🧪 offline
(unit/binary tests; not module-level acceptance) · 📱 real emulator/game. No module has
real-device evidence yet.

| # | Module | Slint reference | SwiftUI entry | Impl. | Verified | Remaining |
|---|---|---|---|---|---|---|
| 1 | Device center (list/search/details/lifecycle/delete) | `launcher/mod.rs`, `launcher-*` | `Center/DeviceViews.swift`, `DeviceModel.swift` | 🟡 | ⬜ | toasts/status pills, session+Magisk details, daemon reconnect |
| 2 | Create/edit device | `device_form/mod.rs`, `edit-device-*` | `NewDeviceView`, `EditDeviceView` | 🟡 | 🧪 validation | five-page form, data page missing, error copy localized |
| 3 | First-run SDK setup | `wizard/mod.rs`, `setup-*` | `InstallSDKView` | 🟡 | 🧪 plan/cancel | step bar, detection, licence scroll, per-download rows |
| 4 | Settings (+MCP, cache, update, storage preflight) | `settings/mod.rs`, `settings-*` | `SettingsView`, `MCPConfiguration.swift` | 🟡 | ⬜ | agents page, item walkthrough |
| 5 | Snapshots | `snapshots/mod.rs`, `snapshots-*` | `SnapshotsView` | 🟡 | ⬜ | refusal/save dialogs, root tags, sizes |
| 6 | Root (modes/verify/revert/modules/props/certs/auto-grant) | `root/mod.rs`, `root-*` | `FullRootView`, `AdvancedTools.swift` | 🟡 | ⬜ | 5-step timeline, log tail, stop+revert, Play Store wait/countdown |
| 7 | Widget panels | `widgets/*`, `widgets-*` | `AdvancedTools.swift` (6 tabs) | 🟡 | ⬜ | docked-panel parity or accepted form difference, map click, sensor presets |
| 8 | Game window (frame/input/IME/clipboard/recording/screenshot/drop/pixel-perfect/fullscreen/sidebar/on-top/state) | `player/*`, `player-*` | `Sources/GameWindow.swift` | 🟡 | ⬜ | fullscreen reveal, debug overlay, uninstall, recording/logcat status, app-tab form |
| 9 | Key mapping and shortcuts | `player/keymap.rs`, `game_shortcuts.rs`, `edit_shortcuts.rs` | `Sources/KeyMapping.swift` | 🟡 | 🧪 keymap | global shortcuts, multi-touch mapping, conflict checks |
| 10 | App/game library | `game_library.rs`, `launcher-game-list` | center app list | 🟡 | ⬜ | daemon copy, empty state, real device |
| 11 | Command palette | `palette/mod.rs`, `palette-*` | — | ❌ | ⬜ | not ported |
| 12 | Background task list | `app.rs` tasks, `launcher-tasks` | — | ❌ | ⬜ | not ported (only SDK cancel) |
| 13 | Menu bar/Dock/single instance/window restore/activation/quit | `macos_dock.rs` | — | ❌ | ⬜ | M3 |
| 14 | Design tokens/Lucide icons | `docs/design/tokens.json`, `ui/icons` | system colours/SF Symbols/2 PNGs | ❌ | ⬜ | generate/map in M3 |
| 15 | Localization EN/ZH | `i18n.rs`, `zh_CN.po` | `.strings` 214 keys + `t()` 249 sites + ternary 26 | 🟡 | 🧪 strings only | 36 reachable leaks, CI rules, visual walkthrough |
| 16 | Test assets | 130 unit tests, 204 goldens | 10 test binaries | ❌ | 🧪 narrow | SwiftPM/XCTest, rendered goldens, real-device tests |
| 17 | Release chain/CI | `xtask/release.rs`, `packaging/macos`, CI | hand-written `swiftc` scripts | ❌ | ⬜ | Swift CI, release branch, signing/DMG |
| 18 | Decisions/licence/docs | D2/D15/D18/D20, ADRs | ADR-0003 (proposed) | 🟡 | — | maintainer approval; D18 wording at M6 |
| 19 | Config compatibility | `window-state/*.json`, `keymaps/*`, `gui-prefs.json` | same keymaps/quality/prefs paths; geometry in `.swiftui.json` | 🟡 | 🧪 window state | bidirectional matrix + rollback rule |
| 20 | Performance | ADR-0001, `display-performance.md` | not measured | ❌ | ⬜ | baseline A/B (M4) |
| 21 | Daemon reconnect (center bridge) | `src/bridge.rs` reconnect | one `connect_or_spawn`, notice only | ❌ | ⬜ | P0 infrastructure |
| 22 | Global shortcuts | `ui/app.slint` key handling | — | ❌ | ⬜ | P0 with palette |
| 23 | RTL / layout direction (D33) | `theme.slint` rtl, mirrored goldens | — | ❌ | ⬜ | decision needed: defer with semantic leading/trailing, or implement |

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

- **P0 (blocks acceptance)**: daemon reconnect; task list/cancel; device-window integration
  (form decision); Root timeline/stop-and-revert/Play Store wait; global shortcuts + palette;
  RTL decision.
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
