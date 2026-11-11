#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# M4-C live UI evidence: build the offscreen renderer, run a real isolated
# daemon + one-shot emulator, and capture the device center and player window.
#
#   bash apps/jidr-swiftui/render-live.sh --self-test
#       Harness smoke test with the deterministic bridge fixtures: no daemon,
#       no emulator, no SDK needed. Writes target/m4/selftest/*.
#
#   bash apps/jidr-swiftui/render-live.sh [--sdk /tmp/m4-sdk]
#       Real evidence. Creates its own JIDR_HOME under /tmp, creates and boots
#       a one-shot AVD from the given SDK, renders target/m4/live-*.png and
#       target/m4/evidence.txt, then stops/deletes the device and daemon.
#
#   bash apps/jidr-swiftui/render-live.sh --verify
#       Re-check the captured files/evidence without a device.
#
# The user's ~/Library/Application Support/Jidr, Android Studio SDK and
# ~/.android/avd are never touched: JIDR_HOME and ANDROID_HOME are explicit and
# the emulator runs with Jidr's own ANDROID_AVD_HOME under JIDR_HOME.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

mode=live
sdk="${M4_SDK:-/tmp/m4-sdk}"
keep_home=0
device_name=""
boot_timeout="${M4_BOOT_TIMEOUT:-420}"
out="$root/target/m4"

