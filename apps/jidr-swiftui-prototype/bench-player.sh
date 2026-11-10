#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# M4-B: measure the SwiftUI player path and run the Slint A/B on the same device.
#
# The harness (Tests/Bench/main.swift) consumes the same `jidr-swiftui-bridge`
# JFR1 frames as the SwiftUI player, through Sources/FrameDecoder.swift and the
# ADR-0001 newest-frame slot / one UI-hop pipeline, then draws with the same
# AppKit view code as ScreenView. It measures:
#   * 10 s of frame rate: received / presented (UI hop) / displayed (draws) and MB/s;
#   * touch -> changed-frame latency, ADR-0001 method: `dev.set show_taps`, home
#     screen, 30 taps, first presented frame whose probe patch changed.
#   * frame-rate phases use a scrollable Settings scene: the SwiftUI harness
#     injects ADR-0001 alternating 300 ms drags through the player bridge; the
#     read-only Slint display_bench gets a neutral adb swipe driver because it
#     never sends input (streamScreenshot only sends new frames).
# bench-player.sh then runs the Slint baseline
#   cargo run -p jidr-ui --example display_bench -- "<device>"
# on the same device, window size (340x752) and scene (home screen), records both
# numbers plus machine/device/emulator metadata, writes JSON artifacts and
# compares against the ADR-0001 targets: displayed fps >= 55 (median),
# latency <= 80 ms (median), and no worse than the Slint baseline by > 10%.
#
# Requirements: macOS with a GUI session, an absolute isolated JIDR_HOME under
# /tmp, a running device whose daemon/SDK are reachable through ANDROID_HOME
# (e.g. ANDROID_HOME=/tmp/m4-sdk). It never writes the user's real Jidr data.
#
# Usage:
#   ANDROID_HOME=/tmp/m4-sdk JIDR_HOME=/tmp/jidr-m4-bench-XXXX \
#     bash apps/jidr-swiftui-prototype/bench-player.sh --device NAME [options]
#
# Options:
#   --device NAME          running device name or id (required unless --self-test)
#   --seconds N            frame-rate window (default 10)
#   --taps N               latency probes, 0 disables (default 30)
#   --quality 0|1|2        bridge stream quality (default 1)
#   --window WxH           benchmark window in points (default 340x752)
#   --probe X,Y            normalized probe point (default 0.5,0.55)
#   --probe-threshold F    RGB patch delta that counts as a change (default 30)
#   --no-probe-dump        do not save the detected probe frames/patches
#   --start-device         start the device if it is stopped
#   --no-fps-drive         do not inject the ADR-0001 scroll drags in the fps phase
#   --no-device-driver     do not run the adb swipe driver for the Slint baseline
#   --create               create the device when it does not exist
#   --image ID             image for --create (default 36:google_apis:arm64-v8a)
#   --no-slint             skip the Slint A/B run
#   --slint-only           only run the Slint baseline
#   --out-dir DIR          artifact directory (default target/m4)
#   --resummarize PREFIX   re-run the gate summary from saved artifacts
#                          (PREFIX-{player,slint,device}.json), no device needed
#   --cleanup-only         stop/delete the device and stop the daemon, then exit
#   --self-test            offline checks only (harness + script parsers)
#                          (test double: BENCH_SLINT_SCRIPT=path replaces the Slint
#                           command and BENCH_SLINT_CMD is not needed)
#   -h, --help
#
# Artifacts (target/m4/, all prefixed bench- so other lines' products are never
# touched): bench-<ts>.log, bench-<ts>-player.{json,log}, bench-<ts>-slint.{json,log},
# bench-<ts>-device.json, bench-<ts>-summary.json, bench-<ts>-emulator-cpu.txt and
# bench-<ts>-probe/ (first detected probe frames + patches). Re-run the same
# command to reproduce.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
outdir="${BENCH_OUT_DIR:-$root/target/m4}"
ts="$(date +%Y%m%d-%H%M%S)"
session_log=""   # set after argument parsing so --out-dir is honoured

JIDR="${JIDR_BIN:-$root/target/debug/jidr}"
BRIDGE="${PLAYER_BRIDGE:-$root/target/debug/jidr-swiftui-bridge}"
bench_bin="$outdir/bench-jidr-swiftui"
harness_src="$root/apps/jidr-swiftui-prototype/Tests/Bench/main.swift"
decoder_src="$root/apps/jidr-swiftui-prototype/Sources/FrameDecoder.swift"

device=""
seconds=10
taps=30
quality=1
window="340x752"
probe="0.5,0.55"
probe_threshold=30
dump_probe=1
start_device=0
cleanup_only=0
resummarize=""
create_device=0
fps_drive=1
device_driver=1
image="36:google_apis:arm64-v8a"
run_slint=1
run_swiftui=1
self_test=0

fps_gate=55
latency_gate=80
ab_ratio=90   # percent of the Slint baseline

log() { printf '%s\n' "$*" | tee -a "$session_log"; }
die() { printf 'bench-player: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR > 2 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="${2:-}"; shift 2 ;;
    --seconds) seconds="${2:-}"; shift 2 ;;
    --taps) taps="${2:-}"; shift 2 ;;
    --quality) quality="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    --probe) probe="${2:-}"; shift 2 ;;
    --probe-threshold) probe_threshold="${2:-}"; shift 2 ;;
    --no-probe-dump) dump_probe=0; shift ;;
    --start-device) start_device=1; shift ;;
    --no-fps-drive) fps_drive=0; shift ;;
    --no-device-driver) device_driver=0; shift ;;
    --create) create_device=1; shift ;;
    --cleanup-only) cleanup_only=1; shift ;;
    --resummarize) resummarize="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    --no-slint) run_slint=0; shift ;;
    --slint-only) run_swiftui=0; shift ;;
    --out-dir) outdir="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

outdir="${outdir%/}"
mkdir -p "$outdir" "$outdir/bench-module-cache"
session_log="$outdir/bench-$ts.log"
: > "$session_log"

