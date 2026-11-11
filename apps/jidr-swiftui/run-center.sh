#!/bin/bash
# Launch the development preview from the invoking user's session and environment.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "${JIDR_HOME:-}" != /* ]]; then
  printf '%s\n' 'Set JIDR_HOME to an absolute, isolated test directory.' >&2
  exit 2
fi
center="$root/target/swiftui-center/JidrSwiftUICenter.app/Contents/MacOS/JidrSwiftUICenter"
center_bridge="$root/target/debug/jidr-center-bridge"
player_bridge="$root/target/debug/jidr-swiftui-bridge"
export JIDR_DAEMON_BIN="${JIDR_DAEMON_BIN:-$root/target/debug/jidr}"
for executable in "$center" "$center_bridge" "$player_bridge" "$JIDR_DAEMON_BIN"; do
  if [[ ! -x "$executable" ]]; then
    printf 'Missing executable: %s\n' "$executable" >&2
    exit 1
  fi
done
exec "$center" "$center_bridge" "$player_bridge"
