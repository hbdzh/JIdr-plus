#!/bin/bash
# Package the SwiftUI device center as an installable, ad-hoc-signed test bundle.
#
#   bash apps/jidr-swiftui-prototype/package-test.sh
#
# Builds the center app (build-center.sh), the standalone player (build.sh) and
# the Rust helpers, assembles JidrSwiftUICenter.app with Contents/{MacOS,Helpers,
# Resources}, renders packaging/swiftui/Info.plist.in with the workspace version,
# signs it inside-out (ad-hoc, hardened runtime), packs Jidr-<version>-test.dmg
# with an /Applications link, mounts the DMG and checks the layout, localisations,
# icon, licences, signature, forbidden content (Google SDK, system images, Magisk)
# and an isolated JIDR_HOME launch.
#
# Output: target/swiftui-package/{JidrSwiftUICenter.app,Jidr-<version>-test.dmg,
#         SHA256SUMS.txt,VERSION}. The script never installs the app, never
# replaces the installed Jidr.app and never writes ~/Library/Application Support/Jidr
# by itself; the launch check uses its own mktemp JIDR_HOME.
#
# Environment:
#   JIDR_SKIP_GUI_TEST=1   record the isolated launch check as "not executed"
#                          instead of starting the app (for environments without
#                          a GUI session); the rest of the verification still runs.
#   PROTOC=...             protoc for jidr-proto's build script; otherwise
#                          target/tools/protoc/bin, Homebrew and PATH are tried.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

die()  { printf 'package-test: %s\n' "$*" >&2; exit 1; }
note() { printf 'package-test: %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

out="$root/target/swiftui-package"
app="$out/JidrSwiftUICenter.app"
dmg_stage="$out/dmg-staging"
mountpoint=""
version=""
dmg=""
tmp_home=""
app_pid=""
mounted=0

cleanup() {
    local code=$?
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$app_pid" 2>/dev/null || true
    fi
    if [ "$mounted" -eq 1 ]; then
        hdiutil detach "$mountpoint" -quiet 2>/dev/null ||
            hdiutil detach "$mountpoint" -force -quiet 2>/dev/null || true
    fi
    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
        rm -rf "$mountpoint"
    fi
    if [ -n "$tmp_home" ]; then
        rm -rf "$tmp_home"
    fi
    exit "$code"
}
trap cleanup EXIT INT TERM

# --- preflight ------------------------------------------------------------
step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "this script packages a macOS app; run it on macOS"
[ "$(uname -m)" = "arm64" ] || note "warning: building on $(uname -m); Info.plist prefers arm64"
for tool in cargo swiftc codesign hdiutil plutil ditto shasum python3 xattr; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
if [ -z "${PROTOC:-}" ]; then
    for candidate in "$root/target/tools/protoc/bin/protoc" /opt/homebrew/bin/protoc /usr/local/bin/protoc; do
        if [ -x "$candidate" ]; then
            export PROTOC="$candidate"
            break
        fi
    done
fi
if [ -n "${PROTOC:-}" ]; then
    note "protoc: $PROTOC"
else
    note "warning: protoc not found in target/tools, Homebrew or PATH; cargo relies on a cached jidr-proto build"
fi
if [ -d /Applications/Jidr.app ]; then
    note "installed /Applications/Jidr.app detected; this script only writes under target/"
fi

# --- version (single source: the workspace/jidr Cargo version) ------------
step "Reading the workspace version"
version="$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c '
import json, sys
meta = json.load(sys.stdin)
print(next((p["version"] for p in meta["packages"] if p["name"] == "jidr"), ""))
')"
[ -n "$version" ] || die "cannot read the jidr package version from cargo metadata"
case "$version" in
    *[!0-9A-Za-z.-]*) die "invalid workspace version: $version" ;;
esac
dmg="$out/Jidr-$version-test.dmg"
if git -C "$root" rev-parse -q --verify "refs/tags/v$version" >/dev/null 2>&1; then
    note "version $version (git tag v$version)"
else
    note "version $version (no git tag v$version; using the Cargo version)"
fi

# --- build ----------------------------------------------------------------
step "Building Rust helpers (debug profile: this is a test package, not M5)"
cargo build -p jidr -p jidr-swiftui-bridge
bin_dir="$root/target/debug"
for bin in jidr jidr-center-bridge jidr-swiftui-bridge; do
    [ -x "$bin_dir/$bin" ] || die "cargo build did not produce $bin_dir/$bin"
