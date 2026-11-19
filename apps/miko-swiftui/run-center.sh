#!/bin/bash
# Launch the development preview from the invoking user's session and environment.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "${MIKO_HOME:-}" != /* ]]; then
  printf '%s\n' 'Set MIKO_HOME to an absolute, isolated test directory.' >&2
  exit 2
fi
center="$root/target/swiftui-center/miko simulator.app/Contents/MacOS/Miko"
center_bridge="$root/target/debug/miko-center-bridge"
player_bridge="$root/target/debug/miko-swiftui-bridge"
export MIKO_DAEMON_BIN="${MIKO_DAEMON_BIN:-$root/target/debug/miko}"
for executable in "$center" "$center_bridge" "$player_bridge" "$MIKO_DAEMON_BIN"; do
  if [[ ! -x "$executable" ]]; then
    printf 'Missing executable: %s\n' "$executable" >&2
    exit 1
  fi
done
exec "$center" "$center_bridge" "$player_bridge"
