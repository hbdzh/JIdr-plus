# SwiftUI test package

The M1 test package for the SwiftUI/AppKit device center: an ad-hoc-signed
`JidrSwiftUICenter.app` and `Jidr-<version>-test.dmg`, built by
`apps/jidr-swiftui-prototype/package-test.sh`. This is not the production
release chain (that is M5 and reuses the Slint packaging in `../macos/`); it
exists so packaging, signing, localisation, licences and the forbidden-content
scan are exercised on a real bundle.

| File | What |
|---|---|
| `Info.plist.in` | bundle metadata; `@VERSION@` becomes the workspace version |
| `../swiftui/README.md` | this file |
| `apps/jidr-swiftui-prototype/package-test.sh` | builds, assembles, signs, packs and verifies the package |

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

## Open items

- Not notarized and not signed with a Developer ID; that is M5 work.
- The Swift center binary is compiled by the existing preview script
  (`build-center.sh`, unoptimized) so there is one source list for the center;
  a release profile revisits that in M5.
- The test package defaults to an isolated data directory
  (`~/Library/Application Support/Jidr-SwiftUI-Test`). The production app will
  default to the standard `~/Library/Application Support/Jidr` path; that
  decision belongs to M5 packaging, not to the test bundle.