check_home() {
  local home="$1"
  [[ -n "$home" ]] || die "JIDR_HOME is not set (use an absolute isolated directory under /tmp)"
  [[ "$home" = /* ]] || die "JIDR_HOME must be absolute: $home"
  case "$home" in
    "$HOME/Library/Application Support/JIdr"|"$HOME/Library/Application Support/JIdr/"*)
      die "refusing to use the real Jidr data directory as JIDR_HOME: $home" ;;
  esac
  case "$home" in
    /tmp/*|/private/tmp/*) ;;
    *) log "warning: JIDR_HOME is not under /tmp: $home" ;;
  esac
}

check_tools() {
  command -v swiftc >/dev/null || die "swiftc is required (Xcode command line tools)"
  command -v python3 >/dev/null || die "python3 is required"
  [[ -x "$JIDR" ]] || die "jidr binary not found: $JIDR (build it with: cargo build -p jidr)"
  [[ -x "$BRIDGE" ]] || die "player bridge not found: $BRIDGE (cargo build -p jidr-swiftui-bridge)"
  pgrep -x WindowServer >/dev/null || die "no GUI session (WindowServer is not running)"
}

compile_harness() {
  if [[ -n "${BENCH_HARNESS_BIN:-}" && -x "${BENCH_HARNESS_BIN:-}" ]]; then
    bench_bin="$BENCH_HARNESS_BIN"
    log "using prebuilt harness: $bench_bin (BENCH_HARNESS_BIN)"
    return
  fi
  log "compiling harness: swiftc (default -Onone, debug) Sources/FrameDecoder.swift Tests/Bench/main.swift"
  swiftc -module-cache-path "$outdir/bench-module-cache" "$decoder_src" "$harness_src" -o "$bench_bin" 2>&1 \
    | tee -a "$session_log"
}

# --- metadata helpers -------------------------------------------------------

# Print a compact JSON document from `jidr --json device details` and
# `device connect-info` (the token is dropped: never log secrets).
parse_meta() { # details.json connect.json JIDR_HOME emulator_pid emulator_cmd emulator_cpu_file
  python3 - "$@" <<'PY'
import json, sys

details_path, connect_path, home = sys.argv[1], sys.argv[2], sys.argv[3]
emulator_pid = sys.argv[4] if len(sys.argv) > 4 else ""
emulator_cmd = sys.argv[5] if len(sys.argv) > 5 else ""
cpu_path = sys.argv[6] if len(sys.argv) > 6 else ""

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except Exception:
        return {}
    if isinstance(value, dict) and isinstance(value.get("result"), dict):
        return value["result"]
    return value

details = load(details_path)
connect = load(connect_path)
device = details.get("device") if isinstance(details.get("device"), dict) else details
config = details.get("config") or {}
if not isinstance(config, dict):
    config = {}

def get(path, default=""):
    cur = device
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur if cur is not None else default

def number(value, default=0):
    try:
        return int(float(value))
    except Exception:
        return default

gpu = ""
if "-gpu " in f" {emulator_cmd} ":
    gpu = emulator_cmd.split("-gpu ", 1)[1].split()[0]

cpu = {"samples": 0, "avg_percent": None, "max_rss_mb": None}
if cpu_path:
    values = []
    rss = []
    try:
        for line in open(cpu_path, encoding="utf-8"):
            parts = line.split()
            if len(parts) >= 2:
                try:
                    values.append(float(parts[0]))
                    rss.append(int(parts[1]) / 1024.0)
                except ValueError:
                    pass
    except OSError:
        pass
    if values:
        cpu = {"samples": len(values),
               "avg_percent": round(sum(values) / len(values), 1),
               "max_rss_mb": round(max(rss), 1)}

width = number(config.get("hw.lcd.width"))
height = number(config.get("hw.lcd.height"))
out = {
    "name": get(("name",)),
    "id": get(("id",)),
    "status": get(("status", "state")),
    "image_api": get(("image", "api"), 0),
    "image_tag": get(("image", "tag")),
    "profile": get(("profile",)),
    "root_mode": get(("root", "mode")),
    "adb_serial": get(("runtime", "adb_serial")) or connect.get("adb_serial", ""),
    "sdk_root": get(("sdk_root",)),
    "panel": {"width": width, "height": height},
    "density": config.get("hw.lcd.density"),
    "ram_mb": config.get("hw.ramSize"),
    "cpus": config.get("hw.cpu.ncore"),
    "grpc_endpoint": connect.get("grpc_endpoint", ""),
    "grpc_port": connect.get("grpc_port", 0),
    "emulator_pid": number(emulator_pid),
    "emulator_gpu": gpu,
    "emulator_cmd": emulator_cmd,
    "emulator_cpu": cpu,
    "jidr_home": home,
    "config": {k: v for k, v in config.items() if k.startswith("hw.lcd.") or k in ("hw.ramSize", "hw.cpu.ncore")},
}
print(json.dumps(out, sort_keys=True))
PY
}

# Parse the visible interval of display_bench output into JSON.
parse_slint() { # slint.log
  python3 - "$@" <<'PY'
import json, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
line = ""
for candidate in text.splitlines():
    if candidate.startswith("visible: "):
        line = candidate
        break
if not line:
    print(json.dumps({"available": False, "reason": "no visible interval in display_bench output"}))
    sys.exit(0)
values = dict(re.findall(r"([A-Za-z_]+)=([^\s]+)", line))
def number(key):
    try:
        return float(values[key])
    except Exception:
        return None
print(json.dumps({
    "available": True,
    "raw": line,
    "seconds": number("seconds"),
    "received_fps": number("received_fps"),
    "shown_fps": number("shown_fps"),
    "mb_per_s": number("MB_per_s"),
    "cpu_percent": number("cpu_percent"),
}, sort_keys=True))
PY
}

# Compare the SwiftUI report with the ADR-0001 targets and the Slint baseline.
# Prints a human table and a JSON summary; exits 0 (pass), 7 (gate failed) or
# 8 (measurement unusable) unless called with --report-only.
summarize() { # meta.json swiftui.json slint.json mode
  python3 - "$@" <<'PY'
import json, sys

meta = json.load(open(sys.argv[1], encoding="utf-8"))
swift = json.load(open(sys.argv[2], encoding="utf-8"))
slint = json.load(open(sys.argv[3], encoding="utf-8")) if len(sys.argv) > 3 and sys.argv[3] != "-" else {}
mode = sys.argv[4] if len(sys.argv) > 4 else "both"

def number(value):
    if isinstance(value, (int, float)):
        return float(value)
    return None

fps = swift.get("fps") or {}
latency = swift.get("latency") or {}
presented = fps.get("median_presented_fps")
actual_draw = fps.get("median_displayed_fps")
displayed = presented if number(presented) is not None else actual_draw
received = fps.get("median_received_fps")
active = fps.get("active_fps_median")
mbps = fps.get("mb_per_s")
cpu = fps.get("cpu_percent")
bridge_cpu = fps.get("bridge_cpu_percent")
total_cpu = fps.get("total_cpu_percent")
lat_median = latency.get("median_ms")
lat_p90 = latency.get("p90_ms")
detected = latency.get("detected")
taps = latency.get("taps")

def fmt(value, suffix=""):
    v = number(value)
    return f"{v:.2f}{suffix}" if v is not None else "—"

fps_gate = 55.0
latency_gate = 80.0
ab_ratio = 0.90
slint_min_valid_fps = 30.0

checks = {}
requires_latency = bool(number(taps)) and number(taps) > 0
if mode != "slint-only":
    checks["displayed_fps_ge_55_median"] = number(displayed) is not None and number(displayed) >= fps_gate
    if requires_latency:
        checks["latency_median_le_80ms"] = number(lat_median) is not None and number(lat_median) <= latency_gate
        checks["all_taps_detected"] = number(detected) == number(taps)
slint_available = bool(slint.get("available")) and mode != "swiftui-only"
slint_shown = number(slint.get("shown_fps"))
slint_valid = (
    slint_available and slint_shown is not None and slint_shown >= slint_min_valid_fps
)
if slint_valid and mode != "slint-only":
    # Like-for-like A/B: both counters are "delivered to the UI hop"; the
    # SwiftUI draw count is reported separately as displayed fps.
    comparable = number(presented)
    checks["not_worse_than_slint_10pct"] = (
        slint_shown is not None and comparable is not None and comparable >= slint_shown * ab_ratio
    )

measurement_usable = mode == "slint-only" or (
    number(displayed) is not None and number(displayed) > 0
    and (not requires_latency or number(detected) is not None)
)
overall = measurement_usable and all(checks.values()) if checks else measurement_usable

table = [
    "M4-B SwiftUI player bench vs ADR-0001 / Slint",
    f"  device: {meta.get('name','?')}  image API {meta.get('image_api','?')} {meta.get('image_tag','')}"
    f"  panel {meta.get('panel',{}).get('width','?')}x{meta.get('panel',{}).get('height','?')}"
    f"  root {meta.get('root_mode','?')}",
    f"  emulator: gpu={meta.get('emulator_gpu','?') or '?'}  "
    f"cpu_avg={meta.get('emulator_cpu',{}).get('avg_percent','—')}%  "
    f"rss_max={meta.get('emulator_cpu',{}).get('max_rss_mb','—')} MB",
    "",
]
if mode != "slint-only":
    table += [
        f"  SwiftUI  received {fmt(received)} fps · presented/UI-hop {fmt(presented)} fps"
        f" · actual-draw {fmt(actual_draw)} fps · active-median {fmt(active)} fps · {fmt(mbps)} MB/s",
        f"  SwiftUI  CPU player {fmt(cpu)}% · bridge {fmt(bridge_cpu)}% · total {fmt(total_cpu)}%"
        f"  window {swift.get('window',{}).get('width','?')}x"
        f"{swift.get('window',{}).get('height','?')} pt  stream "
        f"{fps.get('stream_width','?')}x{fps.get('stream_height','?')}",
        f"  latency  median {fmt(lat_median,' ms')} · p90 {fmt(lat_p90,' ms')}"
        f" · {detected}/{taps} taps detected (show-taps probe, excludes OS input/scanout)",
        "",
    ]
if slint_valid:
    table += [
        f"  Slint    received {fmt(slint.get('received_fps'))} fps · shown {fmt(slint.get('shown_fps'))} fps"
        f" · {fmt(slint.get('mb_per_s'))} MB/s · CPU {fmt(slint.get('cpu_percent'))}%"
        f" (visible {fmt(slint.get('seconds'))} s)",
        f"  streams  SwiftUI {fps.get('stream_width','?')}x{fps.get('stream_height','?')} vs Slint"
        f" {meta.get('panel',{}).get('width',0) // 2}x{meta.get('panel',{}).get('height',0) // 2}"
        f" (display_bench requests native/2) — MB/s not directly comparable",
        "",
    ]
elif slint_available and mode != "swiftui-only":
    table += [
        f"  Slint    baseline INVALID: shown {fmt(slint.get('shown_fps'))} fps"
        f" (< {slint_min_valid_fps:.0f} fps; occluded window or static scene)",
        "           not used for the A/B gate",
        "  reference (not judged): docs/display-performance.md, same-model Mac, Slint debug,",
        "           2026-11-09: received 59.97 / shown 58.72 fps / 155.45 MB/s / CPU 61.3%, 540x1200 stream",
        "",
    ]
elif mode != "swiftui-only":
    table += ["  Slint    baseline unavailable", ""]
table.append("  gates:")
if checks:
    for name, passed in checks.items():
        table.append(f"    {'PASS' if passed else 'FAIL'}  {name}")
else:
    table.append("    (no SwiftUI gates in this mode)")
table.append(f"  result: {'PASS' if overall else 'FAIL'}")
print("\n".join(table))

summary = {
    "mode": mode,
    "device": meta,
    "scene": {
        "fps_phase": "scrollable scene (Settings list preferred; a failed app.launch falls back to the home launcher), "
                     "scrolled by bridge drags (SwiftUI, ADR-0001) / adb swipes (Slint)",
        "latency_phase": "home screen with dev.set show_taps",
    },
    "swiftui": {
        "fps": fps,
        "latency": latency,
        "cpu_percent": cpu,
        "exit_code": swift.get("exit_code"),
        "reason": swift.get("reason"),
    },
    "slint": {
        **slint,
        "valid_for_ab": slint_valid,
        "min_valid_fps": slint_min_valid_fps,
        "reference": {
            "source": "docs/display-performance.md (2026-11-09, same-model Mac, Slint debug)",
            "received_fps": 59.97,
            "shown_fps": 58.72,
            "mb_per_s": 155.45,
            "cpu_percent": 61.3,
            "stream": "540x1200",
            "note": "different date/build/scene; reference only, never a PASS/FAIL judgment",
        },
    },
    "gates": {
        "displayed_definition": "presented frames delivered to the UI hop (same counter as Slint shown); actual_draw_median_fps is the stricter NSView draw count",
        "displayed_ui_hop_median_fps": displayed,
        "actual_draw_median_fps": actual_draw,
        "displayed_fps_median_min": fps_gate,
        "latency_median_ms_max": latency_gate,
        "ab_ratio": ab_ratio,
        "checks": checks,
    },
    "measurement_usable": measurement_usable,
    "result": "PASS" if overall else "FAIL",
}
print("\nSUMMARY_JSON " + json.dumps(summary, sort_keys=True))
sys.exit(0 if overall else (8 if not measurement_usable else 7))
PY
}

# adb from the same read-only SDK the daemon uses; used only for the neutral
# swipe driver during the Slint display_bench baseline.
adb_path() {
  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/platform-tools/adb" ]]; then
    printf '%s\n' "$ANDROID_HOME/platform-tools/adb"
    return 0
  fi
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi
  return 1
}

# JSON params for the current device (avoid hand-built quoting bugs).
device_params() { # extra-json-fields
  local extra="${1:-}"
  [[ -n "$extra" ]] || extra="{}"
  python3 - "$device" "$extra" <<'PY'
import json, sys
device, extra = sys.argv[1], json.loads(sys.argv[2])
params = {"device": device}
params.update(extra)
print(json.dumps(params, sort_keys=True))
PY
}

# adb serial from the connect-info result (never re-expand JSON with `${x:-{}}`).
connect_serial() {
  local json="${connect_json:-}"
  [[ -n "$json" ]] || json="{}"
  printf '%s' "$json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("adb_serial",""))
except Exception: print("")'
}

# Opens a scrollable scene for the frame-rate phases.
open_scrollable_scene() {
  local params
  params="$(device_params '{"package":"com.android.settings"}')" || return 0
  log "opening Settings for the frame-rate phases (app.launch com.android.settings)"
  "$JIDR" --json call app.launch "$params" >/dev/null 2>>"$session_log" \
    || log "warning: app.launch com.android.settings failed; the fps phase may have no frame producer"
  sleep 1.5
}

send_home() {
  local params
  params="$(device_params '{"key":"home"}')" || return 0
  "$JIDR" --json call key.press "$params" >/dev/null 2>>"$session_log" || true
}

# A neutral frame producer for Slint display_bench: continuous swipes over the
# Settings list. The example itself never sends input, so without this the
# emulator has no reason to produce frames (streamScreenshot only sends new
# frames) and the baseline collapses to near-zero fps.
start_adb_driver() {
  [[ "$device_driver" == "1" ]] || { log "adb swipe driver disabled (--no-device-driver)"; return 0; }
  local adm serial
  adm="$(adb_path)" || { log "adb swipe driver unavailable (no adb in ANDROID_HOME/PATH)"; return 0; }
  serial="$(connect_serial 2>/dev/null || true)"
  [[ -n "$serial" ]] || { log "adb swipe driver unavailable (no adb serial)"; return 0; }
  "$adm" -s "$serial" get-state >/dev/null 2>&1 \
    || { log "adb swipe driver: '$serial' not reachable; skipping"; return 0; }
  adb_driver_stop="$(mktemp /tmp/jidr-m4-driver.XXXXXX)"
  rm -f "$adb_driver_stop"
  (
    while [[ ! -f "$adb_driver_stop" ]]; do
      "$adm" -s "$serial" shell input swipe 540 1700 540 700 220 >/dev/null 2>&1 || true
      "$adm" -s "$serial" shell input swipe 540 700 540 1700 220 >/dev/null 2>&1 || true
    done
  ) &
  adb_driver_pid=$!
  log "adb swipe driver running on $serial (pid $adb_driver_pid)"
}

stop_adb_driver() {
  if [[ -n "${adb_driver_pid:-}" ]]; then
    : > "$adb_driver_stop" 2>/dev/null || true
    kill "$adb_driver_pid" 2>/dev/null || true
    wait "$adb_driver_pid" 2>/dev/null || true
    adb_driver_pid=""
    rm -f "$adb_driver_stop"
    log "adb swipe driver stopped"
  fi
}

# Run the Slint A/B baseline and write $slint_log. Returns its exit code.
# BENCH_SLINT_SCRIPT (a path) replaces the cargo command for offline tests.
run_slint_baseline() {
  local slint_seconds="$seconds"
  (( slint_seconds > 60 )) && slint_seconds=60
  (( slint_seconds < 3 )) && slint_seconds=3
  if [[ -n "${BENCH_SLINT_SCRIPT:-}" ]]; then
    log "running Slint baseline test double: $BENCH_SLINT_SCRIPT"
    set +e
    "$BENCH_SLINT_SCRIPT" "$device" 2>&1 | tee -a "$session_log" "$slint_log"
    local rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
  fi
  log "running Slint baseline: cargo run -p jidr-ui --example display_bench -- \"$device\" (visible interval ${slint_seconds} s)"
  set +e
  ( cd "$root" && JIDR_DISPLAY_BENCH_SECS="$slint_seconds" \
      cargo run -p jidr-ui --example display_bench -- "$device" ) 2>&1 \
    | tee -a "$session_log" "$slint_log"
  local rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# --- offline self-test ------------------------------------------------------

run_self_test() {
  local tmp="$outdir/bench-selftest-$ts"
  mkdir -p "$tmp"
  log "self-test: compiling harness"
  compile_harness
  log "self-test: harness offline checks"
  "$bench_bin" --self-test | tee -a "$session_log"

  log "self-test: offline measured run (mock bridge, no daemon/device)"
  local mock="$tmp/mock-bridge"
  swiftc "$root/apps/jidr-swiftui-prototype/Tests/Bench/mock-bridge.swift" -o "$mock" 2>&1 \
    | tee -a "$session_log"
  pgrep -x WindowServer >/dev/null || log "warning: no GUI session; the measured offline run needs one"
  set +e
  "$bench_bin" --device offline-mock --bridge "$mock" --seconds 3 --taps 5 --settle 0.5 \
    --window 340x752 --dump-dir "$tmp/evidence" --json-out "$tmp/offline.json" 2>&1 | tee -a "$session_log"
  local offline_rc=${PIPESTATUS[0]}
  set -e
  [[ "$offline_rc" == "0" ]] || die "self-test: offline measured run failed (exit $offline_rc); a GUI session is required"
  python3 - "$tmp/offline.json" "$tmp/evidence" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
fps, latency = report["fps"], report["latency"]
assert fps["displayed_fps"] > 20, fps
assert len(fps["per_second_displayed"]) == 3, fps
assert fps["stream_width"] == 160 and fps["stream_height"] == 160, fps
assert latency["detected"] == 5 and latency["missed"] == 0, latency
assert 0 < latency["median_ms"] < 500, latency
import glob, os
frames = glob.glob(os.path.join(sys.argv[2], "probe-*.png"))
assert len(frames) == 3, frames
assert os.path.exists(os.path.join(sys.argv[2], "probes.jsonl")), "probes.jsonl missing"
print("self-test: offline measured run ok:",
      round(fps["displayed_fps"], 1), "displayed fps,", round(latency["median_ms"], 1), "ms median,",
      len(frames), "probe dumps")
PY

  log "self-test: negative harness paths (no GUI / no frames / no probe)"
  set +e
  "$bench_bin" --device mock --bridge "$mock" --seconds 2 --taps 0 --settle 0.3 \
    --hidden-window --json-out "$tmp/hidden.json" > /dev/null 2>&1
  local hidden_rc=$?
  "$bench_bin" --device none --bridge /usr/bin/false --first-frame-timeout 1 --seconds 2 --taps 0 \
    --json-out "$tmp/noframe.json" > /dev/null 2>&1
  local noframe_rc=$?
  "$bench_bin" --device mock --bridge "$mock" --seconds 2 --taps 2 --tap-timeout 0.2 \
    --settle 0.3 --probe 0.1,0.1 --json-out "$tmp/noprobes.json" > /dev/null 2>&1
  local noprobes_rc=$?
  set -e
  [[ "$hidden_rc" == "5" ]] || die "self-test: hidden-window exit $hidden_rc, expected 5"
  [[ "$noframe_rc" == "3" ]] || die "self-test: no-frame exit $noframe_rc, expected 3"
  [[ "$noprobes_rc" == "4" ]] || die "self-test: no-probe exit $noprobes_rc, expected 4"
  log "self-test: negative harness paths ok (5/3/4)"

  log "self-test: fps driver path (mock bridge)"
  set +e
  "$bench_bin" --device mock --bridge "$mock" --seconds 2 --taps 0 --settle 0.3     --fps-drive --json-out "$tmp/driven.json" > /dev/null 2>&1
  local driven_rc=$?
  set -e
  [[ "$driven_rc" == "0" ]] || die "self-test: --fps-drive run exit $driven_rc, expected 0"
  python3 - "$tmp/driven.json" <<'DRIVEN'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
fps = report["fps"]
assert fps["displayed_fps"] > 20, fps
assert len(fps["per_second_displayed"]) == 2, fps
print("self-test: fps driver path ok:", round(fps["displayed_fps"], 1), "displayed fps")
DRIVEN

  log "self-test: malformed Slint log"
  printf 'no benchmark output here\n' > "$tmp/slint-bad.log"
  python3 - "$(parse_slint "$tmp/slint-bad.log")" <<'SLINT'
import json, sys
value = json.loads(sys.argv[1])
assert value["available"] is False, value
assert "reason" in value, value
print("self-test: malformed Slint log ok")
SLINT

  log "self-test: full-script integration with a fake jidr (offline)"
  cat > "$tmp/fake-details-running.json" <<'DETAILS'
{"jidr_json":1,"ok":true,"result":{"device":{"id":"fake","name":"FakeBench","status":{"state":"running"},
"image":{"api":36,"tag":"google_apis"},"profile":"agent-lean","root":{"mode":"none"},
"runtime":{"adb_serial":"emulator-5556"},"sdk_root":"/tmp/m4-sdk"},
"config":{"hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"420"}}}
DETAILS
  cat > "$tmp/fake-details-stopped.json" <<'DETAILS'
{"jidr_json":1,"ok":true,"result":{"device":{"id":"fake","name":"FakeBench","status":{"state":"stopped"},
"image":{"api":36,"tag":"google_apis"},"profile":"agent-lean","root":{"mode":"none"},
"runtime":{"adb_serial":null},"sdk_root":"/tmp/m4-sdk"},
"config":{"hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"420"}}}
DETAILS
  cat > "$tmp/fake-connect.json" <<'CONNECT'
{"jidr_json":1,"ok":true,"result":{"device":"fake","grpc_endpoint":"127.0.0.1:9999",
"grpc_port":9999,"adb_serial":"emulator-5556"}}
CONNECT
  cat > "$tmp/fake-jidr" <<'FAKEJIDR'
#!/bin/bash
joined="$*"
case "$joined" in
  *"--json device list"*) echo '{"devices":[{"id":"fake","name":"FakeBench","status":{"state":"running"}}]}' ;;
  *"--json device details"*) cat "${FAKE_DETAILS:?}" ;;
  *"--json device connect-info"*) cat "${FAKE_CONNECT:?}" ;;
  *"--json device start"*)
    if [[ "${FAKE_START_FAIL:-0}" == "1" ]]; then
      echo 'device budget exceeded (fake)' >&2
      exit 9
    fi
    echo '{}' ;;
  *"--json device create"*|*"--json device stop"*|*"--json device delete"*|*"--json daemon stop"*) echo '{}' ;;
  *"--json call"*) echo '{"ok":true}' ;;
  *) echo '{}' ;;
esac
FAKEJIDR
  chmod +x "$tmp/fake-jidr"
  cat > "$tmp/fake-slint" <<'FAKESLINT'
#!/bin/bash
echo "visible: seconds=3.00 received_fps=59.97 shown_fps=58.72 MB_per_s=155.45 cpu_percent=61.3"
echo "paused: seconds=3.00 received_fps=4.37 shown_fps=0.25 MB_per_s=11.34 cpu_percent=0.7"
FAKESLINT
  chmod +x "$tmp/fake-slint"
  printf '#!/bin/bash\necho "display_bench: device busy" >&2\nexit 3\n' > "$tmp/fake-slint-fail"
  chmod +x "$tmp/fake-slint-fail"

  local script_path="$root/apps/jidr-swiftui-prototype/bench-player.sh"
  local integration_out="$tmp/integration-out"
  set +e
  FAKE_DETAILS="$tmp/fake-details-running.json" FAKE_CONNECT="$tmp/fake-connect.json" \
  JIDR_BIN="$tmp/fake-jidr" PLAYER_BRIDGE="$mock" BENCH_HARNESS_BIN="$bench_bin" \
  JIDR_HOME="$tmp/integration-home" \
    bash "$script_path" --device FakeBench --out-dir "$integration_out" --no-slint \
      --seconds 2 --taps 2 > "$tmp/integration.log" 2>&1
  local integration_rc=$?
  set -e
  # The mock bridge caps the frame rate, so the FPS gate must FAIL (exit 7) while
  # every artifact is produced.
  [[ "$integration_rc" == "7" ]] || die "self-test: integration run exit $integration_rc, expected 7 (fps gate)"
  for artifact in "$integration_out"/bench-*-player.json "$integration_out"/bench-*-summary.json \
                  "$integration_out"/bench-*-device.json "$integration_out"/bench-*.log; do
    [[ -f "$artifact" ]] || die "self-test: integration artifact missing: $artifact"
  done
  grep -q "FAIL  displayed_fps_ge_55_median" "$integration_out"/bench-*-summary.json 2>/dev/null \
    || grep -q "result: FAIL" "$integration_out"/bench-*.log \
    || die "self-test: integration summary did not report the fps gate"
  log "self-test: integration run ok (measured + summarized + artifacts, fps gate FAIL as expected)"

  log "self-test: device busy start path"
  set +e
  FAKE_DETAILS="$tmp/fake-details-stopped.json" FAKE_CONNECT="$tmp/fake-connect.json" \
  FAKE_START_FAIL=1 JIDR_BIN="$tmp/fake-jidr" PLAYER_BRIDGE="$mock" \
  JIDR_HOME="$tmp/integration-home" \
    bash "$script_path" --device FakeBench --out-dir "$tmp/busy-out" --start-device --no-slint \
      --seconds 1 --taps 0 > "$tmp/busy.log" 2>&1
  local busy_rc=$?
  set -e
  [[ "$busy_rc" == "2" ]] || die "self-test: device-busy exit $busy_rc, expected 2"
  grep -q "device start failed" "$tmp/busy.log" || die "self-test: device-busy message missing"
  log "self-test: device busy path ok"

  log "self-test: cleanup-only path"
  set +e
  FAKE_DETAILS="$tmp/fake-details-running.json" FAKE_CONNECT="$tmp/fake-connect.json" \
  JIDR_BIN="$tmp/fake-jidr" JIDR_HOME="$tmp/integration-home" \
    bash "$script_path" --device FakeBench --cleanup-only > "$tmp/cleanup.log" 2>&1
  local cleanup_rc=$?
  set -e
  [[ "$cleanup_rc" == "0" ]] || die "self-test: cleanup-only exit $cleanup_rc, expected 0"
  grep -q "cleanup done" "$tmp/cleanup.log" || die "self-test: cleanup-only message missing"
  grep -q "rm -rf" "$tmp/cleanup.log" || die "self-test: cleanup home hint missing"
  log "self-test: cleanup-only path ok"

  log "self-test: Slint-only path with a failing Slint command"
  set +e
  FAKE_DETAILS="$tmp/fake-details-running.json" FAKE_CONNECT="$tmp/fake-connect.json" \
  JIDR_BIN="$tmp/fake-jidr" PLAYER_BRIDGE="$mock" BENCH_SLINT_SCRIPT="$tmp/fake-slint-fail" \
  JIDR_HOME="$tmp/integration-home" \
    bash "$script_path" --device FakeBench --out-dir "$tmp/slint-fail-out" --slint-only \
      --seconds 3 > "$tmp/slint-fail.log" 2>&1
  local slint_fail_rc=$?
  set -e
  [[ "$slint_fail_rc" == "3" ]] || die "self-test: failing Slint exit $slint_fail_rc, expected 3"
  log "self-test: failing Slint path ok"

  log "self-test: Slint-only path with a fake baseline"
  set +e
  FAKE_DETAILS="$tmp/fake-details-running.json" FAKE_CONNECT="$tmp/fake-connect.json" \
  JIDR_BIN="$tmp/fake-jidr" PLAYER_BRIDGE="$mock" BENCH_SLINT_SCRIPT="$tmp/fake-slint" \
  JIDR_HOME="$tmp/integration-home" \
    bash "$script_path" --device FakeBench --out-dir "$tmp/slint-out" --slint-only \
      --seconds 3 > "$tmp/slint.log" 2>&1
  local slint_rc=$?
  set -e
  [[ "$slint_rc" == "0" ]] || die "self-test: Slint-only exit $slint_rc, expected 0"
  python3 - "$tmp/slint-out"/bench-*-slint.json <<'SLINT'
import glob, json, sys
paths = glob.glob(sys.argv[1])
assert len(paths) == 1, paths
value = json.load(open(paths[0], encoding="utf-8"))
assert value["available"] is True and abs(value["shown_fps"] - 58.72) < 0.001, value
print("self-test: Slint-only path ok")
SLINT

  log "self-test: JIDR_HOME guard"
  if ( check_home "$HOME/Library/Application Support/JIdr" >/dev/null 2>&1 ); then
    die "self-test: the real Jidr data directory was accepted as JIDR_HOME"
  fi
  if ( check_home "relative/path" >/dev/null 2>&1 ); then
    die "self-test: a relative JIDR_HOME was accepted"
  fi
  ( check_home "/tmp/jidr-m4-bench-selftest" >/dev/null 2>&1 ) || die "self-test: a /tmp JIDR_HOME was rejected"

  log "self-test: device param and adb serial helpers"
  local saved_device="${device:-}"
  device="MetaDevice"
  local params
  params="$(device_params '{"key":"home"}')"
  python3 - "$params" <<'PARAMS'
import json, sys
value = json.loads(sys.argv[1])
assert value["device"] == "MetaDevice" and value["key"] == "home", value
print("self-test: device_params argument ok")
PARAMS
  params="$(device_params)"
  python3 - "$params" <<'PARAMS'
import json, sys
value = json.loads(sys.argv[1])
assert value == {"device": "MetaDevice"}, value
print("self-test: device_params default ok")
PARAMS
  connect_json='{"adb_serial":"emulator-5554"}'
  [[ "$(connect_serial)" == "emulator-5554" ]] || die "self-test: connect_serial failed"
  connect_json=''
  [[ -z "$(connect_serial)" ]] || die "self-test: connect_serial empty input"
  device="$saved_device"
  log "self-test: device param and adb serial helpers ok"

  log "self-test: metadata parser"
  cat > "$tmp/details.json" <<'JSON'
{"jidr_json":1,"ok":true,"result":{"device":{"id":"11111111-1111-1111-1111-111111111111","name":"M4 Bench","status":{"state":"running"},
"image":{"api":36,"tag":"google_apis"},"profile":"pixel_7","root":{"mode":"none","health":"ok"},
"runtime":{"adb_serial":"emulator-5556"},"sdk_root":"/tmp/m4-sdk"},
"config":{"hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"420",
"hw.ramSize":"2048","hw.cpu.ncore":"4"},
"disk_usage":123}}
JSON
  cat > "$tmp/connect.json" <<'JSON'
{"jidr_json":1,"ok":true,"result":{"device":"11111111-1111-1111-1111-111111111111",
"grpc_endpoint":"127.0.0.1:8554","grpc_port":8554,"grpc_token":"secret",
"adb_serial":"emulator-5556","adb_path":"/tmp/m4-sdk/platform-tools/adb","console_port":5556}}
JSON
  printf '12.5 2048000\n11.5 2100000\n' > "$tmp/cpu.txt"
  local meta
  meta="$(parse_meta "$tmp/details.json" "$tmp/connect.json" "/tmp/jidr-m4-bench-selftest" \
           "4242" "qemu-system-aarch64 -avd M4 -grpc 8554 -gpu host" "$tmp/cpu.txt")"
  python3 - "$meta" <<'PY'
import json, sys
meta = json.loads(sys.argv[1])
assert meta["name"] == "M4 Bench", meta
assert meta["status"] == "running", meta
assert meta["panel"] == {"width": 1080, "height": 2400}, meta
assert meta["emulator_gpu"] == "host", meta
assert meta["emulator_cpu"]["samples"] == 2, meta
assert abs(meta["emulator_cpu"]["avg_percent"] - 12.0) < 0.01, meta
assert "grpc_token" not in json.dumps(meta), "token leaked into metadata"
print("self-test: metadata parser ok")
PY

  log "self-test: Slint log parser"
  cat > "$tmp/slint.log" <<'LOG'
visible: seconds=10.00 received_fps=59.97 shown_fps=58.72 MB_per_s=155.45 cpu_percent=61.3
paused: seconds=10.00 received_fps=4.37 shown_fps=0.25 MB_per_s=11.34 cpu_percent=0.7
LOG
  python3 - "$(parse_slint "$tmp/slint.log")" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["available"] is True, value
assert abs(value["shown_fps"] - 58.72) < 0.001, value
assert abs(value["cpu_percent"] - 61.3) < 0.01, value
assert abs(value["mb_per_s"] - 155.45) < 0.01, value
print("self-test: Slint log parser ok")
PY

  log "self-test: summary gates"
  cat > "$tmp/meta.json" <<'JSON'
{"name":"M4 Bench","image_api":36,"image_tag":"google_apis","panel":{"width":1080,"height":2400},
"root_mode":"none","emulator_gpu":"host","emulator_cpu":{"avg_percent":280.0,"max_rss_mb":4096.0}}
JSON
  cat > "$tmp/swiftui.json" <<'JSON'
{"fps":{"median_displayed_fps":58.0,"median_presented_fps":59.0,"median_received_fps":59.5,
"active_fps_median":59.8,"mb_per_s":150.0,"cpu_percent":12.0,"stream_width":576,"stream_height":1280},
"latency":{"taps":30,"detected":30,"median_ms":13.0,"p90_ms":16.0},
"window":{"width":340,"height":752},"exit_code":0,"reason":"complete"}
JSON
  cat > "$tmp/swiftui-slow.json" <<'JSON'
{"fps":{"median_displayed_fps":40.0,"median_presented_fps":41.0},"latency":{"taps":30,"detected":30,"median_ms":95.0,"p90_ms":120.0},
"window":{"width":340,"height":752},"exit_code":0,"reason":"complete"}
JSON
  cat > "$tmp/slint.json" <<'JSON'
{"available":true,"received_fps":59.97,"shown_fps":58.72,"mb_per_s":155.45,"cpu_percent":61.3,"seconds":10.0}
JSON
  parse_slint "$tmp/slint.log" > "$tmp/slint-parsed.json"
  summarize "$tmp/meta.json" "$tmp/swiftui.json" "$tmp/slint-parsed.json" both > "$tmp/summary-pass.txt" || true
  grep -q "result: PASS" "$tmp/summary-pass.txt" || die "self-test: a passing summary did not PASS"
  set +e
  summarize "$tmp/meta.json" "$tmp/swiftui-slow.json" "$tmp/slint-parsed.json" both > "$tmp/summary-fail.txt"
  local slow_rc=$?
  set -e
  [[ "$slow_rc" == "7" ]] || die "self-test: slow run exit code was $slow_rc, expected 7"
  grep -q "result: FAIL" "$tmp/summary-fail.txt" || die "self-test: a failing summary did not FAIL"
  grep -q "FAIL  displayed_fps_ge_55_median" "$tmp/summary-fail.txt" || die "self-test: fps gate not reported"
  log "self-test: invalid Slint baseline is reported but not judged"
  cat > "$tmp/slint-invalid.json" <<'SLINTBAD'
{"available":true,"received_fps":0.1,"shown_fps":0.1,"mb_per_s":0.26,"cpu_percent":3.4,"seconds":10.0}
SLINTBAD
  set +e
  summarize "$tmp/meta.json" "$tmp/swiftui.json" "$tmp/slint-invalid.json" both > "$tmp/summary-invalid.txt"
  local invalid_rc=$?
  set -e
  [[ "$invalid_rc" == "0" ]] || die "self-test: invalid-Slint summary exit $invalid_rc, expected 0 (fps/latency only)"
  grep -q "baseline INVALID" "$tmp/summary-invalid.txt" || die "self-test: invalid Slint not reported"
  grep -q "not_worse_than_slint" "$tmp/summary-invalid.txt" && die "self-test: A/B gate applied to invalid Slint"
  grep -q "reference (not judged)" "$tmp/summary-invalid.txt" || die "self-test: documented reference missing"
  grep -q "displayed_definition" "$tmp/summary-invalid.txt" || die "self-test: displayed definition missing"
  # 22 fps is still below the ADR-0001 floor: not a comparable baseline.
  cat > "$tmp/slint-mid.json" <<'SLINTMID'
{"available":true,"received_fps":22.39,"shown_fps":22.39,"mb_per_s":58.05,"cpu_percent":28.5,"seconds":10.0}
SLINTMID
  set +e
  summarize "$tmp/meta.json" "$tmp/swiftui.json" "$tmp/slint-mid.json" both > "$tmp/summary-mid.txt"
  local mid_rc=$?
  set -e
  [[ "$mid_rc" == "0" ]] || die "self-test: 22 fps Slint summary exit $mid_rc, expected 0 (reference only)"
  grep -q "baseline INVALID" "$tmp/summary-mid.txt" || die "self-test: 22 fps Slint not marked invalid"
  grep -q "not_worse_than_slint" "$tmp/summary-mid.txt" && die "self-test: A/B gate applied to a 22 fps baseline"
  log "self-test: invalid Slint baseline handling ok"

  # The summariser must also accept the real harness JSON shape produced by the
  # offline measured run above.
  set +e
  summarize "$tmp/meta.json" "$tmp/offline.json" "$tmp/slint-parsed.json" both > "$tmp/summary-offline.txt"
  local offline_summary_rc=$?
  set -e
  [[ "$offline_summary_rc" == "7" ]] || die "self-test: real harness JSON summary exit $offline_summary_rc, expected 7"
  grep -q "SUMMARY_JSON" "$tmp/summary-offline.txt" || die "self-test: summary JSON marker missing"
  log "self-test: summary gates ok"

  log "self-test: resummarize from saved artifacts"
  mkdir -p "$tmp/resummarize"
  cp "$tmp/meta.json" "$tmp/resummarize/run-device.json"
  cp "$tmp/swiftui.json" "$tmp/resummarize/run-player.json"
  cp "$tmp/slint-parsed.json" "$tmp/resummarize/run-slint.json"
  set +e
  JIDR_HOME="$tmp/integration-home" bash "$script_path" --resummarize "$tmp/resummarize/run" \
    > "$tmp/resummarize.log" 2>&1
  local resummarize_rc=$?
  set -e
  [[ "$resummarize_rc" == "0" ]] || die "self-test: resummarize exit $resummarize_rc, expected 0"
  [[ -f "$tmp/resummarize/run-summary.json" ]] || die "self-test: resummarize summary missing"
  grep -q "result: PASS" "$tmp/resummarize.log" || die "self-test: resummarize did not PASS"
  log "self-test: resummarize ok"

  rm -rf "$tmp"
  log "BENCH SELF-TEST PASSED"
  exit 0
}

# --- preflight --------------------------------------------------------------

check_home "${JIDR_HOME:-}"
if [[ "$self_test" == "1" ]]; then
  run_self_test
fi

if [[ -n "$resummarize" ]]; then
  meta_json="$resummarize-device.json"
  swiftui_json="$resummarize-player.json"
  slint_json="$resummarize-slint.json"
  summary_json="$resummarize-summary.json"
  for artifact in "$meta_json" "$swiftui_json" "$slint_json"; do
    [[ -f "$artifact" ]] || die "resummarize: missing artifact $artifact"
  done
  set +e
  summarize "$meta_json" "$swiftui_json" "$slint_json" both \
    | tee -a "$session_log" "$summary_json"
  summary_rc=${PIPESTATUS[0]}
  set -e
  python3 - "$summary_json" <<'PY'
import json, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
json_lines = [line[len("SUMMARY_JSON "):] for line in lines if line.startswith("SUMMARY_JSON ")]
if json_lines:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(json.loads(json_lines[-1]), fh, indent=2, sort_keys=True)
        fh.write("\n")
PY
  log "resummarized: $summary_json"
  exit "$summary_rc"
fi

if [[ "$cleanup_only" == "1" ]]; then
  [[ -n "$device" ]] || die "--device is required with --cleanup-only"
  [[ -x "$JIDR" ]] || die "jidr binary not found: $JIDR"
  log "cleanup: stop '$device' (saves quick-boot state)"
  "$JIDR" --json device stop "$device" 2>&1 | tee -a "$session_log" >/dev/null \
    || log "warning: device stop failed"
  log "cleanup: delete '$device' and its data"
  "$JIDR" --json device delete "$device" --yes 2>&1 | tee -a "$session_log" >/dev/null \
    || log "warning: device delete failed"
  log "cleanup: stop the daemon for this isolated home"
  "$JIDR" --json daemon stop 2>&1 | tee -a "$session_log" >/dev/null \
    || log "warning: daemon stop failed"
  log "cleanup done; remove the isolated home when convenient:"
  log "  rm -rf '$JIDR_HOME'"
  exit 0
fi

check_tools
[[ -n "$device" ]] || die "--device is required (try --help)"

log "M4-B SwiftUI player bench"
log "  root: $root"
log "  JIDR_HOME: $JIDR_HOME"
log "  ANDROID_HOME: ${ANDROID_HOME:-<unset>}"
log "  artifacts: $outdir"
log "  git: $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "  machine: $(sysctl -n hw.model 2>/dev/null || echo unknown) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown) / macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
log "  build profile: debug (swiftc default -Onone; cargo dev; Slint example via cargo run without --release)"

trap 'restore_device_state' EXIT
restore_device_state() {
  if [[ "${show_taps_set:-0}" == "1" ]]; then
    "$JIDR" --json call dev.set "{\"device\":\"$device\",\"show_taps\":false}" >/dev/null 2>&1 || true
    log "restored dev.set show_taps=false"
  fi
  if [[ -n "${sampler_pid:-}" ]]; then
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
  stop_adb_driver
}

# --- device -----------------------------------------------------------------

log "device: $device"
known_devices="$("$JIDR" --json device list 2>>"$session_log" || true)"
if ! printf '%s' "$known_devices" | grep -q "\"name\": *\"$device\"" \
   && ! printf '%s' "$known_devices" | grep -q "\"$device\""; then
  if [[ "$create_device" == "1" ]]; then
    log "device does not exist; creating '$device' from image '$image'"
    "$JIDR" --json device create "$device" --image "$image" 2>&1 | tee -a "$session_log" >/dev/null \
      || die "device create failed (image '$image' not available in ANDROID_HOME=${ANDROID_HOME:-<unset>}?)"
  else
    die "device '$device' does not exist (create it or pass --create --image ID)"
  fi
fi
if ! details_json="$("$JIDR" --json device details "$device" 2>>"$session_log")"; then
  die "cannot read device details for '$device' (is the daemon up for JIDR_HOME=$JIDR_HOME?)"
fi
printf '%s\n' "$details_json" > "$outdir/bench-$ts-details.json"

status="$(printf '%s' "$details_json" | python3 -c 'import json,sys
raw=json.load(sys.stdin)
raw=raw.get("result", raw)
d=raw.get("device",raw)
print((d.get("status") or {}).get("state",""))' 2>/dev/null || true)"
if [[ "$status" != "running" ]]; then
  if [[ "$start_device" == "1" ]]; then
    log "device is '$status'; starting it (--start-device)"
    "$JIDR" --json device start "$device" --timeout 300 2>&1 | tee -a "$session_log" >/dev/null \
      || die "device start failed"
    details_json="$("$JIDR" --json device details "$device")"
    printf '%s\n' "$details_json" > "$outdir/bench-$ts-details.json"
    status="$(printf '%s' "$details_json" | python3 -c 'import json,sys
raw=json.load(sys.stdin)
raw=raw.get("result", raw)
d=raw.get("device",raw)
print((d.get("status") or {}).get("state",""))' 2>/dev/null || true)"
    [[ "$status" == "running" ]] || die "device is '$status' after start, expected running"
  else
    die "device '$device' is '$status', not running (start it or pass --start-device)"
  fi
fi

connect_json="$("$JIDR" --json device connect-info "$device" 2>>"$session_log" \
  | python3 -c 'import json,sys
raw=json.load(sys.stdin)
info=raw.get("result", raw)
# The bearer token must never reach an artifact.
print(json.dumps({k:v for k,v in info.items() if k != "grpc_token"}, sort_keys=True))')"
printf '%s\n' "$connect_json" > "$outdir/bench-$ts-connect.json"
grpc_port="$(printf '%s' "$connect_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("grpc_port",0))')"
emulator_pid="$(ps -axo pid=,command= | grep -F -- "-grpc $grpc_port" | grep -v grep | awk 'NR==1 {print $1}' || true)"
emulator_cmd=""
if [[ -n "$emulator_pid" ]]; then
  emulator_cmd="$(ps -p "$emulator_pid" -o command= | tr -s ' ')"
fi
log "device running: grpc port $grpc_port, adb $(printf '%s' "$connect_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("adb_serial",""))')"
if [[ -n "$emulator_pid" ]]; then
  log "emulator pid $emulator_pid: $(printf '%s' "$emulator_cmd" | cut -c1-160)"
  gpu="$(printf '%s' "$emulator_cmd" | sed -n 's/.*-gpu \([^ ]*\).*/\1/p')"
  [[ "$gpu" == "host" ]] || log "warning: emulator GPU mode is '${gpu:-unknown}', ADR-0001 expects 'host'"
else
  log "warning: could not find the emulator process for grpc port $grpc_port (emulator CPU not sampled)"
fi

# Sample the emulator's CPU/RSS while both benches run (device-side cost).
cpu_file="$outdir/bench-$ts-emulator-cpu.txt"
if [[ -n "$emulator_pid" ]]; then
  ( while kill -0 "$emulator_pid" 2>/dev/null; do
      ps -p "$emulator_pid" -o %cpu=,rss= >> "$cpu_file" 2>/dev/null || true
      sleep 1
    done ) &
  sampler_pid=$!
fi

# --- frame-rate + latency (SwiftUI path) ------------------------------------

swiftui_json="$outdir/bench-$ts-player.json"
swiftui_log="$outdir/bench-$ts-player.log"
probe_dir="$outdir/bench-$ts-probe"
dump_args=()
driver_args=()
if [[ "$fps_drive" == "1" ]]; then
  driver_args=(--fps-drive)
fi
if [[ "$dump_probe" == "1" ]]; then
  dump_args=(--dump-dir "$probe_dir")
fi
swiftui_rc=0
if [[ "$run_swiftui" == "1" ]]; then
  log "setting dev.set show_taps=true (latency probe)"
  "$JIDR" --json call dev.set "{\"device\":\"$device\",\"show_taps\":true}" >/dev/null 2>>"$session_log" \
    || die "dev.set show_taps failed"
  show_taps_set=1
  if [[ "$fps_drive" == "1" ]]; then
    open_scrollable_scene
  else
    send_home
    sleep 0.5
  fi
  log "running SwiftUI harness ($seconds s fps, $taps latency taps, window $window, probe $probe"
  if [[ "$fps_drive" == "1" ]]; then log "  fps phase: Settings list, drives alternating 300 ms drags through the player bridge"; fi
  log "  )"
  set +e
  "$bench_bin" --device "$device" --bridge "$BRIDGE" \
    --panel-width "$(printf '%s' "$details_json" | python3 -c 'import json,sys
raw=json.load(sys.stdin); raw=raw.get("result",raw); print((raw.get("config") or {}).get("hw.lcd.width","1080"))')" \
    --panel-height "$(printf '%s' "$details_json" | python3 -c 'import json,sys
raw=json.load(sys.stdin); raw=raw.get("result",raw); print((raw.get("config") or {}).get("hw.lcd.height","2400"))')" \
    --quality "$quality" --seconds "$seconds" --taps "$taps" --window "$window" --probe "$probe" \
    --probe-threshold "$probe_threshold" "${driver_args[@]}" "${dump_args[@]}" --json-out "$swiftui_json" \
    2>&1 | tee -a "$session_log" "$swiftui_log"
  swiftui_rc=${PIPESTATUS[0]}
  set -e
  log "SwiftUI harness exit=$swiftui_rc"
  if [[ -n "${show_taps_set:-}" && "$show_taps_set" == "1" ]]; then
    "$JIDR" --json call dev.set "{\"device\":\"$device\",\"show_taps\":false}" >/dev/null 2>>"$session_log" || true
    show_taps_set=0
    log "restored dev.set show_taps=false"
  fi
else
  # --slint-only: the summariser still expects a player report file.
  printf '%s\n' '{"fps":{},"latency":{},"exit_code":null,"reason":"skipped (--slint-only)"}' > "$swiftui_json"
fi

# --- Slint baseline ---------------------------------------------------------

slint_log="$outdir/bench-$ts-slint.log"
slint_json="$outdir/bench-$ts-slint.json"
slint_rc=0
if [[ "$run_slint" == "1" ]]; then
  # Same scrollable scene and window size (the example opens 340x752 pt) as the
  # SwiftUI run. display_bench never sends input, so a neutral adb swipe driver
  # keeps the emulator producing frames while it measures its visible interval.
  open_scrollable_scene
  start_adb_driver
  set +e
  run_slint_baseline
  slint_rc=$?
  set -e
  stop_adb_driver
  send_home
  log "Slint baseline exit=$slint_rc"
  parse_slint "$slint_log" > "$slint_json"
else
  printf '%s\n' '{"available":false,"reason":"skipped (--no-slint)"}' > "$slint_json"
fi

# Stop the sampler before writing metadata.
if [[ -n "${sampler_pid:-}" ]]; then
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sampler_pid=""
fi

# --- metadata + summary -----------------------------------------------------

meta_json="$outdir/bench-$ts-device.json"
parse_meta "$outdir/bench-$ts-details.json" "$outdir/bench-$ts-connect.json" "$JIDR_HOME" \
  "${emulator_pid:-}" "${emulator_cmd:-}" "$cpu_file" > "$meta_json"
python3 - "$meta_json" "$swiftui_json" "$slint_json" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], encoding="utf-8"))
for path in sys.argv[2:4]:
    try:
        json.load(open(path, encoding="utf-8"))
    except Exception as error:
        print(f"warning: unreadable artifact {path}: {error}")
