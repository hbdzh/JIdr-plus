#!/usr/bin/env bash
# Developer ID signing and notarization (Phase 12b, D32). `cargo xtask release`
# runs it when MIKO_SIGNING_IDENTITY is set: `app` before the DMG is built,
# `dmg` after.
#
#   packaging/macos/sign.sh app miko simulator.app        # hardened runtime, inside-out
#   packaging/macos/sign.sh dmg Miko-X-arm64.dmg # sign, notarize, staple
#
# Environment:
#   MIKO_SIGNING_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"
#   NOTARY_KEY_PATH         App Store Connect API key (.p8) for notarytool
#   NOTARY_KEY_ID           its key ID
#   NOTARY_ISSUER_ID        its issuer ID
set -euo pipefail

die() { echo "sign.sh: $*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "$1 is not set"; }

[ $# -eq 2 ] || die "usage: sign.sh app <miko simulator.app> | sign.sh dmg <file.dmg>"
kind=$1 target=$2
[ -e "$target" ] || die "$target does not exist"
need MIKO_SIGNING_IDENTITY

sign() {
    codesign --force --timestamp --options runtime \
        --sign "$MIKO_SIGNING_IDENTITY" "$@"
}

# Stapling downloads the notarization ticket from Apple's CDN (CloudKit), and
# a transient connection failure there can fail a release after Apple has
# already accepted the DMG (error 68). Notarization doesn't need repeating,
# so retry only the staple, then confirm the ticket is attached.
staple() {
    local attempt
    for attempt in 1 2 3 4; do
        if xcrun stapler staple "$1"; then
            xcrun stapler validate "$1"
            return
        fi
        [ "$attempt" -eq 4 ] && break
        echo "sign.sh: staple failed (attempt $attempt of 4), retrying in $((attempt * 15))s" >&2
        sleep $((attempt * 15))
    done
    die "stapling $1 failed 4 times. Apple already accepted it: run xcrun stapler staple on the DMG again, or rerun the release job"
}

case "$kind" in
    app)
        # Inside-out: nested executables first, then the bundle. No --deep.
        sign "$target/Contents/Helpers/miko"
        sign "$target/Contents/MacOS/Miko"
        sign "$target"
        codesign --verify --strict --verbose=2 "$target"
        ;;
    dmg)
        need NOTARY_KEY_PATH
        need NOTARY_KEY_ID
        need NOTARY_ISSUER_ID
        [ -f "$NOTARY_KEY_PATH" ] || die "NOTARY_KEY_PATH $NOTARY_KEY_PATH does not exist"
        sign "$target"
        result=$(xcrun notarytool submit "$target" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait 2>&1) || die "notarytool failed: $result"
        echo "$result"
        # Check Apple's verdict, not only notarytool's exit code.
        grep -q "status: Accepted" <<<"$result" \
            || die "notarization was not accepted; run 'xcrun notarytool log <id>' with the same key for details"
        staple "$target"
        ;;
    *)
        die "unknown kind '$kind' (app or dmg)"
        ;;
esac
echo "sign.sh: $kind signed: $target"
