# SwiftUI packaging

Packaging for the SwiftUI/AppKit device center:

1. the **M1 test package** — an ad-hoc-signed `JidrSwiftUICenter.app` and
   `Jidr-<version>-test.dmg` built by
   `apps/jidr-swiftui-prototype/package-test.sh`; it exists so packaging,
   signing, localisation, licences and the forbidden-content scan are
   exercised on a real bundle; and
2. the **M5 production release chain** — `cargo xtask release --gui swiftui`
   in `xtask/src/release.rs`, with `Jidr-Info.plist.in` and
   `apps/jidr-swiftui-prototype/build-release.sh`. Since M6 this is the default
   release GUI; the Slint app is the `--gui slint` fallback.

| File | What |
|---|---|
| `Info.plist.in` | M1 test-bundle metadata (`ly.jidr.JidrSwiftUICenter.test`); `@VERSION@` becomes the workspace version |
| `Jidr-Info.plist.in` | M5 production bundle metadata (`ly.jidr.Jidr`), used by `cargo xtask release --gui swiftui` |
| `apps/jidr-swiftui-prototype/package-test.sh` | builds, assembles, signs, packs and verifies the M1 test package |
| `apps/jidr-swiftui-prototype/build-release.sh` | builds the optimised (`swiftc -O`) SwiftUI center for the release chain |
| `../swiftui/README.md` | this file |

## Output

```
target/swiftui-package/
  JidrSwiftUICenter.app             signed bundle, ready to copy or run
  Jidr-<version>-test.dmg           disk image with the same app and an /Applications link
  SHA256SUMS.txt
  VERSION
```

The app and the DMG live under `target/`; the script never writes to
`/Applications`, never replaces an installed `Jidr.app` and never touches
`~/Library/Application Support/Jidr` by itself.

## Bundle layout

```
JidrSwiftUICenter.app/Contents/
  Info.plist  PkgInfo
  MacOS/JidrSwiftUICenter      SwiftUI center (GPL-3.0)       swiftc
  Helpers/jidr                 CLI + daemon (Apache-2.0)      apps/jidr
  Helpers/jidr-center-bridge   center bridge (Apache-2.0)     bridge crate
  Helpers/jidr-swiftui-bridge  player bridge (Apache-2.0)     bridge crate
  Helpers/JidrSwiftUIPrototype.app  standalone player, development/test entry only
  Resources/Jidr.icns          from apps/jidr-gui/assets/macos (D39)
  Resources/en.lproj, zh-Hans.lproj  Localizable.strings
  Resources/device-list.png, device-detail.png  center art
  Resources/licenses/          LICENSE-APACHE, LICENSE-GPL, NOTICE
```

The CLI lives in `Helpers/` for the same case-insensitive-APFS reason as the
Slint app (`MacOS/jidr` and `MacOS/Jidr` would be the same path). The center
finds these paths from `Contents/Helpers` when it starts without arguments
(`Center/main.swift`, `helpersInBundle()`); running it with the three explicit
arguments keeps the old development behaviour. The standalone player is a
development/test entry point (ADR-0003) and is kept only so the old
three-argument layout stays testable; production packaging drops it.

## Build

```bash
bash apps/jidr-swiftui-prototype/package-test.sh
```

Requirements: macOS on Apple Silicon, the workspace Rust toolchain, Xcode
`swiftc`, `protoc` for `jidr-proto` (the script also looks in
`target/tools/protoc/bin`), `python3`, and the system `codesign`, `hdiutil`,
`diskutil`, `plutil`, `ditto`, `shasum`. Rust helpers are built in **debug**
mode on purpose: this is a packaging/behaviour test package, not a release
build (M5).

## Signing

Ad-hoc, inside-out, no `--deep`:

```
codesign --force --options runtime --timestamp=none -s - Contents/Helpers/JidrSwiftUIPrototype.app/Contents/MacOS/JidrSwiftUIPrototype
codesign ... Contents/Helpers/JidrSwiftUIPrototype.app
codesign ... Contents/Helpers/jidr
codesign ... Contents/Helpers/jidr-center-bridge
codesign ... Contents/Helpers/jidr-swiftui-bridge
codesign ... Contents/MacOS/JidrSwiftUICenter
codesign ... JidrSwiftUICenter.app
codesign --verify --strict JidrSwiftUICenter.app
```

The bundle identifier is `ly.jidr.JidrSwiftUICenter.test`, deliberately
different from the installed `Jidr` (`ly.jidr.Jidr`), so both can coexist.
Because the build is ad-hoc and not notarized, Gatekeeper rejects a
quarantined copy on first launch; for local test packages, copy the app out
of the DMG and start it directly (below), or clear the quarantine after
checking the checksum.

## Isolated launch

The test bundle carries a `test-package` sentinel in `Contents/Resources`, so a
**Finder double-click or `open`** works without environment variables: without
`JIDR_HOME` the center uses `~/Library/Application Support/Jidr-SwiftUI-Test`
and never touches the user's `~/Library/Application Support/Jidr`. Development
builds from `target/` keep the explicit-`JIDR_HOME` requirement (there is no
sentinel). `package-test.sh` exercises the Finder-style launch (no `JIDR_HOME`)
and removes the test data directory afterwards.

The daemon starts on demand. From a copy of the app outside the DMG with an
explicit home:

