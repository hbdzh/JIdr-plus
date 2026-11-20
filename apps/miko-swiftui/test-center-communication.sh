#!/bin/bash
# Opens an isolated GUI window with a fake bridge; never connects to user devices.
set -euo pipefail
if [[ "${1:-}" != --interactive || "$#" != 1 ]]; then
  echo 'This suite opens a test window. Use --interactive when a GUI session is available.' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
out="$root/target/swiftui-center-communication"
mkdir -p "$out/module-cache"
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] || center_sources+=("$file")
done
swiftc -O -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
  "$root"/apps/miko-swiftui/Sources/*.swift "${center_sources[@]}" \
  "$root/apps/miko-swiftui/Tests/CenterCommunication/main.swift" -o "$out/center-communication-tests"
test_home="$(mktemp -d "${TMPDIR:-/tmp}/miko-center-communication.XXXXXX")"
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/data"
cp "$root/apps/miko-swiftui/Tests/CenterCommunication/fixture.py" "$test_home/fixture"
chmod +x "$test_home/fixture"
MIKO_HOME="$test_home" "$out/center-communication-tests" "$test_home/fixture"
