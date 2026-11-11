# SwiftUI packaging

`cargo xtask release` is the sole application packaging implementation. It builds
`Jidr.app`, an arm64 DMG, the MCP bundle and SHA256SUMS under `target/release-artifacts`.
The source template is `Jidr-Info.plist.in` (bundle identity `ly.jidr.Jidr`).

```bash
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

`--rehearsal` uses ad-hoc signatures, isolated temporary data and install/uninstall
checks, and writes `target/release-rehearsal/report.md`. It neither publishes nor
replaces an installed app. `apps/jidr-swiftui/package-test.sh` delegates to it;
there is no second test-only packaging chain or standalone player application.

```
Jidr.app/Contents/
  Info.plist, PkgInfo
  MacOS/Jidr                     SwiftUI/AppKit center and player windows (GPL)
  Helpers/jidr                   CLI / daemon / MCP (Apache)
  Helpers/jidr-center-bridge      JSON-RPC center bridge (Apache)
  Helpers/jidr-swiftui-bridge     player frame/input bridge (Apache)
  Resources/Jidr.icns
  Resources/en.lproj, zh-Hans.lproj
  Resources/device-list.png, device-detail.png
  Resources/fonts/               TTFs and OFL notices
  Resources/licenses/            LICENSE-APACHE, LICENSE-GPL, NOTICE
```

The main executable discovers helpers inside its bundle and uses the standard
Jidr data directory when launched normally. Development explicit arguments are
`CENTER_BRIDGE PLAYER_BRIDGE` and require `JIDR_HOME`.

The bundle scan rejects Google SDK binaries, system images and Magisk. Ad-hoc
signatures are checked inside-out. Developer ID signing and notarization remain
unimplemented for all helpers and must not be reported as passing.
