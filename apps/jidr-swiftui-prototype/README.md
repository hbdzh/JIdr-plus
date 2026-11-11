# SwiftUI game-window prototype

These are experimental macOS SwiftUI/AppKit clients, not a replacement for the Slint application. The standalone game-window prototype connects to an already-running device and does not start, stop, create or migrate devices. The separate device-center preview can create, start, stop and delete devices and snapshots through the daemon. Use disposable test devices and an isolated `JIDR_HOME`; do not point either preview at valuable game data.

The SwiftUI/AppKit source is GPL-3.0-only; see `apps/jidr-gui/LICENSE-GPL`. The independent Rust bridge is Apache-2.0; see `LICENSE-APACHE`. Upstream notices remain in `NOTICE`.

## Build and run

Requires Xcode, the workspace Rust toolchain, and `protoc` (or `PROTOC` pointing at one). From the repository root:

The player, center and optimized release builds explicitly target Apple Silicon
macOS 13, using `LSMinimumSystemVersion` from the production plist as the compiler
deployment target. Each build checks the resulting Mach-O `minos` against the
bundle declaration; a newer host SDK must not silently raise the minimum.

```bash
apps/jidr-swiftui-prototype/build.sh
JIDR_HOME=/absolute/path/to/isolated-test-home \
  target/swiftui-prototype/JidrSwiftUIPrototype.app/Contents/MacOS/JidrSwiftUIPrototype \
  TEST_DEVICE 720 1280 "$PWD/target/debug/jidr-swiftui-bridge"
```

The daemon for that `JIDR_HOME` and the test device must already be running. Pass the device's actual unrotated panel width and height; the prototype does not discover them. The app and helper live under `target/` and do not overwrite the installed Jidr app.

## Scope and limitations

`test.sh` includes a real Mach-O deployment regression: a matching binary passes
and a binary requiring a newer macOS fails. Run
`bash apps/jidr-swiftui-prototype/test-player-lifecycle.sh` in a macOS GUI session
for the center/player integration regressions (mock center bridge, temporary
`JIDR_HOME`, no emulator). It checks button-triggered reconnection through the
actual center callback, unsaved-edit/recording reconnect guards, and device
stop/reboot during each recording phase. Interrupted recordings are marked as
unknown rather than saved, release the window's pending recording state, and
require checking the daemon's task before recording again.

Interactive mock previews are not connected to an emulator. Set
`JIDR_UI_PREVIEW=1` when presenting a mock center/player so both windows display
that limitation. The CenterUI fixture persists simulated deletions only in its
temporary `JIDR_HOME`; unsupported mutations return errors. The player fixture
explicitly rejects device commands, including recording, while local window
tools remain usable. `test-center-ui.sh` covers deletion read-back (including a
false success reply and deleting the last device), fixture persistence, and
unsupported operations. `test-player-lifecycle.sh` also opens the real window
against the Rust fixture, verifies first-frame delivery, local mapping setup,
device-command feedback and recording rejection without a stuck pending state.

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
session; `--update` rewrites the baselines and `--only CASE` limits a run). Every case fixes the
window rect, language/locale, appearance and animation duration (0), and `--check` compares
decoded pixels exactly (no tolerance). The renderer registers the bundled OFL Geist/Geist Mono
faces from `apps/jidr-gui/assets/fonts` with CoreText at startup (falling back to the built
preview bundles, then to the system font with a printed notice), and `snapshot.sh` stages the
`en`/`zh-Hans` string tables and the generated device art next to the executable so
`Bundle.main` resolves them like the packaged preview. Fixture mode is opt-in per process: set
`JIDR_CENTER_FIXTURE` to `empty`, `populated`, `load-failure`, `long-task` or `disconnect` for
the center bridge, or set `JIDR_PLAYER_FIXTURE=1` for the player bridge; when unset, both
bridges use their normal daemon/gRPC paths. These baselines cover the frozen M3 visual and are
the screenshot gate: CI runs `--check` (currently as a reported step) and a failure means the
rendering changed. `center-long-task` drives the center's in-flight `job.progress` state; the
booting player window is not a case. The player chrome is intentionally dark-only and
icon-only in the running state, so `player-running-en` is currently pixel-identical to
`player-running`; it stays in the matrix to catch localized player text regressions. Refresh
the baselines with `--update` after a deliberate visual change and update this table.