usage() {
  cat <<'USAGE'
M4-C live UI evidence: offscreen captures against a real daemon + emulator.

  bash apps/jidr-swiftui/render-live.sh --self-test
      Harness smoke test with deterministic fixtures (no daemon, no emulator,
      no SDK). Writes target/m4/selftest/*.

  bash apps/jidr-swiftui/render-live.sh [--sdk /tmp/m4-sdk]
      Real evidence: isolated JIDR_HOME under /tmp, one-shot AVD, renders
      target/m4/live-*.png + evidence.txt, then stops/deletes device + daemon.
      Options: --device-name NAME, --boot-timeout SECONDS, --keep (keep HOME).

  bash apps/jidr-swiftui/render-live.sh --verify
      Re-check target/m4 captures/evidence without a device.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) mode=self-test ;;
    --verify) mode=verify ;;
    --sdk) sdk="${2:?--sdk needs a path}"; shift ;;
    --device-name) device_name="${2:?--device-name needs a name}"; shift ;;
    --keep) keep_home=1 ;;
    --boot-timeout) boot_timeout="${2:?--boot-timeout needs seconds}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "render-live: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

fail() { echo "render-live: $*" >&2; exit 1; }

# --- build helpers ---------------------------------------------------------

prepare() {
  mkdir -p "$out" "$out/module-cache"
  if [[ ! -x target/debug/jidr ]] || [[ ! -x target/debug/jidr-center-bridge ]] || [[ ! -x target/debug/jidr-swiftui-bridge ]]; then
    echo "render-live: building Rust helpers (jidr, bridges)"
    cargo build -q -p jidr --bin jidr || fail "cargo build -p jidr failed"
    cargo build -q -p jidr-swiftui-bridge || fail "cargo build -p jidr-swiftui-bridge failed"
  fi
  local center_sources=()
  local file
  for file in "$root"/apps/jidr-swiftui/Center/*.swift; do
    [[ "$(basename "$file")" == "main.swift" ]] && continue
    center_sources+=("$file")
  done
  echo "render-live: compiling offscreen renderer"
  swiftc -module-cache-path "$out/module-cache" \
    "$root"/apps/jidr-swiftui/Sources/*.swift \
    "${center_sources[@]}" \
    "$root"/apps/jidr-swiftui/Tests/LiveRender/main.swift \
    -o "$out/live-render" || fail "swiftc failed"
}

# --- output verification ---------------------------------------------------

verify_outputs() {
  local directory="$1"
  local evidence="$2"
  python3 - "$directory" "$evidence" <<'PY'
import struct, sys
from pathlib import Path

directory = Path(sys.argv[1])
evidence = Path(sys.argv[2])
expected = [
    ("live-center-1000x640.png", 1000, 640),
    ("live-center-820x600.png", 820, 600),
    ("live-player-432x768.png", 432, 768),
]
problems = []
for name, width, height in expected:
    path = directory / name
    if not path.is_file():
        problems.append(f"missing {path}")
        continue
    data = path.read_bytes()
    if len(data) < 20_000:
        problems.append(f"{path} is too small ({len(data)} bytes)")
        continue
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        problems.append(f"{path} is not a PNG")
        continue
    if data[12:16] != b"IHDR":
        problems.append(f"{path} has no IHDR")
        continue
    actual_width, actual_height = struct.unpack(">II", data[16:24])
    if (actual_width, actual_height) != (width, height):
        problems.append(f"{path} is {actual_width}x{actual_height}, expected {width}x{height}")
        continue
    print(f"  OK {name} {width}x{height} {len(data)} bytes")
if not evidence.is_file():
    problems.append(f"missing evidence file {evidence}")
else:
    text = evidence.read_text()
    for marker in ("Jidr M4-C offscreen UI evidence", "assertions: PASS",
                   "player_first_frame_ms=", "sha256="):
        if marker not in text:
            problems.append(f"{evidence} lacks marker {marker!r}")
    if "device: name=" not in text or "serial=" not in text:
        problems.append(f"{evidence} lacks the device name/serial line")
    print(f"  OK {evidence.name} ({len(text)} characters)")
if problems:
    for problem in problems:
        print(f"FAIL {problem}")
    sys.exit(1)
print("VERIFY PASSED")
PY
}

# --- evidence summary ------------------------------------------------------

write_summary() {
  local evidence="$1"
  local summary="$out/evidence-summary.md"
  python3 - "$evidence" "$summary" "$out" <<'PY_INSIDE'
import sys
from pathlib import Path

evidence_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
out = Path(sys.argv[3])
lines = evidence_path.read_text().splitlines()
images = sorted(p for p in out.glob("live-*.png"))
rows = []
for line in lines:
    if line.startswith(("device:", "            ", "apps:", "timings:", "environment:")):
        rows.append(line.rstrip())
if not images:
    print("no live-*.png files to summarise", file=sys.stderr)
    sys.exit(1)
summary = [
    "# M4-C live SwiftUI evidence summary",
    "",
    "Generated from `evidence.txt` by `render-live.sh` (offscreen NSHostingView captures; no screen-recording permission needed).",
    "",
    "## Device and timings",
    "```",
    *rows,
    "```",
    "",
    "## Screenshots",
    "| file | size (bytes) |",
    "|---|---:|",
]
for image in images:
    summary.append(f"| `{image.name}` | {image.stat().st_size} |")
summary += ["", "Full details, sha256 and per-step timings: `evidence.txt`; renderer log: `live-render.log`.", ""]
summary_path.write_text("\n".join(summary))
print(f"render-live: wrote {summary_path}")
PY_INSIDE
}

# --- self-test (fixtures; no daemon/emulator) ------------------------------

run_self_test() {
  prepare
  echo "render-live: self-test with fixture bridges (no daemon, no emulator)"
  "$out/live-render" --self-test \
    --center-bridge "$root/target/debug/jidr-center-bridge" \
    --player-bridge "$root/target/debug/jidr-swiftui-bridge" \
    --out "$out" --fonts "$root/target/swiftui-center/Jidr.app/Contents/Resources/fonts" \
    || fail "self-test renderer failed"
  verify_outputs "$out/selftest" "$out/selftest/evidence-selftest.txt"
  echo "SELF-TEST PASSED: target/m4/selftest/{live-center-1000x640.png,live-center-820x600.png,live-player-432x768.png,evidence-selftest.txt}"
}

# --- live (real daemon + real emulator) ------------------------------------

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ "${live_started:-0}" == "1" ]]; then
    echo "render-live: cleaning up device and daemon"
    "$root/target/debug/jidr" -q device stop --all >/dev/null 2>&1
    "$root/target/debug/jidr" -q device delete --all -y >/dev/null 2>&1
    "$root/target/debug/jidr" -q daemon stop >/dev/null 2>&1
  fi
  # Keep the isolated home (daemon/emulator logs) when the run failed, so a
  # failure can be diagnosed without re-running the device.
  if [[ "$keep_home" == "0" && "${run_ok:-0}" == "1" && -n "${home:-}" && -d "$home" ]]; then
    rm -rf "$home"
  elif [[ -n "${home:-}" ]]; then
    echo "render-live: kept isolated home for diagnosis: $home"
  fi
  if [[ "$status" != "0" ]]; then
    echo "render-live: FAILED (exit $status); see target/m4/live-render.log and the kept home above" >&2
  fi
}

run_live() {
  [[ -x "$sdk/emulator/emulator" ]] || fail "no emulator at $sdk/emulator/emulator (use --sdk)"
  [[ -x "$sdk/platform-tools/adb" ]] || fail "no adb at $sdk/platform-tools/adb (use --sdk)"
  prepare
  home="${M4_JIDR_HOME:-$(mktemp -d /tmp/jidr-m4-live.XXXXXX)}"
  case "$home" in
    /tmp/*) ;;
    *) fail "JIDR_HOME must be under /tmp, got $home" ;;
  esac
  mkdir -p "$home"
  export JIDR_HOME="$home"
  export ANDROID_HOME="$sdk"
  export JIDR_TEST_SDK="$sdk"
  export JIDR_DAEMON_BIN="$root/target/debug/jidr"
  echo "render-live: JIDR_HOME=$JIDR_HOME ANDROID_HOME=$ANDROID_HOME"
  live_started=1
  trap cleanup EXIT INT TERM

  local name="${device_name:-M4-UI-$(date +%H%M%S)}"
  local image
  image=$(target/debug/jidr --json image list | python3 -c '
import json, sys
try:
    result = json.load(sys.stdin)["result"]
except Exception:
    sys.exit(0)
installed = [i for i in result if i.get("installed_in")]
if installed:
    first = installed[0]
    print("%s:%s:%s" % (first["api"], first["tag"], first["abi"]))
')
  [[ -n "$image" ]] || fail "no installed system image found in $sdk (checked jidr image list)"
  echo "render-live: creating one-shot device $name from image $image"
  local create_start create_end boot_start boot_end
  create_start=$(python3 -c 'import time; print(int(time.time()*1000))')
  target/debug/jidr -q device create "$name" -i "$image" || fail "device create failed"
  create_end=$(python3 -c 'import time; print(int(time.time()*1000))')
  echo "render-live: booting $name (timeout ${boot_timeout}s)"
  boot_start=$(python3 -c 'import time; print(int(time.time()*1000))')
  target/debug/jidr -q device start "$name" --timeout "$boot_timeout" || fail "device start failed (see $JIDR_HOME/logs and target/m4/live-render.log)"
  boot_end=$(python3 -c 'import time; print(int(time.time()*1000))')
  echo "render-live: device created in $((create_end-create_start)) ms, booted in $((boot_end-boot_start)) ms"

  "$out/live-render" \
    --center-bridge "$root/target/debug/jidr-center-bridge" \
    --player-bridge "$root/target/debug/jidr-swiftui-bridge" \
    --device "$name" --out "$out" \
    --create-ms "$((create_end-create_start))" --boot-ms "$((boot_end-boot_start))" \
    --fonts "$root/target/swiftui-center/Jidr.app/Contents/Resources/fonts" \
    2>&1 | tee "$out/live-render.log"
  local status="${PIPESTATUS[0]}"
  [[ "$status" == "0" ]] || fail "live renderer failed (log: target/m4/live-render.log)"
  verify_outputs "$out" "$out/evidence.txt"
  write_summary "$out/evidence.txt"
  run_ok=1
  echo "LIVE EVIDENCE PASSED: target/m4/live-center-1000x640.png target/m4/live-center-820x600.png target/m4/live-player-432x768.png target/m4/evidence.txt"
}

case "$mode" in
  self-test) run_self_test ;;
  verify)
    verify_outputs "$out" "$out/evidence.txt"
    ;;
  live) run_live ;;
esac
