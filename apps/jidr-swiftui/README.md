# Native macOS UI — 0.4.0

SwiftUI/AppKit is the only desktop UI. `Center/main.swift` owns the device center,
settings/tool windows and integrated player windows. The Rust bridges in `bridge/`
connect to the real daemon and emulator; device state stays in the daemon.

An empty device library shows one creation guide, with SDK setup as a secondary
action. Device search, the overview, app list and device-only actions appear
when devices exist. Background tasks and settings remain accessible in either state.

For a stopped device, the overview shows a short app hint instead of an empty
app browser; capture/install/send controls appear when the device is running.
Device settings stage quality alongside hardware and audio until Save; Cancel
writes nothing. A daemon failure leaves quality unchanged, and a local quality
write failure reports whether device settings have already been saved.
Advanced tools expose calls/SMS, clipboard, fingerprint, cameras and developer
options in a native sidebar, with Device-settings-style detail forms. SDK images are grouped by API, with common
variants before specialized images and explicit 16 KB page-size labels.

The overview groups each action with its content: APK selection and drop-install
share the apps card, full app management stays available even with fewer than
seven apps, and snapshot creation/management share the snapshot card. The header
exposes device settings/tools and a compact screenshot/record/send row; More only
contains restart, delete and an in-progress Root setup entry. Root verification
lives in Root tools. Camera sources are edited only in Device tools; the device
settings sheet links there without discarding its other pending edits.

Root tools expose the existing `root.writable_system` command: enable writes on
Shell Root devices with API 31+ and an adb-root-capable image, or restore the
stock read-only system. A confirmation explains the cold boot and overlay removal.
Stopped devices apply the change on their next start. The displayed flag is the
daemon's configured write-access setting, not a live filesystem probe.

The Microphone page plays a local WAV into Android's microphone with optional
looping. It uses `audio.inject` and daemon jobs, not the Mac's live microphone.
Playback continues when the tools close; the center keeps the session so Stop
remains available when reopened. Stop cancels the owning job (including while
the file is loading); CLI/MCP injections can also be stopped from the page.
The Android app must open its microphone to consume the injected audio.

The Swift source is GPL-3.0-only (`LICENSE-GPL`); Rust bridges are Apache-2.0.
Fonts in `Resources/fonts` retain their OFL notices. Shared Lucide SVGs and ISC
license text live in `assets/lucide`; native UI icons use SF Symbols.

## Operation recordings

The player side rail has an "Operation recordings" window: record the normalised
touch/key/text timeline of a session, replay it with count/duration/infinite
loops, intervals and 0.25x–4x speed, and manage the saved scripts (rename,
delete, import/export JSON). Scripts live under `<data>/scripts/` and are plain
versioned JSON; the player bridge records and replays them locally. Rotation,
screen recording and file operations are not part of v1. CLI/MCP playback is a
later phase. The bridge command/notification contract and the script format are
documented in [`docs/player-scripts.md`](../../docs/player-scripts.md).

## Build and run

Requires macOS, Xcode, the pinned Rust toolchain and protoc:

```bash
bash apps/jidr-swiftui/build-center.sh
open target/swiftui-center/Jidr.app
```

The development bundle contains the real CLI, daemon and bridges. A plain launch
uses the standard Jidr data directory. It does not install SDK components, accept
licenses or start a device automatically. To test against separate data, explicitly
set an absolute `JIDR_HOME` and use `run-center.sh`. No standalone prototype app is
needed: devices open in player windows owned by the center.

