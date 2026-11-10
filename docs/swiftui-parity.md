# SwiftUI parity matrix

Baseline: `master` @ `b46a2f3` (+ M0 fixes). Verification snapshot: 2026-11-11.
How the work is judged and which gates apply: [docs/swiftui-migration.md](swiftui-migration.md).

Legend — **Impl.**: ❌ not started · 🟡 skeleton (entry exists, rules/edge cases incomplete) ·
✅ complete. **Verified**: ⬜ none · 🧪 offline (unit tests or the Swift test binaries) ·
📱 real emulator/game.

A row moves on evidence, in this order: implementation, then a test or recorded verification,
then the verification column. "Has an entry point" is not "verified".

## Module matrix

| # | Module | Slint reference | SwiftUI entry | Impl. | Verified | Remaining |
|---|---|---|---|---|---|---|
| 1 | Device center: list/search/details/lifecycle/delete | `launcher/mod.rs`, `launcher-*` goldens | `Center/DeviceViews.swift`, `Center/DeviceModel.swift` | ✅ | 🧪 form logic only | task center, compact layout, real-device walkthrough |
| 2 | Create/edit device | `device_form/mod.rs`, `edit-device-*` | `NewDeviceView`, `EditDeviceView` | ✅ | 🧪 validation tests | real-device walkthrough of every rule |
| 3 | First-run SDK setup | `wizard/mod.rs`, `setup-*` | `InstallSDKView` | 🟡 | 🧪 plan + cancel integration | 4-step flow, "first device" step, resume |
| 4 | Settings (+MCP/agents, cache, update, storage preflight) | `settings/mod.rs`, `settings-*` | `SettingsView`, `MCPConfiguration.swift` | 🟡 | 🧪 | defaults/ranges/error paths walkthrough |
| 5 | Snapshots | `snapshots/mod.rs`, `snapshots-*` | `SnapshotsView` | 🟡 | ⬜ | refusal explanation, root tags, thumbnails |
| 6 | Root (modes, verify, revert, modules, props, CA certs, auto-grant) | `root/mod.rs`, `root-*` | `FullRootView`, `AdvancedTools.swift` | 🟡 | 🧪 messages only | Play Store guided grant, `writable_system`, real props edit |
| 7 | Widget panels (battery/GPS/net/sensors/phone/SMS/fingerprint/clipboard/dev/logcat) | `widgets/*`, `widgets-*` | `AdvancedTools.swift` (6 tabs) | ✅ | 🧪 | map click-to-set-fix, sensor presets, real device |
| 8 | Game window (frame/input/IME/clipboard/recording/screenshot/drop/pixel-perfect/fullscreen/sidebar/on-top/state/reconnect) | `player/*`, `player-*` | `Sources/GameWindow.swift` | 🟡 | ⬜ | fullscreen reveal, debug overlay, app uninstall |
| 9 | Key mapping and shortcuts | `player/keymap.rs`, `game_shortcuts.rs`, `edit_shortcuts.rs` | `Sources/KeyMapping.swift` | 🟡 | 🧪 | multi-touch mapping, shortcut editor, conflicts |
| 10 | Installed app/game library | `game_library.rs`, `launcher-game-list` | center app list | ✅ | ⬜ | real-device list, icons, launch confirmation |
| 11 | Command palette | `palette/mod.rs`, `palette-*` | — | ❌ | ⬜ | not ported yet |
| 12 | Background task list | `app.rs` tasks, `launcher-tasks` | — | ❌ | ⬜ | not ported yet |
| 13 | Menu bar/Dock/single instance/window restore | `macos_dock.rs` | — | ❌ | ⬜ | M3 |
| 14 | Design tokens/Lucide icons | `docs/design/tokens.json`, `ui/icons` | system colours, SF Symbols, 2 PNGs | ❌ | ⬜ | generate/map in M3 |
| 15 | Localization (EN/ZH) | `i18n.rs`, `zh_CN.po` (404 unique strings, all translated) | `.strings` 218 keys, `t()`, inline ternary | 🟡 | 🧪 `.strings` coverage only | English walkthrough; coverage for all three mechanisms |
| 16 | Test assets | 130 unit tests, 204 goldens, `player_emulator` | 10 small test binaries | ❌ | 🧪 | SwiftPM/XCTest, rendered goldens, real-device tests (M1/M4) |
| 17 | Release chain/CI | `xtask/release.rs`, `packaging/macos`, CI | hand-written `swiftc` scripts | ❌ | ⬜ | Swift CI job, release branch, signing/DMG (M1/M5) |
| 18 | Decisions/licence/docs | D2/D15/D18/D20, ADRs | ADR-0003 (proposed) | 🟡 | — | maintainer approval; D18 wording at M6 |
| 19 | Config compatibility | `window-state/*.json`, `keymaps/*`, `gui-prefs.json` | same keymaps/quality/prefs paths; window geometry in `<device>.swiftui.json` | 🟡 | 🧪 | bidirectional matrix + rollback rule (M3) |
| 20 | Performance | ADR-0001, `display-performance.md` | not measured | ❌ | ⬜ | baseline A/B (M4) |

## Golden-scene coverage

68 scenes (204 PNGs = 68 × dark/light/rtl). Current mapping: **55 have a SwiftUI entry point,
5 are partial, 8 are missing**. This counts entry points only; the module matrix above is the
behavioural weighting.

Missing: `palette`, `palette-filtered`, `launcher-tasks`, `edit-device-compact`,
`launcher-device-details-compact`, `player-fullscreen-reveal`, `player-overlay`,
`root-playstore-beta`.

Partial: `player-logcat` (lives in Advanced Tools, not the player panel), `root-awaiting-grant`,
`root-devtools-no-auto-grant`, `setup-4-first-device`, `snapshots-refusal`.

## Flows the goldens do not cover

| Flow | Slint reference | SwiftUI today |
|---|---|---|
| Job progress / cancel / task list | `app.rs` tasks, launcher-tasks | only `jobs.cancel` for SDK install; no task list |
| Reconnect after bridge/daemon exit | `player/session.rs` reconnect, `app.rs` | `GameReconnectPolicy`; not verified end to end |
| Corrupt keymap/shortcut config refused, original kept | `player/keymap.rs`, `game_shortcuts.rs` | `KeyMapping.load` keeps the file and reports; unit-tested |
| Safe quit with a running device | `app.rs` quit flow | center quit asks and stops devices; not verified on a device |
| Multi-window / two devices | `player/mod.rs` per-device windows | center opens player windows; not verified |
| APK signature-conflict reinstall confirmation | `player/mod.rs` install flow | missing confirmation copy/flow |
| App uninstall entry | `player/mod.rs` (`app.uninstall`) | not ported |
| Localized dynamic errors | `i18n::device_label`, error mappings | `OperationMessages`; needs EN walkthrough |

## Deliberately not ported (proposal)

- Device clone: the Slint GUI has no clone entry point either; the command stays CLI/MCP-only.
- Protocol/system-level features the GUI never exposed (pool, bases, budget internals) stay
  out; they remain CLI/MCP features.
- Fake "Genymotion parity" items listed as ⏭️ in [docs/parity.md](parity.md) are not in scope.
