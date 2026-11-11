#!/bin/bash
# Source after setting root to the repository root. The production bundle's
# minimum version is also the compiler deployment target, independent of the
# SDK/host version or an inherited MACOSX_DEPLOYMENT_TARGET.
jidr_minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$root/packaging/swiftui/Jidr-Info.plist.in")"
# Match the native Rust helpers (production is arm64; CI may run on Intel).
jidr_swift_target="$(uname -m)-apple-macosx${jidr_minimum_macos}"
