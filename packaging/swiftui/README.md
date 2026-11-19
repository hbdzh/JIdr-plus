# SwiftUI packaging

`cargo xtask release` is the sole application packaging implementation. It builds
`miko simulator.app`, an arm64 DMG, the MCP bundle and SHA256SUMS under `target/release-artifacts`.
The source template is `Miko-Info.plist.in` (bundle identity `ly.miko.Miko`).
Workspace version 0.7.0 supplies the CLI version, application plist version and
artifact filenames. The template deliberately keeps `@VERSION@` placeholders.

```bash
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

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
  Resources/Miko.icns
  Resources/en.lproj, zh-Hans.lproj
  Resources/device-list.png, device-detail.png, device-stopped.png
  Resources/fonts/               TTFs and OFL notices
  Resources/licenses/            LICENSE-APACHE, LICENSE-GPL, NOTICE
```

The main executable discovers helpers inside its bundle and uses the standard
Miko data directory when launched normally. Development explicit arguments are
`CENTER_BRIDGE PLAYER_BRIDGE` and require `MIKO_HOME`.

The bundle scan rejects Google SDK binaries, system images and Magisk. Ad-hoc
signatures are checked inside-out. Developer ID signing and notarization remain
unimplemented for all helpers and must not be reported as passing.