print(json.dumps(meta, indent=2, sort_keys=True))
PY

mode="both"
if [[ "$run_swiftui" == "0" ]]; then mode="slint-only"; fi
if [[ "$run_slint" == "0" ]]; then mode="swiftui-only"; fi

summary_json="$outdir/bench-$ts-summary.json"
summary_rc=0
set +e
summarize "$meta_json" "$swiftui_json" "$slint_json" "$mode" \
  | tee -a "$session_log" "$summary_json"
summary_rc=${PIPESTATUS[0]}
set -e

# Keep a copy of the summary lines without the embedded JSON marker.
python3 - "$summary_json" <<'PY'
import json, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
human = [line for line in lines if not line.startswith("SUMMARY_JSON ")]
json_lines = [line[len("SUMMARY_JSON "):] for line in lines if line.startswith("SUMMARY_JSON ")]
if json_lines:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(json.loads(json_lines[-1]), fh, indent=2, sort_keys=True)
        fh.write("\n")
PY

log ""
log "artifacts:"
for path in "$session_log" "$swiftui_log" "$slint_log" "$swiftui_json" "$slint_json" \
            "$meta_json" "$summary_json" "$cpu_file"; do
  [[ -f "$path" ]] && log "  $path"
done
if [[ -d "$probe_dir" ]]; then
  log "  $probe_dir/ ($(ls -1 "$probe_dir" | wc -l | tr -d ' ') probe evidence files)"
fi
log ""
log "reproduce:"
log "  ANDROID_HOME=${ANDROID_HOME:-/tmp/m4-sdk} JIDR_HOME=$JIDR_HOME \\"
log "    bash apps/jidr-swiftui-prototype/bench-player.sh --device $device --seconds $seconds --taps $taps --window $window"

if [[ "$swiftui_rc" != "0" && "$mode" != "slint-only" ]]; then
  log "SwiftUI harness exited $swiftui_rc (measurement failed)"
  exit "$swiftui_rc"
fi
if [[ "$slint_rc" != "0" && "$mode" != "swiftui-only" ]]; then
  log "Slint baseline exited $slint_rc (A/B failed)"
  exit "$slint_rc"
fi
exit "$summary_rc"
