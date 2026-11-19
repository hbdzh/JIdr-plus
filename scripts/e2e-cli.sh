#!/usr/bin/env bash
# End-to-end CLI run on a real emulator, non-interactive, JSON everywhere:
# create → start (wait for boot) → install → stop → delete → daemon stop.
#
# Env: MIKO_TEST_SDK (SDK holding the image, read-only; default Studio's),
#      MIKO_TEST_IMAGE (sdkmanager package; default API 31 google_apis, host ABI),
#      MIKO_TEST_APK (APK to install; default a sample app from the SDK's images).
set -euo pipefail
cd "$(dirname "$0")/.."

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}"
cargo build -q -p miko
# CARGO_TARGET_DIR may be absolute (CI, `cargo xtask e2e-mac` callers) or relative.
case "$CARGO_TARGET_DIR" in /*) TARGET="$CARGO_TARGET_DIR" ;; *) TARGET="$PWD/$CARGO_TARGET_DIR" ;; esac
MIKO="$TARGET/debug/miko"

case "$(uname -m)" in arm64|aarch64) ABI=arm64-v8a ;; *) ABI=x86_64 ;; esac
SDK="${MIKO_TEST_SDK:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
export ANDROID_HOME="$SDK"
IMAGE="${MIKO_TEST_IMAGE:-system-images;android-31;google_apis;$ABI}"
APK="${MIKO_TEST_APK:-$(find "$SDK/system-images" -path '*/data/app/*' -name '*.apk' 2>/dev/null | head -1 || true)}"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "e2e-cli: no APK to install; set MIKO_TEST_APK" >&2
  exit 1
fi

# A short, private Miko home (Unix socket paths are limited to ~104 bytes).
MIKO_HOME="$(mktemp -d /tmp/miko-e2e.XXXXXX)"
export MIKO_HOME
cleanup() {
  # Stops devices, the daemon and any leftover emulator of this run, even
  # after a failure or Ctrl-C (scratch HOME: real MCP configs untouched).
  mkdir -p "$MIKO_HOME/cleanup-home"
  HOME="$MIKO_HOME/cleanup-home" "$MIKO" --quiet uninstall --purge --yes >/dev/null 2>&1 || true
  "$MIKO" daemon stop >/dev/null 2>&1 || true
  rm -rf "$MIKO_HOME"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Runs `miko --json …`, checks the exit code and that ok == true, prints the result.
step() {
  local name="$1"; shift
  local out code=0
  out="$("$MIKO" --json "$@")" || code=$?
  if [ "$code" -ne 0 ]; then
    echo "e2e-cli: FAIL $name (exit $code): $out" >&2
    exit 1
  fi
  python3 -I -c 'import json,sys; v=json.loads(sys.stdin.read().strip().splitlines()[-1]); assert v["miko_json"]==2 and v["ok"] is True, v' <<<"$out" \
    || { echo "e2e-cli: FAIL $name: bad envelope: $out" >&2; exit 1; }
  echo "e2e-cli: ok   $name"
  LAST="$out"
}

field() {  # field <python expression on r = result>
  python3 -I -c "import json,sys; r=json.loads(sys.stdin.read().strip().splitlines()[-1])['result']; print($1)" <<<"$LAST"
}

start=$(date +%s)
step "create"   device create e2e --image "$IMAGE" --profile small-phone-5
step "start"    device start e2e --timeout 300
[ "$(field 'r[0]["status"]["state"]')" = running ] || { echo "e2e-cli: FAIL not running: $LAST" >&2; exit 1; }
echo "e2e-cli:      booted on $(field 'r[0]["runtime"]["adb_serial"]') after $(( $(date +%s) - start )) s"
step "install"  install e2e "$APK"
step "logcat"   logcat e2e -n 20
step "stop"     device stop e2e
step "delete"   device delete e2e --yes
step "list"     device list
[ "$(field 'len(r)')" = 0 ] || { echo "e2e-cli: FAIL device left behind: $LAST" >&2; exit 1; }

# Uninstall --purge (D31) with HOME pointed at a scratch dir, so the real MCP
# configs are never touched; a fake Claude Code config proves the cleanup.
step "create2"  device create e2e2 --image "$IMAGE" --profile small-phone-5
step "start2"   device start e2e2 --timeout 300
FAKE_HOME="$MIKO_HOME/home"
mkdir -p "$FAKE_HOME"
printf '{"mcpServers":{"miko":{"command":"miko","args":["mcp"]},"other":{"command":"x"}}}' > "$FAKE_HOME/.claude.json"
LAST="$(HOME="$FAKE_HOME" "$MIKO" --json uninstall --purge --yes)" || { echo "e2e-cli: FAIL uninstall: $LAST" >&2; exit 1; }
echo "e2e-cli: ok   uninstall --purge"
[ "$(field 'r["purged"]')" = True ] || { echo "e2e-cli: FAIL not purged: $LAST" >&2; exit 1; }
for d in data cache logs; do
  [ ! -e "$MIKO_HOME/$d" ] || { echo "e2e-cli: FAIL $MIKO_HOME/$d remains" >&2; exit 1; }
done
python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); assert "miko" not in c["mcpServers"] and "other" in c["mcpServers"], c' "$FAKE_HOME/.claude.json" \
  || { echo "e2e-cli: FAIL MCP entry not removed" >&2; exit 1; }
[ ! -S "$MIKO_HOME/data/daemon.sock" ] || { echo "e2e-cli: FAIL daemon socket remains" >&2; exit 1; }
# No emulator may still be running a Miko AVD.
python3 -I "$(dirname "$0")/lib/no_miko_emulators.py" "$MIKO_HOME" \
  || { echo "e2e-cli: FAIL a Miko emulator is still running" >&2; exit 1; }
echo "e2e-cli: passed in $(( $(date +%s) - start )) s"
