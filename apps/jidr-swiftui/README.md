# Native macOS UI

SwiftUI/AppKit is the only desktop UI. `Center/main.swift` owns the device center,
settings/tool windows and integrated player windows. The Rust bridges in `bridge/`
connect to the real daemon and emulator; device state stays in the daemon.

The Swift source is GPL-3.0-only (`LICENSE-GPL`); Rust bridges are Apache-2.0.
Fonts in `Resources/fonts` retain their OFL notices. Shared Lucide SVGs and ISC
license text live in `assets/lucide`; native UI icons use SF Symbols.

## Build and run

Requires macOS, Xcode, the pinned Rust toolchain and protoc:

```bash
bash apps/jidr-swiftui/build-center.sh
open target/swiftui-center/JidrSwiftUICenter.app
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
cover 24 fixed language/appearance/layout scenarios; intentional visual changes
use `snapshot.sh --update`. Fixture flags are test-only, never normal launch
settings. Interactive mock sessions must set `JIDR_UI_PREVIEW=1` to display their
limitations, and must reject unsupported device commands rather than claim success.

The native performance harness (`Tests/Bench`) remains available for real-device
measurements. See `bench-player.sh --help`, `render-live.sh`, ADR-0001 and
`docs/display-performance.md`. Historical migration results are in
`docs/swiftui-migration.md`; those results are not new acceptance evidence.