done

step "Building the Swift center and player previews"
bash apps/jidr-swiftui-prototype/build-center.sh
bash apps/jidr-swiftui-prototype/build.sh
center_bin="$root/target/swiftui-center/JidrSwiftUICenter.app/Contents/MacOS/JidrSwiftUICenter"
player_app="$root/target/swiftui-prototype/JidrSwiftUIPrototype.app"
[ -x "$center_bin" ] || die "build-center.sh did not produce $center_bin"
[ -d "$player_app" ] || die "build.sh did not produce $player_app"

# --- assemble -------------------------------------------------------------
step "Assembling $app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" \
         "$app/Contents/Helpers" \
         "$app/Contents/Resources/en.lproj" \
         "$app/Contents/Resources/zh-Hans.lproj" \
         "$app/Contents/Resources/licenses"

cp "$center_bin" "$app/Contents/MacOS/JidrSwiftUICenter"
for bin in jidr jidr-center-bridge jidr-swiftui-bridge; do
    cp "$bin_dir/$bin" "$app/Contents/Helpers/$bin"
done
ditto "$player_app" "$app/Contents/Helpers/JidrSwiftUIPrototype.app"
cp apps/jidr-gui/assets/macos/Jidr.icns "$app/Contents/Resources/Jidr.icns"
cp apps/jidr-swiftui-prototype/Resources/en.lproj/Localizable.strings \
   "$app/Contents/Resources/en.lproj/Localizable.strings"
cp apps/jidr-swiftui-prototype/Resources/zh-Hans.lproj/Localizable.strings \
   "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp crates/jidr-ui/ui/assets/device-list-generated.png "$app/Contents/Resources/device-list.png"
cp crates/jidr-ui/ui/assets/device-detail-generated.png "$app/Contents/Resources/device-detail.png"
cp LICENSE-APACHE "$app/Contents/Resources/licenses/LICENSE-APACHE"
cp apps/jidr-gui/LICENSE-GPL "$app/Contents/Resources/licenses/LICENSE-GPL"
cp NOTICE "$app/Contents/Resources/licenses/NOTICE"
printf 'APPL????' > "$app/Contents/PkgInfo"
# Marks this bundle as the isolated test package: Center/main.swift then defaults
# JIDR_HOME to ~/Library/Application Support/Jidr-SwiftUI-Test when it is unset.
: > "$app/Contents/Resources/test-package"

python3 - "$root/packaging/swiftui/Info.plist.in" "$app/Contents/Info.plist" "$version" <<'PY'
import sys
template_path, dest, version = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(template_path, encoding="utf-8").read()
if "@VERSION@" not in text:
    sys.exit("packaging/swiftui/Info.plist.in has no @VERSION@ placeholder")
rendered = text.replace("@VERSION@", version)
if "@VERSION@" in rendered:
    sys.exit("Info.plist.in still contains @VERSION@")
open(dest, "w", encoding="utf-8").write(rendered)
PY
plutil -lint "$app/Contents/Info.plist" >/dev/null || die "rendered Info.plist is not a valid plist"
note "helpers: $(cd "$app/Contents/Helpers" && ls -1 | tr '\n' ' ')"

# --- sign -----------------------------------------------------------------
step "Signing (ad-hoc, hardened runtime, inside-out)"
xattr -cr "$app"
sign() {
    codesign --force --options runtime --timestamp=none -s - "$1" >/dev/null 2>&1 ||
        die "codesign failed for $1"
}
player="$app/Contents/Helpers/JidrSwiftUIPrototype.app"
sign "$player/Contents/MacOS/JidrSwiftUIPrototype"
sign "$player"
for bin in jidr jidr-center-bridge jidr-swiftui-bridge; do
    sign "$app/Contents/Helpers/$bin"
done
sign "$app/Contents/MacOS/JidrSwiftUICenter"
sign "$app"
if ! codesign --verify --strict --verbose=2 "$app" >"$out/codesign-verify.log" 2>&1; then
    sed 's/^/  /' "$out/codesign-verify.log" >&2
    die "codesign --verify --strict failed after signing"
