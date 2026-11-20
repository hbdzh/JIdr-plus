# Miko (جذر): rules for AI coding agents

Miko is an open-source Genymotion Desktop alternative in Rust with one-click rooted Android devices. These are the rules an agent (and any contributor) follows when changing it. [CONTRIBUTING.md](CONTRIBUTING.md) has the human-facing version with setup steps. Product and architecture decisions are in [docs/decisions/log.md](docs/decisions/log.md) (cited as `D<n>`) and the ADRs next to it. Don't change a decision as a side effect of other work: propose it in an issue first.

## Architecture in one paragraph

`miko daemon` owns all device state and drives the AOSP emulator (gRPC `EmulatorController`, the telnet console, `adb`). The GUI (`apps/miko-swiftui`, the sole SwiftUI/AppKit client), the CLI (`apps/miko`) and the MCP server (`miko mcp`) are thin clients over JSON-RPC 2.0 / NDJSON on a Unix socket. Every user action is a protocol command; UI-only view state (window size, zoom, panel layout) stays in the GUI. Providers (`miko-daemon` core, `miko-widgets`, `miko-root`) register commands through the `CommandProvider` trait in `miko-core`.

## Repository map

| Path | Contents | Licence |
|---|---|---|
| `crates/miko-core` | model, error codes, protocol types, the `CommandProvider` trait | Apache-2.0 |
| `crates/miko-proto` | gRPC code from the emulator's `emulator_controller.proto` / `snapshot_service.proto` | Apache-2.0 |
| `crates/miko-adb` | wraps the `adb` binary | Apache-2.0 |
| `crates/miko-sdk` | SDK discovery and install, license consent, AVDs, hardware profiles, download cache | Apache-2.0 |
| `crates/miko-backend` | `Backend` trait and the AOSP emulator backend (launch, ports, boot wait, console, gRPC) | Apache-2.0 |
| `crates/miko-daemon` | command registry, JSON-RPC server, jobs, events, locks | Apache-2.0 |
| `crates/miko-client` | protocol client used by the CLI, the GUI and MCP | Apache-2.0 |
| `crates/miko-mcp` | MCP server | Apache-2.0 |
| `crates/miko-widgets` | provider for sensors, phone, network, GPS, dev tools, media, snapshots | Apache-2.0 |
| `crates/miko-cpio` | ramdisk cpio and gz/lz4/xz codecs | Apache-2.0 |
| `crates/miko-root` | provider for root modes (adb, Magisk, verify, revert, build props) | Apache-2.0 |
| `apps/miko` | the `miko` binary: CLI, `daemon` and `mcp` subcommands | Apache-2.0 |
| `apps/miko-swiftui` | SwiftUI/AppKit device centre and integrated player (only GUI); `bridge/` is the Apache-2.0 Rust bridge | **GPL-3.0-only** (Swift sources) / Apache-2.0 (bridge) |
| `xtask` | `ci`, `license-check`, `e2e-mac`, `release` | Apache-2.0 |
| `skills/` | agent skills (`skills/<name>/SKILL.md`, D43), checked by `cargo xtask skills-check` | Apache-2.0 |
| `docs/design/` | design tokens (`tokens.json`, the source for the app), CSS and component specs | — |

Dependency versions live in the root `[workspace.dependencies]`; crates use `foo.workspace = true`.

## Development skills

- `.agents/skills/` contains optional internal development skills. Choose skills and references for the task at hand; related areas do not require loading every skill or repeating the same analysis and checks.
- Use visual-design and relevant HIG skills for design questions, SwiftUI/AppKit skills for their implementation boundaries, and Rust skills for the specific language, API, concurrency, testing, performance, or safety work involved. Use `rust-uniffi-building` only when UniFFI is actually in use or explicitly being evaluated; FFI alone does not select a binding technology.
- Follow Miko's existing architecture, build scripts, and rules below over generic skill examples. Scope verification to the change and its risks, preserving regression tests, safety checks, and the full pre-PR gates required here.
- `skills/` contains product-facing skills. Read them when their development, maintenance, testing, or user-facing behavior is relevant; do not register them as default internal development skills.

## Licensing (D18)

- Apache-2.0 for project code except the desktop GUI sources: `apps/miko-swiftui` Swift/AppKit code (GPL-3.0-only by choice, ADR-0003). The SwiftUI Rust bridge is Apache-2.0. Third-party QEMU source records in `packaging/runtime-source/` retain their upstream licences and are separate from the Apache-licensed crates.
- The CLI, the daemon, MCP and every other Apache crate must never reintroduce Slint or the retired GUI crates. `cargo xtask license-check` (part of `cargo xtask ci`) enforces this.

## Clean-room rules (non-negotiable)

See [docs/clean-room.md](docs/clean-room.md). In short: use Genymotion's public docs, public AOSP emulator protos and docs, and behaviour observed by running the SDK tools. AOSP emulator source may be used for a separately licensed runtime and source records, never copied into Apache-licensed crates. Never decompile, string-dump or inspect Genymotion binaries. Never copy GPL code (Magisk, rootAVD); you may read their scripts to learn the documented ramdisk layout. Never bundle system images. A separately licensed, hash-pinned official Magisk APK may be bundled with its licence and corresponding source materials, without copying its GPL code into Apache-licensed crates. Bundling emulator and platform-tools binaries requires the verified component provenance, licences, corresponding source and notices described in `docs/clean-room.md`; do not publish unreviewed runtime material. No Google, Android or Genymotion logos. Log any non-obvious source in the clean-room file.

