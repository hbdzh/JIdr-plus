# ADR-0003: SwiftUI/AppKit as the sole GUI

- **Status:** Accepted and implemented. The maintainer explicitly approved removal of
  the Slint fallback and obsolete prototype application on 2026-11-11.
- **Date:** 2026-11-11
- **Related:** D2 (Slint), D15 (Apple Silicon only, code stays portable), D18 (split licensing),
  D20 (Slint spike), D41 (design tokens), ADR-0001 (frame transport). Current build and
  verification commands are in the [SwiftUI guide](../../apps/miko-swiftui/README.md).

## Context

The MVP GUI is Slint (`crates/miko-ui`, `apps/miko-gui`, GPL-3.0-only because it links Slint).
This fork targets Chinese-first, player-oriented macOS use, where native input methods,
clipboard, drag-and-drop, multi-display behaviour and window management matter more than a
portable toolkit. A SwiftUI/AppKit prototype already covers the device center, the game
window and most settings and advanced tools, and the migration does not touch the daemon,
the protocol or the CLI: both GUIs are thin clients over the same JSON-RPC control protocol.

## Decision (approved 2026-11-11)

1. **SwiftUI/AppKit is the only GUI.** The retired `crates/miko-ui` and `apps/miko-gui`
   sources, golden images, Cargo dependencies and release selection have been removed.
   The native app is `apps/miko-swiftui`; shared assets were moved before deletion.
2. **Entry point:** one device-center application owns all player windows. The old
   standalone prototype app and duplicate packaging implementation are removed. Tests
   and the native performance harness remain separate verification executables.
3. **Tech path:** SwiftUI with AppKit where SwiftUI lacks the behaviour, over the existing
   Rust bridges. Device state stays in the daemon; the GUI holds only view state.
4. **Platform:** Apple Silicon macOS. The minimum system version is 13.0 unless SwiftUI
   requires a higher version; the app bundle and deployment-target checks enforce it.
5. **Map:** keep the MapKit container with OpenStreetMap/`tile_url` overlays and attribution,
   as today, and add the missing map-click interaction. D14 stays satisfied.
6. **Licensing:** keep the Swift GUI GPL-3.0-only and the Rust bridge Apache-2.0. No
   relicensing now. D18 and `cargo xtask license-check` enforce the license boundary.
7. **Visual language:** D41 stays the source: Workbench tokens and Lucide icons are generated
   or mapped for SwiftUI. Native controls are used where appropriate.
8. **Legacy removal:** Slint is no longer built, shipped or maintained in this tree.
   Earlier revisions remain available in Git for historical comparisons and rollback.
9. **Data location and migration:** a separate project. This migration keeps today's behaviour
   (choose a destination, read-only preflight, clear "not migrated" copy).

## Approved on 2026-11-11

1. **Window model:** keep standalone device windows; there is no in-window device tab. The
   Slint tab form is deliberately not ported. The player window owns the booting, stopped and
   reconnect states, so `player-booting`/`player-stopped` are shown there rather than in a tab.
2. **RTL:** not required. The app ships Chinese and English only; use semantic leading/trailing
   where it is free, but the RTL golden variants are not a gate. Revisit only if Arabic ships.
3. **Localization direction:** keep the current Chinese-key `.strings` tables, the `t()` helper
   and the inline ternaries for this migration. Enforce localization coverage in CI,
   move user-visible dynamic errors (bridge diagnostics,
   `NSError`/`LocalizedError`) to English or code-based messages, and shrink the allowlist as
   known leaks are fixed. Only consider an English-source catalogue if a third language is
   added.

Amendments this proposal implies: D2 (Slint was the MVP UI; for miko 模拟器 the production UI
is SwiftUI), D15 (portability stays at the daemon/protocol/CLI; the GUI is macOS-only),
D20 (the Slint spike is closed), D18 (wording and enforcement when Slint leaves the build).
D41 is not amended; the tokens remain the single design source.

## Validation and consequences

The daemon, protocol and user data layout are unchanged. SwiftUI is now the only UI
build path; release-toolkit selection is rejected. CI builds the native app and
checks logic, localization, deployment, window/connection regressions and rendered
screenshots. Packaging uses the production bundle for isolated rehearsals.

Removal does not establish new game compatibility or notarization evidence. Outstanding
real-device acceptance and Developer ID/notarization gaps must continue to be reported honestly. Rollback
requires an earlier Git revision or installer rather than a second UI in this tree.
