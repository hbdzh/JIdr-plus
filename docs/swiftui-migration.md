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
| Entry | Device center is production; the separate standalone player app is a development/test entry, not shipped |
| Window model | Standalone device windows per device; no in-window device tab (2026-11-11) |
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

### Audits completed (evidence)

- **Parity**: all 68 golden scenes mapped against the code in
  [docs/swiftui-parity-scenes.md](swiftui-parity-scenes.md) (behaviour level: 7 entry, 49
  partial, 12 missing), with the module matrix in [docs/swiftui-parity.md](swiftui-parity.md).
  Structural gaps: no daemon reconnect, no task list/cancel, no device tab in the workbench,
  coarse Root state, no global shortcuts, no RTL.
- **Localization**: [docs/swiftui-localization.md](swiftui-localization.md) audits all three
  mechanisms (`.strings` 154 keys / `t()` 249 sites / 26 ternaries) and lists ~36 reachable
  Chinese strings in English mode, with the top 10 on main flows, plus the CI rules that would
  catch them.

### Open M0 items (not blocking M1)

- **Visual English walkthrough**: the code-level audit is done; the on-screen walkthrough
  (running app + daemon) is folded into the M1 screenshot harness rather than claimed as done.
- **ADR approval**: D2/D15/D20 amendments and the Slint freeze need the maintainer's approval;
  the licence wording change for D18 is deferred to M6.
## Approved decisions (2026-11-11)

- **Window model:** standalone device windows, no in-window device tab. The player window owns
  the booting/stopped/reconnect states that the Slint tab used to show.
- **RTL:** not required; Chinese and English only. The rtl golden variants are not a gate.
- **Localization:** keep the Chinese-key `.strings` + `t()` + ternary mechanisms, harden them
  with CI rules, move user-visible dynamic errors to English/code-based messages, and shrink the
  allowlist. An English-source catalogue is only reconsidered if a third language is added.

### First estimate after M0

Person-days, one owner plus up to two agents, excluding maintainer-only work (game sessions,
signing credentials). Ranges are deliberately coarse; M1 replaces them with the task facts.

| Stage | Work | Person-days |
|---|---|---:|
| M1 | Swift CI + localization gate; fixture mode; screenshot baselines; installable test `.app` + DMG; isolation | 7–11 |
| M2-A | device center and tasks: reconnect, task list/cancel, player window booting/stopped states, palette + shortcuts, toasts/status | 8–12 |
| M2-B | player and input: fullscreen reveal, overlay, uninstall, multi-touch mapping, shortcut editor, status displays | 8–12 |
| M2-C | root/snapshots/tools: 5-step timeline, stop+revert, Play Store wait, snapshot dialogs, map click, runtime camera | 8–12 |
| M3 | native integration, tokens/icons, multi-window/compact/Retina, EN/ZH walkthrough, config compatibility (no RTL) | 11–15 |
| M4 | isolated acceptance scripts + runs; performance A/B and long-run checks (maintainer joins for games) | 6–10 |
| M5 | release chain: packaging, signing/notarization, Gatekeeper, install/upgrade/rollback | 4–6 |
| M6 | switch, docs, Slint fallback, deferred decisions | 2–4 |
| **Total** | | **53–80 person-days** |

With one owner plus two agents and the M1 gate as the first checkpoint this is roughly
**6–9 calendar weeks**, low-to-medium confidence; the M2 split and review overhead dominate.
The three decisions above remove the RTL work and the device-tab work from the estimates.

## M1: test and package skeleton (status 2026-11-11)

| Item | Evidence |
|---|---|
| macOS Swift CI job | `.github/workflows/ci.yml` `swift-macos`: rustup, protoc, cached Rust, builds both previews, runs `test.sh` and the localization gate; the GUI window test is a separate `continue-on-error` step (reported, never silently skipped) |
| Localization gate | `Tests/localization_coverage.py` (8 rules, mechanisms a/b/c, UI and AppKit sinks, both bridge diagnostics, self-test) plus `Tests/i18n_allowlist.txt` (47 audited baseline rows); fails only on new leaks; `.strings` hygiene is warnings; `test.sh` runs `--self-test` |
| Fixtures and screenshots | `JIDR_CENTER_FIXTURE` (empty/populated/load-failure/long-task/disconnect) and `JIDR_PLAYER_FIXTURE` drive the UI without a daemon; `snapshot.sh --update/--check/--only` renders offscreen with exact pixel comparison; the five baselines now match the M2 visuals (`--check` 5/5 PASS on this machine) |
| Installable test package | `package-test.sh` → `target/swiftui-package/JidrSwiftUICenter.app` + `Jidr-0.3.1-test.dmg`; re-verified after M2 (signature, structure, forbidden-content scan, Finder-style launch, real data untouched) |
| Isolation | the packaging run and the CI-local tests never write `~/Library/Application Support/Jidr`; the test home is removed afterwards |

CI runs the snapshot check as a **reported** step: font/control metrics and the backing scale
differ between macOS runner images, so it does not gate until the runner image is pinned. The
GUI window lifecycle step is reported for the same reason.

## M2: behaviour parity (status 2026-11-11)

Three work lines ran in parallel with disjoint write scopes and merged as three commits
(`dff2601` player, `ec8c063` centre/tasks/palette, `ba69547` root/snapshots/tools):

| Line | Delivered |
|---|---|
| Player | own link-state card (connecting/booting/running/stopped/disconnected) with start and reconnect, ⌥⌘I overlay, ⌃⌘F fullscreen with hover reveal and pixel chip, ⌥ pinch / ⇧⌥ pan, uninstall sheet with the signature-conflict reinstall chain, per-device shortcut editor mirroring the Slint schema, recording clock, logcat bar |
| Centre and tasks | daemon/bridge reconnect with bounded backoff and heartbeat, task list with cancel and a visible quit-blocking reason, ⌘K palette, global shortcuts that do not steal text-editor keys, toasts, session/Magisk/busy details, APK signature-conflict reinstall |
| Root, snapshots, tools | five-step root timeline, recent steps/log tail, stop-and-revert, Play Store guided grant countdown and unverified branch, snapshot save/restore/delete dialogs with refusal reasons, map click-to-set GPS, next-boot camera switching, root dev-tools page |

Verification on this machine: `build-center.sh` and `build.sh` green; `test.sh` runs 14 logic
groups plus the localization gate (0 new leaks); reconnect exercised with a real daemon killed
and restarted; the root state machine driven end to end against a fake bridge; 18 off-screen
renders in `target/m2c-renders` reviewed. Commits stay local; no push.

What M2 did **not** do: any real-emulator/real-game verification (that is M3/M4), the device
form's five-page layout (only `edit-device-data` remains from the parity gaps), the menu bar and
Dock integration, the design-token mapping, and the visual English walkthrough (all M3).

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

Shared tasks are on the team board. M0 (parity, localization), M1 (CI, package, fixtures,
baselines), M2-A/B/C (centre, player, root) and the player bridge increment are complete.
Remaining: M2 visual baseline refresh (`M2 视觉冻结`), then M3 native/visual/localization.
Write scopes are disjoint; the Lead commits and runs the gates.