## Code rules

- Rust edition 2024, toolchain pinned in `rust-toolchain.toml`.
- Never crash: `unwrap`, `expect`, `panic!`, `todo!`, `unimplemented!` and `dbg!` are denied outside tests (workspace lints and `clippy.toml`). Return typed errors (`miko_core::MikoError`). Integration-test files (`tests/*.rs`) start with `#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`, because clippy's test allowance only covers `#[test]` fns and `#[cfg(test)]` modules.
- `unsafe` is denied by default. A crate that truly needs it allows it locally with a comment explaining why.
- Every bug fix gets a regression test.
- Emulators launch with `-gpu host` on macOS (ADR-0001: `auto` falls back to software rendering under `-no-window`); CI on Linux KVM uses `swiftshader_indirect`.
- Android Studio's SDK and AVDs are read-only (D3). Miko's own SDK lives in `~/Library/Application Support/Miko/sdk`. Tests create AVDs in temp dirs, never in `~/.android/avd`.
- Never accept a Google SDK license on a user's behalf outside a test context.

## Tests

- `cargo nextest run -p <crate>` runs unit and integration tests offline. `miko_daemon::testing::TestDaemon` gives a daemon with a fake backend and a fake SDK. The SwiftUI client has its own `apps/miko-swiftui/test.sh` (logic tests + localization gate), `snapshot.sh` (rendered screenshot matrix) and `cargo xtask release --rehearsal`/`render-live.sh` (packaging and live-device evidence).
- Tests that need a running emulator sit behind each crate's `emulator` feature (`cargo nextest run -p <crate> --features emulator`). They read:
  - `MIKO_TEST_SDK`: the SDK root (default `~/Library/Android/sdk`, used read-only);
  - `MIKO_TEST_IMAGE`: the sdkmanager package of the image (default on Apple Silicon `system-images;android-31;google_apis;arm64-v8a`);
  - `MIKO_TEST_API`: its API level.
- On a pull request, CI runs the emulator tests on Linux KVM with x86_64 images (API 30, 33 and 35). `cargo xtask e2e-mac` is the arm64 release gate on an Apple Silicon Mac (D28).

## Protocol

The control protocol is frozen at the tag `protocol-v0.1` ([docs/control-protocol.md](docs/control-protocol.md)). Any change to the wire format, an existing command's params or result, error codes or event topics needs a row in that file's changelog. New commands from providers are additive. The generated command reference is kept in sync by `cargo nextest run -p miko-daemon protocol_doc` (`MIKO_UPDATE_DOCS=1` rewrites it).

## GitHub presentation and releases

- Write the README, repository description, release notes and other public-facing copy in clear, natural Chinese unless the maintainer asks for another language. Be concise and specific; avoid formulaic promotion, repetitive headings, task handoff language and references to the writing process.
- Present the project as **miko 模拟器**, a macOS Android emulator management tool. Keep the upstream attribution, licence and third-party notices accurate. The README should make the main features, download, usage, build instructions and project links easy to find; update claims as the product changes.
- For each release, compare the new version with the previous released version and account for all relevant additions, fixes and improvements, including work merged in multiple PRs. Use the categories **新增**, **修复** and **优化** where applicable; describe user-visible behavior and important technical changes concretely. Check the actual changes and changelog rather than relying on generated commit summaries alone.
- Include relevant installation requirements, signing/notarization status, checksums, known issues and verification limits when they apply. Report failed, skipped or unverified checks accurately; do not imply that a build or automated test proves real-device acceptance. Keep GitHub Release notes and `CHANGELOG.md` consistent without dropping substantive changes or risks.
- Keep PR titles and descriptions focused on the actual change and its validation. Avoid conversational history or unsupported claims about authorship; retain necessary attribution and factual records.
- After an authorized PR is merged, remove its merged local and remote working branches when safe. Keep `master` and preserve branches containing unmerged work. Do not generalize a one-time approval to bypass a failing check to future PRs or releases.

## Before you open a pull request

1. `cargo xtask ci` passes: fmt, clippy, tests, the licence check and the skills check.
2. If you touched a crate with emulator tests, run them for that crate if you have an image.
3. Docs that describe the change are updated (`docs/cli.md`, `docs/mcp.md`, `docs/root.md`, the protocol changelog, and `skills/` when a command an agent uses changes).
4. One conventional commit per logical change (`feat(daemon): …`, `fix(widgets): …`, `docs: …`). Release notes are generated from them.
5. Never push to `main`; open a pull request. Don't push or publish anything without the maintainer asking.

## Useful commands

```bash
cargo xtask ci                                   # fmt, clippy, tests, license-check, skills-check
cargo xtask license-check                        # D18 split-licensing guard
cargo xtask skills-check                         # skills' frontmatter and miko commands (D43)
cargo nextest run -p <crate>                     # unit + integration tests
cargo nextest run -p <crate> --features emulator # needs an emulator image
cargo xtask e2e-mac                              # release gate on Apple Silicon (D28)

# GUI (SwiftUI) and release rehearsal
bash apps/miko-swiftui/build-center.sh # debug app build
bash apps/miko-swiftui/test.sh         # Swift logic tests + localization gate
bash apps/miko-swiftui/snapshot.sh --check --only tools-battery-light # hidden, scoped; --all only for full regression
cargo xtask release --rehearsal                  # SwiftUI app + DMG, ad-hoc, local only
```