fi
note "codesign --verify --strict: ok"
signature_info="$(codesign -dv "$app" 2>&1 || true)"
case "$signature_info" in
    *Signature=adhoc*) ;;
    *) printf '%s\n' "$signature_info" >&2; die "the bundle is not ad-hoc signed" ;;
esac
for nested in \
    "$app/Contents/MacOS/JidrSwiftUICenter" \
    "$app/Contents/Helpers/jidr" \
    "$app/Contents/Helpers/jidr-center-bridge" \
    "$app/Contents/Helpers/jidr-swiftui-bridge" \
    "$player" \
    "$player/Contents/MacOS/JidrSwiftUIPrototype"; do
    codesign --verify --strict "$nested" >/dev/null 2>&1 || die "nested signature does not verify: $nested"
done
note "signature: adhoc, hardened runtime; nested helpers verified"

# --- DMG ------------------------------------------------------------------
step "Creating the DMG"
mkdir -p "$dmg_stage"
ditto "$app" "$dmg_stage/JidrSwiftUICenter.app"
ln -s /Applications "$dmg_stage/Applications"
volume="Jidr SwiftUI Center $version test"
create_dmg() {
    hdiutil create -volname "$volume" -srcfolder "$dmg_stage" -fs APFS -format UDZO -ov "$dmg" \
        >"$out/hdiutil-create.log" 2>&1
}
if ! create_dmg; then
    note "first hdiutil create failed (Resource busy is transient); retrying once"
    sleep 5
    create_dmg || { sed 's/^/  /' "$out/hdiutil-create.log" >&2; die "hdiutil create failed"; }
fi
rm -rf "$dmg_stage" "$out/hdiutil-create.log"
hdiutil verify "$dmg" >/dev/null || die "hdiutil verify failed for $dmg"
sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
printf '%s  %s\n' "$sha" "$(basename "$dmg")" > "$out/SHA256SUMS.txt"
printf '%s\n' "$version" > "$out/VERSION"
note "DMG: $dmg ($(du -h "$dmg" | awk '{print $1}'))"
note "SHA256: $sha"

# --- mount and verify -----------------------------------------------------
step "Mounting and verifying the DMG"
# Mount under /tmp: this macOS refuses a mountpoint inside the external workspace
# volume ("Permission denied"), and a short path stays well below every limit.
mountpoint="$(mktemp -d /tmp/jidr-pkg-mnt.XXXXXX)"
if ! hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$dmg" >"$out/attach.log" 2>&1; then
    note "hdiutil attach failed ($(tail -1 "$out/attach.log")); trying the diskutil image fallback"
    diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$mountpoint" "$dmg" >/dev/null ||
        die "cannot attach $dmg"
fi
rm -f "$out/attach.log"
mounted=1
mounted_app="$mountpoint/JidrSwiftUICenter.app"
[ -L "$mountpoint/Applications" ] && [ "$(readlink "$mountpoint/Applications")" = "/Applications" ] ||
    die "the DMG has no /Applications symlink"

expect_file() { [ -f "$1" ] || die "missing file in the DMG: $1"; }
expect_exec() { [ -x "$1" ] || die "not executable in the DMG: $1"; }
expect_dir()  { [ -d "$1" ] || die "missing directory in the DMG: $1"; }

expect_dir "$mounted_app"
plist="$mounted_app/Contents/Info.plist"
expect_file "$plist"
executable="$(plutil -extract CFBundleExecutable raw "$plist")"
expect_exec "$mounted_app/Contents/MacOS/$executable"
for bin in jidr jidr-center-bridge jidr-swiftui-bridge; do
    expect_exec "$mounted_app/Contents/Helpers/$bin"
done
expect_exec "$mounted_app/Contents/Helpers/JidrSwiftUIPrototype.app/Contents/MacOS/JidrSwiftUIPrototype"
expect_file "$mounted_app/Contents/PkgInfo"
[ "$(cat "$mounted_app/Contents/PkgInfo")" = "APPL????" ] || die "unexpected PkgInfo content"

expect_file "$mounted_app/Contents/Resources/Jidr.icns"
[ "$(head -c 4 "$mounted_app/Contents/Resources/Jidr.icns")" = "icns" ] || die "Jidr.icns has no icns magic"
icon_name="$(plutil -extract CFBundleIconFile raw "$plist")"
[ "$icon_name" = "Jidr" ] || die "CFBundleIconFile is '$icon_name', expected Jidr"