```bash
tmp="$(mktemp -d /tmp/jidr-pkg.XXXXXX)"   # short path: the daemon socket limit is 100 bytes
cp -R "/Volumes/Jidr SwiftUI Center <version> test/JidrSwiftUICenter.app" "$tmp/"
JIDR_HOME="$tmp/home" "$tmp/JidrSwiftUICenter.app/Contents/MacOS/JidrSwiftUICenter"
```

`package-test.sh` does exactly this automatically after mounting the DMG: it
waits for `<JIDR_HOME>/data/daemon.sock`, checks that the center bridge and
the bundled daemon are running, asks the bundled CLI for `daemon status`, then
stops the daemon and the app. `JIDR_SKIP_GUI_TEST=1` records the launch check
as not executed instead of running it.

## Forbidden content

The script mounts the DMG under `/tmp` (this macOS refuses a mountpoint inside
the external workspace volume) and scans the mounted tree exactly like
`cargo xtask release --scan` does (same `classify_name`/`classify_content` rules
from `xtask/src/release.rs`, re-implemented for the bundle): Google SDK/emulator
tools and kernels, APKs and Android payload formats (ELF, boot/sparse images,
ext4, ramdisk cpio/lz4, dex, APKs), system-image files and package metadata, and
Magisk by name. A synthetic tree with `magisk.apk`, `system.img`, an ELF file,
`source.properties` and an APK makes the scan fail, which is how the rule set is
exercised; the built app scans clean (20 files, 16 directories). Jidr downloads
those artefacts on the user's machine and never ships them (NOTICE, clean-room
rules).

## M5 production release chain (`cargo xtask release --gui swiftui`)

The production chain is `xtask/src/release.rs`; this folder only holds its
Info.plist template. It does not replace the installed app and it is separate
from the M1 test package above.

```bash
PATH="$PWD/target/tools/bin:$PATH" PROTOC="$PWD/target/tools/protoc/bin/protoc" \
  cargo xtask release --gui swiftui --rehearsal   # ad-hoc, local, writes report.md
cargo xtask release --gui swiftui                 # real SwiftUI release (credentials for notarization)
cargo xtask release                               # SwiftUI default since M6
```

- `--gui swiftui` is the default since M6. `--gui slint` builds the
  Rust helpers in the release profile (`jidr`, `jidr-center-bridge`,
  `jidr-swiftui-bridge`), compiles the device center with
  `apps/jidr-swiftui-prototype/build-release.sh` (`swiftc -O`) and assembles
  `Jidr.app/Contents/MacOS/Jidr` plus `Contents/Helpers/{jidr,
  jidr-center-bridge, jidr-swiftui-bridge}`.
- The production bundle keeps the `ly.jidr.Jidr` identity, `Jidr.icns`,
  `LSMinimumSystemVersion 13.0`, `NSHighResolutionCapable`,
  `ATSApplicationFontsPath=fonts` and the en/zh-Hans localisations. It ships
  `Contents/Resources/fonts/` (the 8 Geist / Geist Mono / Noto Kufi Arabic TTF
  files plus their OFL texts), the center device art, and
  `Contents/Resources/licenses/` with LICENSE-APACHE, LICENSE-GPL and NOTICE.
  It never contains the standalone player app (ADR-0003) or the M1
  `test-package` sentinel.
- `--rehearsal` implies `--scan`, always signs ad-hoc (never a Developer ID,
  never notarizes), writes to `target/release-rehearsal/` (DMG, MCP bundle,
  `SHA256SUMS.txt`, `VERSION`, `report.md`) and runs the mounted-DMG checks:
  bundle structure, inside-out `codesign --verify --strict`, the same
  forbidden-content scan as `--scan`, `Contents/Helpers/jidr --version` from
  the mounted image, an isolated `JIDR_HOME` install/launch/`daemon status`,
  `jidr uninstall --purge` in that isolated home, `/Applications` and the real
  Jidr data left untouched, and the observed Gatekeeper verdict.
- Signing honesty: with no Developer ID credentials the rehearsal signs ad-hoc,
  Gatekeeper rejects the copy and `report.md` records that as expected, with
  Developer ID signing, notarization and stapling explicitly marked **NOT
  VERIFIED**. `--gui swiftui` refuses the Developer ID path until
  `packaging/macos/sign.sh` also signs the two bridge helpers (M5b), rather
  than shipping an unverified signature.
- The production app still requires an explicit `JIDR_HOME` because the
  production bundle intentionally has no sentinel; since M6 the centre defaults
  to the standard Jidr home when launched without arguments and without
  JIDR_HOME (development builds still require it).
- `report.md` also lists the unverified items (Developer ID/notarization,
  upgrade from an older installer, Finder launch without `JIDR_HOME`,
  real-device acceptance) and the notes for the M6 switch.

## Open items

- The M1 test package stays debug-built and ad-hoc; it is a packaging and
  behaviour rehearsal, not a release artifact.
- The M5 SwiftUI chain is ad-hoc in rehearsal. The Developer ID +
  notarization path needs `packaging/macos/sign.sh` extended to the two bridge
  helpers before the first signed SwiftUI release; until then the rehearsal
  reports it as unverified instead of passing it.
- Since M6 the production bundle defaults to `~/Library/Application Support/Jidr`
  on a plain launch; development builds keep the explicit JIDR_HOME requirement.
