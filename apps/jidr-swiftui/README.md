# Native macOS UI

SwiftUI/AppKit is the only desktop UI. `Center/main.swift` owns the device center,
settings/tool windows and integrated player windows. The Rust bridges in `bridge/`
connect to the real daemon and emulator; device state stays in the daemon.

An empty device library shows one creation guide, with SDK setup as a secondary
action. Device search, the inspector, app list and device-only actions appear
when devices exist. Background tasks and settings remain accessible in either state.

The Swift source is GPL-3.0-only (`LICENSE-GPL`); Rust bridges are Apache-2.0.
Fonts in `Resources/fonts` retain their OFL notices. Shared Lucide SVGs and ISC
license text live in `assets/lucide`; native UI icons use SF Symbols.

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
bash apps/jidr-swiftui/test-center-ui.sh
bash apps/jidr-swiftui/test-player-lifecycle.sh
bash apps/jidr-swiftui/test-window.sh
bash apps/jidr-swiftui/generate-tokens.sh --check
bash apps/jidr-swiftui/snapshot.sh --check
bash apps/jidr-swiftui/bench-player.sh --self-test
```

Window/screenshot tests need a logged-in GUI session. Tests use temporary homes
and fixture bridges and never change real devices or SDKs. Screenshot baselines
cover 26 fixed language/appearance/layout scenarios; intentional visual changes
use `snapshot.sh --update`. Fixture flags are test-only, never normal launch
settings. Interactive mock sessions must set `JIDR_UI_PREVIEW=1` to display their
limitations, and must reject unsupported device commands rather than claim success.

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
toolbar RPCs. Repeats, downs/ups, gestures and clipboard chords are never
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
in addition to touch latency. Probe failures are retained and all input pairs
are collected; any failed probe leaves `manifest.complete=false` and a nonzero
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
with an empty selection. The existing clipboard implementation awaits a fresh
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
