# SwiftUI game-window prototype

These are experimental macOS SwiftUI/AppKit clients, not a replacement for the Slint application. The standalone game-window prototype connects to an already-running device and does not start, stop, create or migrate devices. The separate device-center preview can create, start, stop and delete devices and snapshots through the daemon. Use disposable test devices and an isolated `JIDR_HOME`; do not point either preview at valuable game data.

The SwiftUI/AppKit source is GPL-3.0-only; see `apps/jidr-gui/LICENSE-GPL`. The independent Rust bridge is Apache-2.0; see `LICENSE-APACHE`. Upstream notices remain in `NOTICE`.

## Build and run

Requires Xcode, the workspace Rust toolchain, and `protoc` (or `PROTOC` pointing at one). From the repository root:

```bash
apps/jidr-swiftui-prototype/build.sh
JIDR_HOME=/absolute/path/to/isolated-test-home \
  target/swiftui-prototype/JidrSwiftUIPrototype.app/Contents/MacOS/JidrSwiftUIPrototype \
  TEST_DEVICE 720 1280 "$PWD/target/debug/jidr-swiftui-bridge"
```

The daemon for that `JIDR_HOME` and the test device must already be running. Pass the device's actual unrotated panel width and height; the prototype does not discover them. The app and helper live under `target/` and do not overwrite the installed Jidr app.

## Scope and limitations

The helper reads frames directly from the emulator gRPC stream and sends mouse/key/clipboard commands. Raw frames use a bounded queue and the UI displays only the newest pending frame. Clipboard synchronization occurs only on user copy, cut, paste or committed IME text; a test-only named pasteboard can be selected with `JIDR_PROTOTYPE_TEST_PASTEBOARD`.

Chinese IME text is committed using the Android clipboard and paste, so the target Android field must support paste. Keyboard handling and game compatibility are preliminary. Copy waits for a new Android clipboard event and deliberately avoids returning stale content; copying text identical to the existing Android clipboard may therefore leave the host clipboard unchanged. The center can reconnect a disconnected player after a successful root module or certificate operation when there is no unsaved key mapping or active/unknown recording. Production packaging, real-game acceptance and data migration are incomplete.

The prototype sidebar can be hidden or shown and provides navigation, volume, rotation and fullscreen controls. It also supports saving screenshots and choosing or dragging a file to install APKs or send files to the device. Basic per-device key mapping and recording are available. The center provides battery, GPS and route, network and proxy, sensors, logs, Root management, simulated phone and SMS, device clipboard, fingerprint and developer controls. Some original advanced workflows still need parity review and end-to-end validation. Recording must be stopped and saved before closing the prototype. The window follows the streamed screen aspect ratio outside fullscreen; fullscreen may letterbox to preserve that ratio.

The Logcat panel can filter by priority and follow a dedicated live log connection while the panel is active. It retains the latest 1,000 lines and warns when the stream reports dropped events; stopping or leaving the panel closes that connection.

Run the local decoder, mapping, creation, quality, log and localization-gate checks with
`apps/jidr-swiftui-prototype/test.sh`. To build an installable ad-hoc-signed test bundle and
DMG that run without a development environment, use `apps/jidr-swiftui-prototype/package-test.sh`
(see `packaging/swiftui/README.md`; the test bundle uses its own `Jidr-SwiftUI-Test` data
directory and never touches the user's Jidr data). On macOS with a GUI session, `bash apps/jidr-swiftui-prototype/test-window.sh` checks game-window lifetime without an emulator.

Deterministic UI snapshots render offscreen from bridge fixtures, so no daemon or emulator is
needed (`bash apps/jidr-swiftui-prototype/snapshot.sh --check` with a logged-in macOS GUI
session; `--update` rewrites the baselines and `--only CASE` limits a run). The five baselines
in `apps/jidr-swiftui-prototype/Tests/golden/` are `center-empty`, `center-populated`,
`center-load-failure`, `center-long-task` and `player-running`; the rects are fixed, the
appearance is dark, animations are disabled and the locale is zh-Hans, and `--check` compares
pixels exactly (no tolerance). Fixture mode is opt-in per process: set `JIDR_CENTER_FIXTURE`
to `empty`, `populated`, `load-failure`, `long-task` or `disconnect` for the center bridge, or
set `JIDR_PLAYER_FIXTURE=1` for the player bridge; when unset, both bridges use their normal
daemon/gRPC paths. The baselines are provisional until the M2 UI work lands: refresh them with
`--update` after a deliberate visual change, and treat a `--check` failure before that refresh
as expected.

## Device-center development preview

Build with `apps/jidr-swiftui-prototype/build-center.sh`. This builds a separate app in `target/swiftui-center`, and does not replace the installed application. The center requires an explicit isolated `JIDR_HOME` and the paths of the center bridge, standalone player executable and player bridge as arguments. If a daemon is not running for that home, set `JIDR_DAEMON_BIN` to the intended test daemon executable.

For local development, `JIDR_HOME=/absolute/path/to/isolated-test-home bash apps/jidr-swiftui-prototype/run-center.sh` starts the preview directly from the current session, preserving its environment. Set `ANDROID_HOME` when the test images live in a separate SDK. This launcher does not grant macOS access to an external volume; the user session must already be able to access it.

The center is incomplete: it does not yet reproduce every existing settings and advanced-device workflow, its language coverage is partial, and production packaging and a full isolated acceptance run are outstanding. Storage settings can select a prospective destination and run a read-only space/format preflight. This check does not copy, validate recovery, switch locations, or authorize a migration. Storage migration remains unavailable. SDK installation asks the user to review and accept each displayed licence before recording consent; do not automate that confirmation. The preview must not be shipped as the production app until feature parity, safe shutdown and game-data/snapshot recovery have been verified.

The SDK bridge can be exercised with a synthetic local repository and synthetic licence using `JIDR_TEST_DAEMON_BIN=/path/to/jidr JIDR_TEST_CENTER_BRIDGE=/path/to/jidr-center-bridge python3 apps/jidr-swiftui-prototype/Tests/SDK/integration.py`. The test creates its own temporary home and synthetic archives, verifies that installation is refused before synthetic consent, and checks both tool and image installation. It does not accept a Google licence or install a Google package.

SDK installation can continue after its panel is closed, and can be cancelled once a job ID is available. `Tests/SDK/cancel_integration.py` tests cancellation against a throttled synthetic repository and checks that an unrelated file is preserved; it never accepts a Google licence.

## Isolated migration recovery check

The SDK integration test `migration_restores_guest_data_and_snapshot` creates its own temporary AVD, writes a test marker, creates a snapshot, performs a verified offline copy and checks that the copied snapshot restores the marker while the source remains present. This proves that test scenario only; it is not evidence that a particular game's data or all existing snapshots can be restored. The SwiftUI preflight and tests never activate a storage location.
