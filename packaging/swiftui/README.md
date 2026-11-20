# SwiftUI packaging

`cargo xtask release` is the sole application packaging implementation. It builds
`miko simulator.app`, an arm64 DMG, the MCP bundle and SHA256SUMS under `target/release-artifacts`.
The source template is `Miko-Info.plist.in` (bundle identity `ly.miko.Miko`).
The workspace version supplies the CLI version, application plist version and
artifact filenames. The template deliberately keeps `@VERSION@` placeholders.

Prepare a new runtime directory from the verified upstream archives and the
pinned locally built core (existing destinations are never overwritten):

```bash
python3 scripts/prepare-bundled-runtime.py \
  --emulator-zip /path/to/emulator-darwin_aarch64-16970787.zip \
  --platform-tools-zip /path/to/platform-tools_r37.0.3-darwin.zip \
  --core /path/to/qemu-system-aarch64-headless \
  --output /path/to/new-runtime
export MIKO_BUNDLED_SDK=/path/to/new-runtime
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

The local candidate requires `MIKO_BUNDLED_SDK` with `emulator/` and
`platform-tools/`. It checks every file against the pinned SHA-256 manifest, the 37.3.10 runtime, core libraries and notices,
and copies the two directories into the application. System images remain
separate. This input is external build material and is not stored in the
repository. This is local development work only. The clean-room policy allows
redistribution only after the component provenance, licences, corresponding-source
obligations and notices are verified; this review remains open.

For GitHub Actions, the shared `prepare-miko-runtime` action can fetch a
separately hosted pinned core from repository variable `MIKO_RUNTIME_CORE_URL`,
verify its SHA-256, download the two pinned official archives and reconstruct
the runtime. The action was exercised locally with fixture downloads; it has
not yet run on GitHub. No core URL is configured by this change. The public
release gate remains closed and the packaging-check workflow deliberately does
not upload its local test artifacts while redistribution review is incomplete.
The action's local fixture test is `scripts/test-ci-runtime-action.sh` followed
by the two archive paths and the core path. A core built from source must first
be reviewed and made available at a stable HTTPS location with its complete
corresponding source. See
`docs/runtime-provenance-local.md`.

`--rehearsal` uses ad-hoc signatures, isolated temporary data and install/uninstall
checks, and writes `target/release-rehearsal/report.md`. It neither publishes nor
replaces an installed app. `apps/miko-swiftui/package-test.sh` delegates to it;
there is no second test-only packaging chain or standalone player application.

```
miko simulator.app/Contents/
  Info.plist, PkgInfo
  MacOS/Miko                     SwiftUI/AppKit center and player windows (GPL)
  Helpers/miko                   CLI / daemon / MCP (Apache)
  Helpers/miko-center-bridge      JSON-RPC center bridge (Apache)
  Helpers/miko-swiftui-bridge     player frame/input bridge (Apache)
  Resources/sdk/                 local candidate: emulator and platform-tools
  Resources/Miko.icns
  Resources/en.lproj, zh-Hans.lproj
  Resources/device-list.png, device-detail.png, device-stopped.png
  Resources/fonts/               TTFs and OFL notices
  Resources/licenses/            LICENSE-APACHE, LICENSE-GPL, NOTICE
```

The main executable discovers helpers inside its bundle and uses the standard
Miko data directory when launched normally. Development explicit arguments are
`CENTER_BRIDGE PLAYER_BRIDGE` and require `MIKO_HOME`.

The candidate scan matches bundled SDK tools against its input and rejects
system images and unapproved APKs; the pinned official Magisk APK, source and licence are bundled. Ad-hoc
signatures are checked inside-out. Developer ID signing and notarization remain
unimplemented for all helpers and must not be reported as passing.