```bash
JIDR_HOME=/absolute/path/to/disposable-test-home bash apps/jidr-swiftui/run-center.sh
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

Release builds use macOS 13 as the deployment target and check the Mach-O minimum
against the production plist. Release/rehearsal artifacts stay under `target/`.
Developer ID signing/notarization and complete game compatibility still require
separate validation; an ad-hoc build does not establish either.

## Verification

```bash
bash apps/jidr-swiftui/test.sh
bash apps/jidr-swiftui/test-center-ui.sh --interactive # visible windows; dedicated test session
bash apps/jidr-swiftui/test-player-lifecycle.sh
bash apps/jidr-swiftui/test-window.sh
bash apps/jidr-swiftui/generate-tokens.sh --check
bash apps/jidr-swiftui/snapshot.sh --check --only tools-battery-light
bash apps/jidr-swiftui/bench-player.sh --self-test
```

Screenshot tests render into hidden, unordered hosting windows and never activate
the test application. They still need access to a logged-in WindowServer session.
For local changes, select only the relevant cases with repeatable `--only CASE`;
`--list` lists names without opening windows. The complete screenshot matrix requires
explicit `--all` and belongs in CI or a broader regression, rather than every
local style adjustment. Intentional visual changes use `--update` with the same
case scope. `test-center-ui.sh --interactive` tests actual focus and responder
handoffs: it opens visible windows and must run in a dedicated session or after
arranging foreground access with the user; without the flag it refuses to run.
Tests use temporary homes and fixture bridges and never change real devices or
SDKs. Fixture flags are test-only, never normal launch
settings. Interactive mock sessions must set `JIDR_UI_PREVIEW=1` to display their
limitations, and must reject unsupported device commands rather than claim success.

Offscreen bitmap caching does not composite all native sidebar vibrancy and
transparent window materials. Their baselines check structure and content;
selection colors, shadows and material blending also need inspection in the real app.

The native performance harness (`Tests/Bench`) remains available for real-device
measurements. See `bench-player.sh --help`, `render-live.sh`, ADR-0001 and
`docs/display-performance.md`. Historical migration results are in
`docs/swiftui-migration.md`; those results are not new acceptance evidence.

`bench-player.sh` now defaults to optimized Release builds and the actual
`GameWindowController`/`PlayerTransport`/`ScreenView` path. Optional observation
callbacks are nil in normal app launches. Reports distinguish decode, UI handoff,
unique image draws, input-to-draw latency (excluding OS delivery and GPU scanout),
main-queue lag and per-process physical/peak footprint. The 7×7 probe uses the
existing decoded bytes and travels with its matching image; no image-sized copy
is added for measurement. Native minimize/restore probes require a newly decoded
frame, so repainting a pre-minimize image cannot count as recovery.

To capture three repeatable runs with fixed 1080×2400/4-core/4-GiB settings on a
throwaway real device and an already installed, read-only SDK:

```bash
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk
```

The runner builds before booting, preserves revision and binary/input hashes,
rejects dirty-source measurements and missed touch probes, records unresolved
manual/Space/fullscreen acceptance, and stops/deletes only its own device/home.
No SDK download, license acceptance or normal Jidr data is involved. Use the same
measurement revision, screen refresh rate, window size and scene for later A/B;
`JIDR_BENCH_PROFILE=debug` exists for explicit build-mode comparisons only.

The player bridge shares an immutable RGBA buffer with its output writer, and
reserves the single waiting-frame slot before rotation or packet preparation.
JFR1 bytes, quality, orientation rules and the drop-new-on-full policy are
unchanged. One writer emits the header and payload with complete-write handling;
their owner stays alive until the write finishes. `JIDR_PLAYER_FRAME_TRANSPORT=legacy`
selects the copied-packet fallback when launching the app/bridge for rollback or
comparison; the default is `shared`. This is independent of input scheduling.

For a same-binary comparison, run the offline cleanup/ordering checks, then three
pairs on one disposable real device (legacy/shared, shared/legacy, legacy/shared):

```bash
python3 scripts/test-player-baseline.py
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk --compare-frames
```

Reports include the transport selector and executable hashes. Compare total
displayed FPS, unfiltered frame-interval tails, touch/restore probes and physical
footprint, including failed runs; copying less data does not alone prove a user
experience improvement. Rotation/channel/short-write/lifetime tests live in the
Rust bridge's `frame_transport` module.

For this change, the pre-measurement acceptance limits are: all touch and fresh
restore probes detected, identical stream dimensions/quality, median displayed
FPS no more than 5% lower, median per-run touch p95 no more than
`max(5 ms, 20%)` higher, and maximum restore no more than 50 ms higher. A breach
requires investigation or a longer repeated comparison; these short runs cannot
certify games or long-duration behavior. Memory is reported per process; an
improvement claim needs at least one RGBA frame of median bridge peak-footprint
reduction or a repeatable bridge CPU reduction, rather than adding unrelated
process footprints together.

Input runs on one bounded FIFO consumer (`JIDR_PLAYER_INPUT_SCHEDULER=fifo`,
the default). Frame reception continues while it awaits key/touch/clipboard or
toolbar RPCs. FIFO uses its own actual gRPC connection for input/clipboard;
cloning a Controller would still share screenshot-stream HTTP/2 flow control.
The inline fallback keeps the shared connection. Repeats, downs/ups, gestures and clipboard chords are never
coalesced or dispatched as separate event tasks. The existing media/app job
tasks keep their previous behavior. `JIDR_PLAYER_INPUT_SCHEDULER=inline` retains
the coupled scheduling branch for rollback and same-binary measurements.

Input state has a single owner. Potential downs are recorded before the RPC;
acknowledged ups remove them. EOF drains queued commands, then releases held
inputs. Frame/output loss, SIGTERM and Ctrl-C cancel in-flight input and attempt
releases in reverse press order, including temporary clipboard-chord keys.
Each release has a one-second bound. Failure recovery also retains ownership
until an up attempt finishes, so shutdown can retry an interrupted recovery.

```bash
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk \
  --compare-input --seconds 20 --taps 60