for lproj in en zh-Hans; do
    table="$mounted_app/Contents/Resources/$lproj.lproj/Localizable.strings"
    expect_file "$table"
    [ -s "$table" ] || die "empty localisation table: $table"
    grep -q '=' "$table" || die "localisation table has no key/value entries: $table"
    note "localisation: $lproj.lproj ($(wc -l < "$table" | tr -d ' ') lines)"
done

for name in LICENSE-APACHE LICENSE-GPL NOTICE; do
    licence="$mounted_app/Contents/Resources/licenses/$name"
    expect_file "$licence"
    [ -s "$licence" ] || die "empty licence: $licence"
done
grep -q "Apache License" "$mounted_app/Contents/Resources/licenses/LICENSE-APACHE" ||
    die "LICENSE-APACHE does not look like the Apache licence"
grep -q "GNU GENERAL PUBLIC LICENSE" "$mounted_app/Contents/Resources/licenses/LICENSE-GPL" ||
    die "LICENSE-GPL does not look like the GNU GPL"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$plist")"
[ "$bundle_id" = "ly.jidr.JidrSwiftUICenter.test" ] || die "unexpected CFBundleIdentifier: $bundle_id"
[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" = "$version" ] ||
    die "CFBundleShortVersionString does not match $version"
[ "$(plutil -extract CFBundleVersion raw "$plist")" = "$version" ] ||
    die "CFBundleVersion does not match $version"
[ "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = "13.0" ] ||
    die "LSMinimumSystemVersion is not 13.0"
[ "$(plutil -extract NSHighResolutionCapable raw "$plist")" = "true" ] ||
    die "NSHighResolutionCapable is not true"
for arch_target in \
    "$mounted_app/Contents/MacOS/$executable" \
    "$mounted_app/Contents/Helpers/jidr" \
    "$mounted_app/Contents/Helpers/jidr-center-bridge" \
    "$mounted_app/Contents/Helpers/jidr-swiftui-bridge"; do
    file "$arch_target" | grep "arm64" >/dev/null || die "not an arm64 Mach-O: $arch_target"
done
# The bundled CLI must run straight from the (read-only) DMG, with no repo or dev env.
cli_version="$(env -u JIDR_HOME -u JIDR_DAEMON_BIN "$mounted_app/Contents/Helpers/jidr" --version 2>&1)" ||
    die "the bundled CLI does not run from the DMG: $cli_version"
[ "$cli_version" = "jidr $version" ] || die "unexpected bundled CLI version: $cli_version"
note "bundled CLI runs from the DMG: $cli_version"

if ! codesign --verify --strict --verbose=2 "$mounted_app" >"$out/codesign-verify-mounted.log" 2>&1; then
    sed 's/^/  /' "$out/codesign-verify-mounted.log" >&2
    die "codesign --verify --strict failed on the app inside the DMG"
fi
note "codesign --verify --strict (mounted DMG): ok"
for nested in \
    "$mounted_app/Contents/MacOS/$executable" \
    "$mounted_app/Contents/Helpers/jidr" \
    "$mounted_app/Contents/Helpers/jidr-center-bridge" \
    "$mounted_app/Contents/Helpers/jidr-swiftui-bridge" \
    "$mounted_app/Contents/Helpers/JidrSwiftUIPrototype.app"; do
    codesign --verify --strict "$nested" >/dev/null 2>&1 || die "signature does not verify in the DMG: $nested"
done
note "structure ok: Info.plist $bundle_id $version, helpers executable, en/zh-Hans, Jidr.icns, 3 licences, arm64, signatures"

# --- forbidden content ----------------------------------------------------
step "Scanning for forbidden content (Google SDK, system images, Magisk)"
python3 - "$mountpoint" <<'PY'
import os
import sys

root = sys.argv[1]
sdk_tools = {
    "emulator", "emulator-check", "adb", "fastboot", "sdkmanager",
    "avdmanager", "aapt", "aapt2", "mksdcard",
}
image_words = ("system", "vendor", "ramdisk", "userdata", "boot", "cache",
               "encryptionkey", "product")


def classify_name(name):
    lower = name.lower()
    if "magisk" in lower:
        return "Magisk (GPL-3.0, downloaded at runtime, never bundled)"
    if lower in sdk_tools or lower.startswith("qemu-system") or lower.startswith("libqemu"):
        return "Android SDK / emulator binary (downloaded on the user's machine)"
    if lower.startswith("kernel-ranchu") or lower == "kernel-qemu":
        return "emulator kernel (system image component)"
    if lower.endswith(".img") and any(word in lower for word in image_words):
        return "Android system image"
    if lower in ("source.properties", "package.xml"):
        return "Android SDK package metadata"
    return None


def classify_content(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(64 * 1024)
    except OSError:
        return None

    def starts(magic):
        return head.startswith(magic)

    if starts(b"\x7fELF"):
        return "ELF binary (Android/Linux code has no place in the app)"
    if starts(b"ANDROID!") or starts(b"VNDRBOOT"):
        return "Android boot image"
    if starts(bytes([0x3A, 0xFF, 0x26, 0xED])):
        return "Android sparse image"
    if len(head) >= 1082 and head[1080:1082] == bytes([0x53, 0xEF]):
        return "ext4 filesystem image"
    if starts(bytes([0x02, 0x21, 0x4C, 0x18])) or starts(b"070701") or starts(b"070702"):
        return "ramdisk (lz4 or cpio)"
    if starts(b"dex\n"):
        return "Android dex bytecode"
    if starts(b"PK\x03\x04") and b"AndroidManifest.xml" in head:
        return "Android APK"
    return None


findings = []
files = directories = 0
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    directories += 1
    for name in dirnames:
        reason = classify_name(name)
        if reason:
            findings.append((os.path.join(dirpath, name), reason))
    for name in filenames:
        full = os.path.join(dirpath, name)
        if os.path.islink(full):
            continue
        files += 1
        reason = classify_name(name) or classify_content(full)
        if reason:
            findings.append((full, reason))

for path, reason in sorted(findings):
    print(f"  FORBIDDEN {path}: {reason}")
if findings:
    print(f"scan failed: {len(findings)} forbidden file(s)")
    sys.exit(1)
print(f"  scan ok: {files} files, {directories} directories, no Google SDK, system image or Magisk content")
PY

# --- isolated launch ------------------------------------------------------
step "Isolated launch check"
if [ "${JIDR_SKIP_GUI_TEST:-0}" = "1" ]; then
    note "launch: NOT EXECUTED (JIDR_SKIP_GUI_TEST=1); recorded as 未执行, not as a pass"
else
    tmp_home="$(mktemp -d /tmp/jidr-pkg.XXXXXX)"
    # Finder-style launch: no JIDR_HOME. The bundle's sentinel makes the app use its own
    # data directory, which must be empty before the run and removed afterwards.
    test_home="$HOME/Library/Application Support/Jidr-SwiftUI-Test"
    case "$test_home" in
        "$HOME/Library/Application Support/Jidr-SwiftUI-Test") rm -rf -- "$test_home" ;;
        *) die "refusing to clean an unexpected test home: $test_home" ;;
    esac
    # Copy out of the read-only DMG exactly as a user would.
    ditto "$mounted_app" "$tmp_home/JidrSwiftUICenter.app"
    launch_app="$tmp_home/JidrSwiftUICenter.app"
    codesign --verify --strict "$launch_app" >/dev/null 2>&1 ||
        die "signature does not verify after copying the app out of the DMG"
    log="$tmp_home/center.log"
    real_data="$HOME/Library/Application Support/Jidr"
    real_before="$(stat -f '%m' "$real_data" 2>/dev/null || echo absent)"
    socket="$test_home/data/daemon.sock"
    [ ! -e "$socket" ] || die "the isolated test home already has a daemon socket: $socket"
    # No JIDR_HOME and no JIDR_DAEMON_BIN: the packaged app must find its Helpers and
    # choose its own isolated data directory, exactly as a Finder double-click would.
    env -u JIDR_HOME -u JIDR_DAEMON_BIN \
        "$launch_app/Contents/MacOS/JidrSwiftUICenter" >"$log" 2>&1 &
    app_pid=$!
    started=0
    for _ in $(seq 1 60); do
        if [ -S "$socket" ]; then
            started=1
            break
        fi
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.5
    done
    if ! kill -0 "$app_pid" 2>/dev/null; then
        note "center stderr:"
        sed 's/^/  /' "$log" >&2 || true
        die "the packaged center exited during startup"
    fi
    if [ "$started" -ne 1 ]; then
        note "center stderr:"
        sed 's/^/  /' "$log" >&2 || true
        die "the daemon socket $socket did not appear (no auto-start)"
    fi
    note "center running: pid $app_pid"
    note "daemon socket appeared: $socket"
    descendants() {
        local parent="$1" depth="${2:-0}" child
        [ "$depth" -ge 6 ] && return 0
        for child in $(pgrep -P "$parent" 2>/dev/null || true); do
            printf '%s\n' "$child"
            descendants "$child" "$((depth + 1))"
        done
    }
    descendants_of_center="$(descendants "$app_pid")"
    bridge_pid=""
    daemon_pid=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        command_line="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        case "$command_line" in
            *jidr-center-bridge*) bridge_pid="$candidate" ;;
            *"jidr daemon"*) daemon_pid="$candidate" ;;
        esac
    done <<< "$descendants_of_center"
    [ -n "$bridge_pid" ] || die "no jidr-center-bridge process under the center (the bundled bridge did not start)"
    [ -n "$daemon_pid" ] || die "no 'jidr daemon' process for the isolated home (the bundled daemon did not auto-start)"
    center_command="$(ps -p "$app_pid" -o command= 2>/dev/null || true)"
    bridge_command="$(ps -p "$bridge_pid" -o command= 2>/dev/null || true)"
    daemon_command="$(ps -p "$daemon_pid" -o command= 2>/dev/null || true)"
    note "center command: $center_command"
    note "center bridge command: $bridge_command"
    note "daemon command: $daemon_command"
    [ "$center_command" = "$launch_app/Contents/MacOS/JidrSwiftUICenter" ] ||
        die "the center was not started in bundle-discovery mode: $center_command"
    case "$bridge_command" in
        "$launch_app/Contents/Helpers/jidr-center-bridge"*) ;;
        *) die "the center bridge did not come from Contents/Helpers: $bridge_command" ;;
    esac
    case "$daemon_command" in
        "$launch_app/Contents/Helpers/jidr daemon"*) ;;
        *) die "the daemon did not come from Contents/Helpers/jidr: $daemon_command" ;;
    esac
    note "helper discovery: center bridge and daemon both came from Contents/Helpers"
    status_out="$(JIDR_HOME="$test_home" "$launch_app/Contents/Helpers/jidr" --json daemon status 2>&1)" ||
        die "the packaged CLI cannot reach the daemon: $status_out"
    printf '  daemon status: %s\n' "$(printf '%s' "$status_out" | head -c 400)"
    [ -f "$test_home/logs/daemon.log" ] && note "daemon log: $(wc -l < "$test_home/logs/daemon.log" | tr -d ' ') line(s)"

    # Orderly stop of the test daemon and the app; only processes for this home.
    JIDR_HOME="$test_home" "$launch_app/Contents/Helpers/jidr" daemon stop >/dev/null 2>&1 || true
    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -KILL "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        kill -TERM "$candidate" 2>/dev/null || true
    done <<< "$descendants_of_center"
    sleep 1
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        kill -KILL "$candidate" 2>/dev/null || true
    done <<< "$descendants_of_center"

    real_after="$(stat -f '%m' "$real_data" 2>/dev/null || echo absent)"
    if [ "$real_before" = "$real_after" ]; then
        note "real ~/Library/Application Support/Jidr untouched (mtime unchanged)"
    else
        note "warning: ~/Library/Application Support/Jidr mtime changed during the test (${real_before} -> ${real_after})"
    fi
    note "launch ok: Finder-style start used $test_home, found Contents/Helpers, auto-started the daemon and reached it"
    rm -rf -- "$test_home"
    note "test home removed: $test_home"
fi

# --- summary --------------------------------------------------------------
step "Package ready"
printf '  app:    %s\n' "$app"
printf '  dmg:    %s\n' "$dmg"
printf '  sha256: %s\n' "$sha"
printf '  sums:   %s\n' "$out/SHA256SUMS.txt"
note "the app and DMG are under target/; the installed Jidr.app was not touched"
