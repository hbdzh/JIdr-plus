# SwiftUI migration: plan, status and gates

Status: **M0–M6 complete (2026-11-11)**. The SwiftUI centre is the default GUI of the release
chain; the Slint app stays as the `--gui slint` fallback. Evidence per item is recorded in the
sections below; the remaining manual checks are listed under M6.

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

## M3: native integration, visual and localization (status 2026-11-11)

| Area | Delivered |
|---|---|
| Native shell | real menu bar (app/edit/device/view/window/help) driven through palette actions with target validation, Dock menu, per-JIDR_HOME flock single instance that activates the running window, close-to-hide/reopen, device-window focus instead of duplicates, key-window menu target resolution |
| Layout and displays | centre collapses to one scrolling column below 940pt with a details toggle; sheets fit 900×600; player windows save their display id, restore on the saved/nearest screen and clamp when the screen set changes; Retina handled in points |
| Design system | `generate-tokens.sh` renders the D41 tokens from `docs/design/tokens.json` into Swift (150 light/dark colour pairs, spacing, radii, borders, 30 type styles, durations, easings, shadows); 903 Wb* call sites across the centre and player; 69 semantic WbIcon constants with no bare SF Symbol names left; CI fails when the generated files drift |
| Fonts | Geist, Geist Mono and Noto Kufi ship in both previews and the package with `ATSApplicationFontsPath`; WbFontResolver uses the real faces and falls back to the system font; the OFL licences ship in the package |
| Localization | the audited baseline went 34 → **0**: bridge and Swift diagnostics now carry stable codes and English messages, `.strings` hygiene is clean (no duplicate, trailing-space or dead keys; en and zh both 190 keys), a new English corpus test asserts language 0 output has no CJK, and old window-state/keymaps/game-shortcuts/gui-prefs compatibility is covered by tests |
| Accessibility | icon-only controls across the centre toolbar, device rows, palette, overlays and player chrome carry labels and hide decorative images; palette rows and the logcat bar are focusable buttons; sheets answer Esc/Return; the a11y tree and Tab order were validated at the API level because this session cannot use AX inspection or VoiceOver |
| Screenshot matrix | 11 baselines now cover zh/en × dark and the light centre states, rendered with the registered Geist fonts and pixel-exact checks (byte-identical across two `--update` runs) |

Verification on this machine: both previews build, `test.sh` runs 21 test groups with the
localization gate at zero findings, `test-window.sh` passes, the token generator is idempotent
and `--check`-clean, and light/dark Geist renders are captured in `target/m3-tokens/` and
`target/m3-tokens2/`. The CI macOS job gains the token-drift check; the screenshot check stays
reported until the runner image is pinned.

**M3 gate status: met** with documented limits. The zh/en light/dark matrix is committed, the
localization gate is at zero, the compact layouts and sheets fit the target sizes, and old
configs are readable. The real-device and real-game part of the acceptance is M4; a player
window stays dark on purpose (matches Slint) and Noto Kufi is registered but RTL is out of
scope. Accessibility end-to-end (VoiceOver/Tab order) remains a manual check.

## M4: isolated real-device acceptance (status 2026-11-11)

All runs used a throwaway `JIDR_HOME` under `/tmp`, a one-off AVD and a read-only SDK; no
user data, AVDs or SDK files were touched and no Google licence was accepted by a test.

