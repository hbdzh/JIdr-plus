# SwiftUI migration: plan, status and gates

Status: **M0 in progress** (2026-11-11). Baseline: `master` @ `b46a2f3`, then two M0 fixes
(`5a4d8eb`, `69b890a`). The plan was approved in outline; the ADR proposal is in
[docs/decisions/0003-swiftui-gui.md](decisions/0003-swiftui-gui.md). Progress is tracked as
evidence per item, never as a single percentage.

The parity matrix lives in [docs/swiftui-parity.md](swiftui-parity.md): implementation and
verification are separate columns, and every row names its evidence.

## Scope (as approved)

| Area | Decision for this migration |
|---|---|
| Platform | Apple Silicon macOS; minimum version fixed in M1 (13.0 unless SwiftUI needs more) |
| Tech | SwiftUI + AppKit where needed, over the existing Rust bridges; daemon still owns state |
| Function | Match the Slint user capabilities, state feedback and failure handling; new features are separate |
| Entry | Device center is production; the standalone player is a development/test entry, not shipped |
| Map | MapKit container + OSM/`tile_url` tiles, D14 satisfied; map-click interaction still to add |
| Licence | Swift GUI stays GPL-3.0-only, bridge Apache-2.0; no relicensing |
| Visual | D41 Workbench tokens and Lucide icons; native-control exceptions recorded in M3 |
| Slint | Freeze features, fix blocking bugs, keep a buildable fallback until M6 |
| Data migration | Separate project; only the current choose/preflight/clear-copy behaviour stays |
| Commits | One conventional commit per logical task on `master`, no push, no release |

## M0: baseline, tooling, first evidence

Done and reproducible on this machine:

| Check | Command | Result |
|---|---|---|
| Rust gate | `PATH=target/tools/bin:$PATH PROTOC=target/tools/protoc/bin/protoc cargo xtask ci` | **green**: 597 passed, 1 skipped; licence-check ok (16 crates); skills-check ok (4 skills) |
| Swift logic tests | `bash apps/jidr-swiftui-prototype/test.sh` | 10/10 pass (decoder, mapping, quality, window state, creation, SDK plan, MCP, app list, log filter, i18n coverage) |
| Player preview | `bash apps/jidr-swiftui-prototype/build.sh` | builds `target/swiftui-prototype/JidrSwiftUIPrototype.app` |
| Center preview | `bash apps/jidr-swiftui-prototype/build-center.sh` | builds `target/swiftui-center/JidrSwiftUICenter.app` |
| Window lifecycle | `bash apps/jidr-swiftui-prototype/test-window.sh` | passed (GUI session available) |

Two fixes made the baseline honest (they were red before this migration started):

- `5a4d8eb` — the bridge failed `clippy -D warnings` in two places (`chunks_exact_to_as_chunks`,
  `items_after_test_module`). Fixed, not suppressed.
- `69b890a` — `protocol_doc_matches_commands_list` was red because `device.edit` field
  descriptions had drifted from the generated reference; the code comments now carry the
  full descriptions and `docs/control-protocol.md` was regenerated.

### Toolchain in use (installed under `target/tools/`, not committed)

| Tool | Version | Notes |
|---|---|---|
| rustc / cargo | 1.99.0 | pinned by `rust-toolchain.toml` |
| protoc | 36.2 | needed by `jidr-proto`'s build script; CI installs it via `setup-protoc` |
| cargo-nextest | 0.9.151 | the gate runner; CI installs it |
| Xcode | 27.2 (build 27B52) | `swiftc` from the active command-line tools |
| macOS | 27.0.1 | dev machine |

Reproducibility caveat for M1: `crates/jidr-proto/build.rs` prefers the protos shipped with
the installed SDK emulator and falls back to the vendored 35.6.11 copies. Two machines can
therefore compile different gRPC bindings. M1 fixes the policy (pin `JIDR_PROTO_VENDORED=1`
for CI and acceptance, or declare the minimum emulator version) and records it.

### Open M0 items

- **English-mode walkthrough**: code-level audit delegated; the visual walkthrough of the
  English main flow still needs the running app with a daemon, and its findings go into the
  parity rows.
- **Parity matrix**: first draft in [docs/swiftui-parity.md](swiftui-parity.md); scene mapping
  is being verified against the code.
- **ADR approval**: D2/D15/D20 amendments and the Slint freeze need the maintainer's approval;
  the licence wording change for D18 is deferred to M6.

## M1–M6 gates (summary)

- **M1 — test and package skeleton.** macOS CI job for Swift builds, logic tests and the
  localization check; a fixture mode for the UI; rendered screenshot baselines; an installable
  ad-hoc-signed `.app` + DMG with helpers, localizations, icon and licences; isolated
  `JIDR_HOME` for every test run. Gate: documented commands rebuild and test from a clean
  checkout; the test package launches from Finder; no Google SDK/image/Magisk inside.
- **M2 — behaviour parity, three parallel work lines.** A: device center and tasks. B: player
  and input. C: root, snapshots and advanced tools. Every task ships implementation, tests
  where they pay for themselves, and updated parity evidence. Gate: every scene row is
  implemented or explicitly not ported with a reason.
- **M3 — native integration, visual and localization.** Menu bar, Dock, activation/quit,
  multi-window and compact layouts, Retina and display restore, tokens/icons, focus and basic
  accessibility, EN/ZH walkthrough, light/dark/system, extended localization checks, old
  config compatibility.
- **M4 — isolated acceptance and performance.** Full flow on disposable devices with an
  isolated `JIDR_HOME`: SDK setup → create → root → install/launch → input → screenshot and
  recording → snapshot save/restore → safe stop. Plus multi-device, disconnects, bridge/daemon
  exits, data/config round-trip, and measurements against ADR-0001 and the Slint baseline
  (`docs/display-performance.md`). Google licences are accepted by the user, never by tests.
- **M5 — release chain.** Swift in the release/release-check path: version, bundle id, helper
  lookup, resources, licences, DMG, signature order, hardened runtime, notarization,
  Gatekeeper, install/upgrade/uninstall/rollback, CLI/daemon/MCP regression.
- **M6 — switch and keep the fallback.** Default GUI switches to SwiftUI; docs, architecture,
  licences and skills updated; Slint stays buildable; deleting Slint is a later separate
  decision.

## Pause conditions

Pause the switch (Slint stays production) if: data safety or rollback compatibility cannot be
confirmed; performance keeps missing the agreed thresholds; key root/snapshot/game flows lack
repeatable evidence; the package still depends on the dev machine or its signing state is
unclear; a key architecture decision is unapproved; or the repository has uncoordinated
concurrent edits.

## Task tracking

Shared tasks are on the team board: `M0 parity 初稿`, `M0 本地化走查`, followed by the M1
tasks. Write scopes are disjoint; the Lead commits and runs the gates.