```

This comparison keeps shared frames fixed and alternates inline/FIFO order.
Reports include input-phase received/drawn FPS and interval/main-queue timelines,
in addition to touch latency. Touch misses in otherwise completed input runs are
retained while the remaining pairs are collected; process/render failures can
abort collection. Any failed probe leaves `manifest.complete=false` and a nonzero
exit status. `collection_complete` only says that every planned run was captured.
Acceptance requires all FIFO probes, order/cancellation regressions and fresh
restores to pass; the same 5% FPS, `max(5 ms, 20%)` touch-p95 and 50 ms restore
limits apply. Target input-phase receive-interval p95 is under 50 ms and at least
50% below inline; per-process peak bridge footprint should stay within one RGBA
frame plus 1 MiB of inline, player within 10%. Report hardware IME, games and
physical multitouch separately from offline protocol-order tests.

Add `--input-smoke --build-sdk /path/to/installed/build-sdk` to build and run the
Android input fixture before the timed A/B pairs. It uses an existing `JAVA_HOME`,
Android 36 platform and SDK build-tools (read-only), an ephemeral debug signing
key, and only the runner's disposable device. The actual production bridge sends
modifier/letter events, Unicode paste, copy/cut, two-finger gestures and a final
SIGTERM while inputs are held. Assertions read the Android app's own private
event/text trace through `adb run-as`; no fake bridge or simulated device is
used. This checks protocol-to-Android behavior and release on a real process
signal; hardware IME composition and games remain separate acceptance.

The home-screen input series can contain intervals without changing content;
its low input-phase FPS alone cannot identify an RPC-induced freeze. For a
controlled comparison add `--animated-input`. The fixture continuously moves a
bar away from the static touch-probe patch, disables its trace-file writes,
stays foreground with Volume Up instead of Home, and uses three Copy requests
in a fixture mode that consumes the Copy shortcut without updating the clipboard
(functional copy/cut smoke checks keep that mode disabled). The clipboard implementation awaits a fresh
event for up to 1.5 seconds. In each first one-second wait window, record actual
received/drawn frames. The controlled target is at least 45 drawn FPS in each
FIFO wait window and at least twice its paired inline window, while the existing
touch/restore/order/footprint limits still apply. The 50% interval-reduction
target above is exploratory for ordinary input; continuous drawing during the
explicit clipboard wait is the causal independence check.

```bash
python3 scripts/player-baseline.py --sdk /path/to/clean-test-sdk \
  --compare-input --seconds 20 --taps 60 --input-smoke --animated-input \
  --build-sdk /path/to/installed/build-sdk
```

UI state and interaction regressions also cover filtered selection, named deletion
with a captured target, details failures/timeouts with retry, the complete command
catalog, stopped-device Root/camera reads, and preference window sizing. Device
policies separate new-device Root defaults from global runtime policies, validate
numeric input, and indicate unsaved changes. Device tools are available directly;
Root configuration lives beside its status, while the Root section in Device
details remains read-only.
Route playback uses a generation token so replies from a stopped route cannot
change the state of a later route. These checks use isolated fixtures; running
games, real route playback, and live Root changes still require device acceptance.

Device tools uses the reviewed compact integrated layout in a lightweight panel
attached to the invoking center/player window. Its 168-point sidebar extends
through the full height, with a small tool/device header and device state below
the navigation. A native NSTableView retains keyboard and type-to-select behavior,
with standard 32-point rows and template SF Symbols. AppKit draws selection
using the system accent and active/inactive colors; no custom pale selection,
fixed icon palette or forced cell emphasis is applied. Group headings do not float.
The detail side has one full-width page scroll viewport containing its title,
description, stopped-device hint and bounded groups of native fields. Only the
content width is capped; its scrollbar stays at the far-right page edge. Groups
never introduce a separate form-area scroll viewport. Primary form actions sit
below the input group; Close stays fixed at the bottom right. Initial size is 716 × 500 with a 660 × 460
minimum. Tool selection never changes the window frame. Root entry selects Root
directly, and camera drafts survive switching tools.

Escape travels through the responder chain so input composition and child
sheets can consume it before the panel closes. Cmd+W closes the panel. Camera
selectors expose distinct front/back accessibility labels; only edited values
can be applied, and successful saves update the baseline. Automatic reads do
not show a mutation-success message. Background regressions verify sidebar width/density, full-height background,
system selection drawing and emphasis propagation, cross-group arrow-key navigation, field
alignment, full-width page scrolling, a stable panel frame and camera draft retention. Focus/responder checks remain
in the explicitly interactive suite.