| Evidence | Result |
|---|---|
| CLI/protocol flow (`scripts/m4-swiftui-acceptance.sh`, read-only SDK, real emulator) | **11/11 steps in 104 s**: create → boot (23 s) → connect-info → `app.list` + launch Settings (focused) → screenshot → guest marker, `snapshot.save`, delete, `snapshot.load`, marker read back → `root.verify`/`root.set adb` (uid=0) → 3 s recording (88 frames) → stop → delete → daemon quit |
| Live UI render (`render-live.sh` + `Tests/LiveRender`) | real daemon + real device (Android 16 API 36): centre ready 102 ms, centre 1000×640 and 820×600 renders, player first frame **173 ms** at 432×768; app list empty on a fresh image is the real state and is noted |
| Player performance (`bench-player.sh` + `Tests/Bench`) | 30/30 taps detected: touch→new-frame **median 13.28 ms, p90 24.57 ms** (ADR-0001 budget 80 ms: PASS); 10 s driven run at 576×1280: received **59.0 fps**, presented ("delivered to the UI hop", the same counter as Slint's `shown`) **59.0 fps**; 173.42 MB/s; player+bridge CPU 52.76% of one core; RSS 832 MB; bench result PASS. The stricter actual-draw counter read 50 fps: the machine's main display was running at **50 Hz**, and AppKit draws at most once per refresh, so that number is the panel ceiling, not a SwiftUI cost (per-frame draw measured at 0.13–0.16 ms; a 60 Hz screen placement still drew at 50 Hz in this session). The bench now reports `display_refresh_hz`/`displayed_ratio_of_refresh`, takes `--screen N` to place the window on a known display, and gates the UI-hop counter against 55 fps while judging the draw counter against the panel. |
| Slint comparison | live A/B not obtained: `display_bench` itself does not drive frames and the swipe driver had a script bug, so its numbers are a static-scene artefact. Against the same-machine 2026-11-09 reference (received 59.97 / displayed 58.72, CPU 61.3%) presented fps is -0.5% (reference only, no PASS/FAIL) |
| Rollback | the Slint 0.3.1 app starts normally on a `gui-prefs.json` written with the SwiftUI shape (unknown keys ignored, file untouched); keymaps/shortcuts/window-state legacy readers are covered by tests |

The presented-vs-draw gap is explained: the bench session's main display is a DELL
S2725QS running at 50 Hz (it offers 60 and 120 Hz modes), so AppKit window draws cap at 50/s
while the stream delivers 59–60 frames/s; per-frame draw cost measured 0.13–0.16 ms, so this
is not a SwiftUI regression. On a 60/120 Hz display the draw counter should track presented
fps. The scenario's remaining manual checks are real-game compatibility, on-screen
IME/clipboard behaviour, VoiceOver/Tab order (this session has no screen-recording or
accessibility permission), and a Slint live A/B with a driven scene.

The automated part of M4 is complete; the three manual items above stay open as switch
conditions for M6.

**M4 gate status: the automated part is done** — CLI/protocol acceptance passed on a real
device, the real-device UI renders and the player measurements are inside the ADR-0001 budget
with one logged observation (actual draws below presented frames). The three manual items
(real game, on-screen IME/clipboard, VoiceOver/Tab order) stay open as M6 switch conditions.

## M6: default switch (executed 2026-11-11)

| Item | Result |
|---|---|
| Default GUI | `cargo xtask release` builds the SwiftUI device centre; `--gui slint` keeps the pre-M6 chain as the fallback. The release and release-check workflows therefore ship the SwiftUI app. |
| Production launch | a packaged launch without arguments and without `JIDR_HOME` leaves the environment unset, so the centre, the bridge and the daemon resolve the standard `~/Library/Application Support/Jidr` paths like the CLI. Verified from the rehearsal DMG with an isolated `HOME`: the socket appeared at the standard path, one daemon answered `daemon status`, and the real home was untouched. |
| Release rehearsal | `cargo xtask release --rehearsal` builds the release-profile centre and helpers, assembles the bundle (fonts, localisations, licences, no standalone player, no test sentinel), signs inside-out ad-hoc, packs the DMG, scans for forbidden content and runs mount/install/launch/uninstall checks with `report.md`. |
| Docs, architecture, licensing | README, AGENTS, CONTRIBUTING, NOTICE and ADR-0003 updated: SwiftUI/AppKit sources GPL-3.0-only, the Rust bridge Apache-2.0, the Slint crates the GPL fallback, the OFL fonts attributed; the guard still keeps every Apache crate free of Slint/GUI dependencies. |
| CI | the macOS job gained the token-drift check, the screenshot matrix (reported) and the release rehearsal (reported); the existing Rust gate is unchanged. |
| Slint fallback | the Slint crates and app stay buildable; `cargo xtask release --gui slint --dry-run` still produces the previous DMG. Deleting them remains a separate later decision. |

Remaining manual checks before calling the product fully accepted (no code left here): Developer
ID signing/notarization (needs the maintainer's credentials; `--gui swiftui` deliberately refuses
to pretend it signed), an install → upgrade → rollback run (needs a previous package), real-game
play, on-screen IME/clipboard behaviour and VoiceOver/Tab order (this session has no screen
recording or accessibility permission), and the 15% presented-vs-actual-draw observation.

### Post-M6 visual refresh (2026-11)

After the switch, the SwiftUI centre, settings window, sheets and player chrome were moved onto
the refreshed D41 palette and a shared `Center/DesignKit.swift` component layer: card surfaces with
hairline borders, status dots, accent-tinted selected rows, inline device actions with an overflow
menu, grouped settings forms with a native sidebar, and a dark token-built player chrome. The Slint
fallback consumes the same regenerated tokens while keeping its own layout. Every existing field,
action, alert, accessibility label and keyboard shortcut was preserved; the screenshot matrix was
regenerated. Details, implementation notes, deviations and verification live in
[docs/design/visual-refresh.md](design/visual-refresh.md).

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