| case | language | appearance | size | bytes | sha256 |
|---|---|---|---|---|---|
| `center-empty` | zh | dark | 1000×640 | 70924 | `25b2fca60828ce0e2bb1f22dbf1fb6022cf794d2b881ba7d998ed6b8a368275a` |
| `center-populated` | zh | dark | 1000×640 | 125179 | `1dd417f66bbe12626f6c2a7d9365f1762cf84e87df1abc4c102f26e646da657e` |
| `center-load-failure` | zh | dark | 1000×640 | 60603 | `4786feb842ba8906292117e3d36b36e779462ae6d23f53d668bce73f701352d1` |
| `center-long-task` | zh | dark | 1000×640 | 117593 | `c08faa0db4835a40988f985870fd3dc1292d995076bfde18834cf472e531a189` |
| `player-running` | zh | dark | 432×768 | 27852 | `00a892f29d6452bb0b4d7e98280000531e070046984e1d284bb46b34b9b6476c` |
| `center-empty-en` | en | dark | 1000×640 | 77740 | `c6e983771a520c3e08aa0b2debee99e8d65ee779aae30a233e7a045ded65ef8f` |
| `center-populated-en` | en | dark | 1000×640 | 132375 | `d0190bff3dfa972797fc47fc1d818114238518f982601783bf285e038d44eb5a` |
| `center-long-task-en` | en | dark | 1000×640 | 123363 | `c9ca51949333c692bdda525664b57a4bd8e04f7555e071e1cfe3e2faca2ba569` |
| `player-running-en` | en | dark | 432×768 | 27852 | `00a892f29d6452bb0b4d7e98280000531e070046984e1d284bb46b34b9b6476c` |
| `center-populated-light` | zh | light | 1000×640 | 112704 | `fa68aa7289f72adf02245a7f728bfedce3610072f8cb04523dd397806e9e53eb` |
| `center-load-failure-light` | zh | light | 1000×640 | 56065 | `60006896b7d69bb415b4928f29d0108f629b171451dfa89a4558317d3b75cfb6` |

## Device-center development preview

Build with `apps/jidr-swiftui-prototype/build-center.sh`. This builds a separate app in `target/swiftui-center`, and does not replace the installed application. The center requires an explicit isolated `JIDR_HOME` and the paths of the center bridge, standalone player executable and player bridge as arguments. If a daemon is not running for that home, set `JIDR_DAEMON_BIN` to the intended test daemon executable.

For local development, `JIDR_HOME=/absolute/path/to/isolated-test-home bash apps/jidr-swiftui-prototype/run-center.sh` starts the preview directly from the current session, preserving its environment. Set `ANDROID_HOME` when the test images live in a separate SDK. This launcher does not grant macOS access to an external volume; the user session must already be able to access it.

The center is incomplete: it does not yet reproduce every existing settings and advanced-device workflow, its language coverage is partial, and production packaging and a full isolated acceptance run are outstanding. Storage settings can select a prospective destination and run a read-only space/format preflight. This check does not copy, validate recovery, switch locations, or authorize a migration. Storage migration remains unavailable. SDK installation asks the user to review and accept each displayed licence before recording consent; do not automate that confirmation. The preview must not be shipped as the production app until feature parity, safe shutdown and game-data/snapshot recovery have been verified.

The SDK bridge can be exercised with a synthetic local repository and synthetic licence using `JIDR_TEST_DAEMON_BIN=/path/to/jidr JIDR_TEST_CENTER_BRIDGE=/path/to/jidr-center-bridge python3 apps/jidr-swiftui-prototype/Tests/SDK/integration.py`. The test creates its own temporary home and synthetic archives, verifies that installation is refused before synthetic consent, and checks both tool and image installation. It does not accept a Google licence or install a Google package.

SDK installation can continue after its panel is closed, and can be cancelled once a job ID is available. `Tests/SDK/cancel_integration.py` tests cancellation against a throttled synthetic repository and checks that an unrelated file is preserved; it never accepts a Google licence.

## Isolated migration recovery check

The SDK integration test `migration_restores_guest_data_and_snapshot` creates its own temporary AVD, writes a test marker, creates a snapshot, performs a verified offline copy and checks that the copied snapshot restores the marker while the source remains present. This proves that test scenario only; it is not evidence that a particular game's data or all existing snapshots can be restored. The SwiftUI preflight and tests never activate a storage location.

## UI layout and regression checks

The center uses a native customizable macOS toolbar and a resizable master/detail split down to an 800×550 content area. All six quick actions remain on screen and wrap into additional rows; device settings, restart and delete are exposed directly in the inspector. Settings uses native preference-toolbar categories in one nonmodal window, retaining its selected pane for the current session; independent tool windows follow the same appearance preference. Background tasks and command search use reusable lightweight native panels with identical frame and shadow styling, without traffic lights or a modal backdrop. Clicking outside or pressing Esc dismisses the active panel without cancelling jobs. SDK setup inside device creation and snapshot saving use an inline step rather than another sheet.

Run `bash apps/jidr-swiftui-prototype/test-center-ui.sh` in a macOS GUI session for actual hosted-window regressions: command-palette first responder/input/Escape, native toolbar attachment, settings reuse and pane retention, transient task-panel reuse/outside dismissal, standard menu responder routing, native list deselection/stale-response rejection, unified title-bar appearance, full-label action wrapping, live auxiliary-window appearance changes, rendered Light preview under a Dark parent, and minimum-size split layout. Its bridge and preferences are isolated in a temporary directory. `test.sh` additionally checks helper-text contrast against actual sRGB token values. `snapshot.sh` includes English minimum-size/recording cases and light/dark settings, SDK setup, empty/active tasks and command-search cases; these capture content, while the window test and interactive review cover native chrome.

Interactive regression steps: close Settings and immediately type in ⌘K; confirm the background search stays unchanged. At minimum width, check full action labels and drag the divider. In Snapshots, open Save and press Esc: the list must remain open. In New Device, enter a name, open SDK setup and cancel: the creation form and its inputs must remain. Check both Light/Dark previews while switching appearance and confirm an already-open Advanced Tools window updates. These checks do not establish full VoiceOver, increased-contrast, older-macOS or real-game acceptance.
