# ADR-0003: SwiftUI/AppKit as the production GUI (proposal)

- **Status:** Accepted (2026-11-11, M0) and **implemented (2026-11-11, M6)**: `cargo xtask
  release` now builds the SwiftUI centre by default (`--gui slint` keeps the Slint fallback),
  the production bundle defaults to the standard Jidr home, and D2/D15/D18 are recorded below.
- **Date:** 2026-11-11
- **Related:** D2 (Slint), D15 (Apple Silicon only, code stays portable), D18 (split licensing),
  D20 (Slint spike), D41 (design tokens), ADR-0001 (frame transport); the plan, parity
  checklist and gates are in [docs/swiftui-migration.md](../swiftui-migration.md).

## Context

The MVP GUI is Slint (`crates/jidr-ui`, `apps/jidr-gui`, GPL-3.0-only because it links Slint).
This fork targets Chinese-first, player-oriented macOS use, where native input methods,
clipboard, drag-and-drop, multi-display behaviour and window management matter more than a
portable toolkit. A SwiftUI/AppKit prototype already covers the device center, the game
window and most settings and advanced tools, and the migration does not touch the daemon,
the protocol or the CLI: both GUIs are thin clients over the same JSON-RPC control protocol.

## Decision (approved 2026-11-11)

1. **SwiftUI/AppKit replaces Slint as the production GUI on macOS.** `crates/jidr-ui` and
   `apps/jidr-gui` stay buildable and receive bug fixes until the M6 switch, then they are
   frozen; deleting them is a separate later decision.
2. **Entry points:** the device center is the production entry point. The standalone player
   stays a development and test entry point and is not shipped in the production app bundle.
3. **Tech path:** SwiftUI with AppKit where SwiftUI lacks the behaviour, over the existing
   Rust bridges. Device state stays in the daemon; the GUI holds only view state.
4. **Platform:** Apple Silicon macOS. The minimum system version follows the existing product
   requirement (13.0) unless M1 shows the SwiftUI code needs a higher one; it is fixed in the
   app bundle and a deployment-target build in M1.
5. **Map:** keep the MapKit container with OpenStreetMap/`tile_url` overlays and attribution,
   as today, and add the missing map-click interaction. D14 stays satisfied.
6. **Licensing:** keep the Swift GUI GPL-3.0-only and the Rust bridge Apache-2.0. No
   relicensing now. When Slint leaves the build, D18's wording and `cargo xtask
   license-check`'s GPL crate list are updated in the same change (M6).
7. **Visual language:** D41 stays the source: Workbench tokens and Lucide icons are generated
   or mapped for SwiftUI in M3. Where a native control is used instead, the choice is
   recorded in the M3 notes.
8. **Slint freeze:** from M1 to the M6 switch Slint receives blocking bug fixes only. Upstream
   Slint features are not ported during the migration.
9. **Data location and migration:** a separate project. This migration keeps today's behaviour
   (choose a destination, read-only preflight, clear "not migrated" copy).
10. **Commits and releases:** one conventional commit per logical task on `master`, no remote
    push, no release or installed-app replacement without the maintainer's explicit ask.

## Approved on 2026-11-11

1. **Window model:** keep standalone device windows; there is no in-window device tab. The
   Slint tab form is deliberately not ported. The player window owns the booting, stopped and
   reconnect states, so `player-booting`/`player-stopped` are shown there rather than in a tab.
2. **RTL:** not required. The app ships Chinese and English only; use semantic leading/trailing
   where it is free, but the RTL golden variants are not a gate. Revisit only if Arabic ships.
3. **Localization direction:** keep the current Chinese-key `.strings` tables, the `t()` helper
   and the inline ternaries for this migration. Harden them with the CI rules in
   `docs/swiftui-localization.md`, move user-visible dynamic errors (bridge diagnostics,
   `NSError`/`LocalizedError`) to English or code-based messages, and shrink the allowlist as
   M2 fixes the known leaks. Only consider an English-source catalogue if a third language is
   added.

Amendments this proposal implies: D2 (Slint was the MVP UI; for JIdr Plus the production UI
is SwiftUI), D15 (portability stays at the daemon/protocol/CLI; the GUI is macOS-only),
D20 (the Slint spike is closed), D18 (wording and enforcement when Slint leaves the build).
D41 is not amended; the tokens remain the single design source.

## Pause criteria

Work pauses and Slint stays production if data safety or rollback compatibility cannot be
confirmed, performance keeps missing the agreed thresholds, key root/snapshot/game flows lack
repeatable passing evidence, the package still depends on the development machine, or a key
architecture decision is not approved.

## Consequences

- The fork owns its GUI permanently; upstream Slint UI work is not inherited. This is the
  accepted price of the product direction.
- Tests, CI and the release chain are rebuilt for Swift (M1, M5). Until then the prototype
  cannot be shipped.
- `cargo xtask license-check` keeps enforcing that Apache crates never link Slint or the GPL
  GUI crates; the GPL crate list changes only when the Slint crates leave the build.
