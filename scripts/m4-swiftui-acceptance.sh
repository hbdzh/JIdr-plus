#!/usr/bin/env bash
# M4-A: isolated, repeatable real-device acceptance for the SwiftUI migration.
#
# Runs the CLI/protocol surface the SwiftUI app is built on against one real
# emulator, in a throwaway JIDR_HOME under /tmp (short path: Unix sockets are
# limited to ~104 bytes). It never touches the user's data, AVDs or SDK files:
# the SDK is read-only (ANDROID_HOME=JIDR_TEST_SDK) and every AVD lives under
# the throwaway home.
#
# Steps (all against a real booted Android emulator):
#   1  create            device create (profile small-phone-5)
#   2  start             device start, waits for boot; boot duration recorded
#   3  connect-info      gRPC endpoint/port/token, adb serial/path + TCP probe
#   4  apps              app.list + app.launch com.android.settings (focused)
#   5  screenshot        media.screenshot to an absolute /tmp path, PNG checked
#   6  snapshot          guest marker → snapshot.save → delete → snapshot.load
#                        → marker read back (proves the restore)
#   7  root              root.verify → root.set adb (live adbd root) → verify
#   8  record            media.record 3 s → media.record_stop → MP4 checked
#   9  stop              device stop, no Jidr emulator left
#   10 delete            device delete --yes, device list empty
#   11 daemon-quit       daemon.quit, socket gone, daemon not running
#
# Output: target/m4/acceptance-<ts>.log (full transcript), target/m4/screenshot.png,
# target/m4/record.mp4, and target/m4/evidence-<ts>/ (per-step JSON, steps.tsv,
# summary.json, README.md, logs copied from the throwaway home).
#
# Environment:
#   JIDR_TEST_SDK    SDK holding the system image (read-only). Default: $ANDROID_HOME
#                    or the Android Studio SDK. On this machine use /tmp/m4-sdk.
#   JIDR_TEST_IMAGE  sdkmanager package. Default: android-36 google_apis, host ABI.
#   JIDR_TEST_PROFILE Hardware profile (default small-phone-5).
#   JIDR_TEST_DEVICE  Device name (default m4-accept-<HHMMSS>; keep it unique).
#   JIDR_M4_KEEP=1   Keep the throwaway JIDR_HOME after the run (debugging).
#   JIDR_M4_SKIP_RAMDISK_CHECK=1  Skip the pristine-ramdisk preflight (not advised).
#   PROTOC            protoc for rebuilding jidr-proto; autodetected from
#                     target/tools/protoc/bin/protoc or PATH. An up-to-date
#                     target/debug/jidr is preferred and build is skipped;
#                     JIDR_M4_FORCE_BUILD=1 always rebuilds.
#
# Rerun on this machine:
#   JIDR_TEST_SDK=/tmp/m4-sdk bash scripts/m4-swiftui-acceptance.sh
#
# On another machine: use a clean, read-only SDK whose image was not patched
# by a root tool (ramdisk.img must stay the image's LZ4 ramdisk; if it is an
# Android boot image the emulator won't boot — see the preflight error). No
# license acceptance, SDK download or user AVD is touched here. The script
# needs a logged-in macOS GUI session (the emulator and the MP4 encoder are
# windowed/AVFoundation based) and ~10 GiB free in /tmp.
#
# This script is evidence tooling only: it does not change product code,
# build scripts, docs or the GitHub workflows, and it does not commit anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---- invocation -----------------------------------------------------------
# --self-check       test this script's JSON/ramdisk/cleanup helpers, no daemon
# --preflight-only   verify the SDK, image and free space; start nothing
MODE=run
case "${1:-}" in
  --self-check) MODE=self-check ;;
  --preflight-only) MODE=preflight-only ;;
  "") ;;
  *) printf 'usage: %s [--self-check|--preflight-only]\n' "$0" >&2; exit 2 ;;
esac

# ---- configuration --------------------------------------------------------
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}"
case "$CARGO_TARGET_DIR" in /*) TARGET="$CARGO_TARGET_DIR" ;; *) TARGET="$ROOT/$CARGO_TARGET_DIR" ;; esac
JIDR="$TARGET/debug/jidr"

case "$(uname -m)" in arm64|aarch64) ABI=arm64-v8a ;; *) ABI=x86_64 ;; esac
SDK="${JIDR_TEST_SDK:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
IMAGE="${JIDR_TEST_IMAGE:-system-images;android-36;google_apis;$ABI}"
PROFILE="${JIDR_TEST_PROFILE:-small-phone-5}"
DEVICE="${JIDR_TEST_DEVICE:-m4-accept-$(date +%H%M%S)-$$}"
TS="$(date +%Y%m%d-%H%M%S)"
EVID="$ROOT/target/m4"
if [ "$MODE" = self-check ]; then LOG="$EVID/selfcheck-$TS.log"; else LOG="$EVID/acceptance-$TS.log"; fi
ART="$EVID/evidence-$TS"
mkdir -p "$EVID" "$ART"

SDK_ABS="$(cd "$SDK" 2>/dev/null && pwd || true)"
SDK="${SDK_ABS:-$SDK}"

# Read-only SDK, isolated home. Short /tmp path for the Unix socket. The
# merged SDK is exported for the daemon *after* the build: cargo's proto build
# script fingerprints ANDROID_HOME, so the build keeps the inherited host env.
INHERITED_ANDROID_HOME="${ANDROID_HOME:-unset}"
unset ANDROID_AVD_HOME || true
JIDR_HOME="$(mktemp -d /tmp/jidr-m4-accept.XXXXXX)"
export JIDR_HOME
RUN="$JIDR_HOME/run"
mkdir -p "$RUN"
export JIDR_M4_HOME="$JIDR_HOME"

# ---- shared state ---------------------------------------------------------
CURRENT_STEP=""
STEP_START=0
FAILED_STEP=""
SUMMARY_WRITTEN=0
STEPS_TSV="$ART/steps.tsv"
: > "$STEPS_TSV"
BOOT_SECONDS=""
TOTAL_START="$SECONDS"
ADB_PATH=""
ADB_SERIAL=""
JIDR_VERSION=""

# ---- logging / evidence helpers ------------------------------------------
exec > >(tee "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
note() { printf '[%s]   %s\n' "$(date +%H:%M:%S)" "$*"; }

sha256() { shasum -a 256 -- "$1" | awk '{print $1}'; }

# The ramdisk.img of the image the acceptance would create; handles both the
# full sdkmanager package and `36` / `36:google_apis` short forms.
image_ramdisk_path() {
  local img="$1" api tag candidates
  if [[ "$img" == *";"* ]]; then
    printf '%s/%s/ramdisk.img\n' "$SDK" "${img//;//}"
    return 0
  fi
  api="${img%%:*}"
  tag=""
  [[ "$img" == *:* ]] && tag="${img#*:}"
  candidates=("$SDK"/system-images/android-"$api"/${tag:-*}/"$ABI"/ramdisk.img)
  [ -e "${candidates[0]}" ] && printf '%s\n' "${candidates[0]}"
}

# Empty when the ramdisk is the image's pristine LZ4 ramdisk; otherwise why
# the emulator would not boot it (e.g. an Android boot image from a root tool).
ramdisk_problem() {
  local path="$1" desc
  [ -e "$path" ] || { printf 'missing %s\n' "$path"; return 0; }
  desc="$(file -b "$path" 2>/dev/null || true)"
  case "$desc" in
    *"LZ4 compressed"*) ;;
    *) printf '%s\n' "${desc:-unknown}" ;;
  esac
}

# A throwaway home this script is allowed to delete.
can_remove_home() {
  case "$1" in
    /tmp/jidr-m4-accept.*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the last line of a `jidr --json` output file is the ok envelope.
envelope_ok() {
  python3 -I - "$1" <<'PY'
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
value = json.loads(lines[-1])
assert value.get("jidr_json") == 1 and value.get("ok") is True, value
PY
}

write_summary() {  # write_summary <status> [failed-step]
  [ "$MODE" = self-check ] && return 0
  [ "$SUMMARY_WRITTEN" = 1 ] && return 0
  SUMMARY_WRITTEN=1
  local status="$1" failed_step="${2:-}"
  cp -R "$JIDR_HOME/logs" "$ART/logs" 2>/dev/null || true
  cp "$JIDR_HOME/data/devices.json" "$ART/devices.json" 2>/dev/null || true
  python3 -I - "$ART" "$status" "$failed_step" "$STEPS_TSV" "$DEVICE" "$IMAGE" "$SDK" \
      "$JIDR_VERSION" "$BOOT_SECONDS" "$(( SECONDS - TOTAL_START ))" "$ROOT" <<'PY'
import datetime, hashlib, json, os, platform, subprocess, sys
art, status, failed_step, steps_tsv, device, image, sdk, version, boot, total, root = sys.argv[1:12]
steps = []
try:
    for line in open(steps_tsv):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            row = {"step": parts[0], "status": parts[1], "seconds": int(parts[2])}
            if len(parts) > 3 and parts[3]:
                row["note"] = parts[3]
            steps.append(row)
except FileNotFoundError:
    pass
files = {}
for name, rel in [("screenshot", os.path.join(os.path.dirname(art), "screenshot.png")),
                  ("record", os.path.join(os.path.dirname(art), "record.mp4"))]:
    if os.path.isfile(rel) and os.path.getsize(rel) > 0:
        files[name] = {
            "path": os.path.relpath(rel, root),
            "bytes": os.path.getsize(rel),
            "sha256": hashlib.sha256(open(rel, "rb").read()).hexdigest(),
        }
host = {"macos": platform.mac_ver()[0], "arch": platform.machine()}
try:
    host["ram_gb"] = round(int(subprocess.check_output(["sysctl", "-n", "hw.memsize"])) / 1073741824, 1)
except Exception:
    pass
summary = {
    "tool": "scripts/m4-swiftui-acceptance.sh",
    "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "status": status,
    "failed_step": failed_step or None,
    "device": device,
    "image": image,
    "sdk": sdk,
    "jidr_version": version,
    "boot_seconds": int(boot) if str(boot).isdigit() else None,
    "total_seconds": int(total),
    "steps": steps,
    "files": files,
    "host": host,
}
open(os.path.join(art, "summary.json"), "w").write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
if status == "ok":
    lines = [
        "# M4-A SwiftUI acceptance evidence",
        "",
        f"- status: **ok**",
        f"- device: `{device}`",
        f"- image: `{image}`",
        f"- SDK: `{sdk}` (read-only)",
        f"- jidr: `{version}`",
        f"- boot: {boot} s, total: {total} s",
        "",
        "| step | status | seconds | note |",
        "|---|---|---:|---|",
    ]
    lines += [f"| {s['step']} | {s['status']} | {s['seconds']} | {s.get('note','')} |" for s in steps]
    lines += ["", "## Files", ""]
    lines += [f"- `{v['path']}` — {v['bytes']} bytes, sha256 `{v['sha256']}`" for v in files.values()]
    lines += [
        "",
        "## Rerun",
        "",
        "```bash",
        "JIDR_TEST_SDK=/tmp/m4-sdk bash scripts/m4-swiftui-acceptance.sh",
        "```",
        "",
        "## Another machine",
        "",
        "Use a clean, read-only Android SDK whose system image ramdisk was not",
        "patched (the preflight refuses an Android boot image), a logged-in macOS",
        "GUI session, and ~10 GiB free in /tmp. The script creates its own",
        "throwaway JIDR_HOME, AVD and 3-second MP4; it never writes the user's",
        "Jidr data, AVDs or SDK files, and it does not accept any SDK licence.",
    ]
    open(os.path.join(art, "README.md"), "w").write("\n".join(lines) + "\n")
PY
  [ "$status" = ok ] && cp "$LOG" "$EVID/acceptance-latest.log" 2>/dev/null || true
  log "evidence: $ART/summary.json"
}

fail() {
  local message="$1" code="${2:-1}"
  log "FAIL${CURRENT_STEP:+ [$CURRENT_STEP]}: $message"
  FAILED_STEP="${CURRENT_STEP:-preflight}"
  write_summary failed "$FAILED_STEP"
  exit "$code"
}

# Runs `jidr --json …`; fails on a non-zero exit or a non-ok envelope.
# Leaves the raw output in $RUN/last.json.
last_json() { printf '%s\n' "$RUN/last.json"; }
jidr_json() {
  local out code=0
  out="$("$JIDR" --json "$@" 2>&1)" || code=$?
  printf '%s\n' "$out" > "$RUN/last.json"
  if [ "$code" -ne 0 ]; then
    fail "jidr $* exited $code: $out"
  fi
  envelope_ok "$RUN/last.json" || fail "jidr $* returned a bad JSON envelope: $out"
  LAST="$out"
}

# field <python expression over r = result> [json file] (default: last command)
field() {
  python3 -I - "${2:-$RUN/last.json}" "$1" <<'PY'
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
print(eval(sys.argv[2], {"r": r}))
PY
}

save_json() { cp "$RUN/last.json" "$ART/$1.json"; }

begin_step() {
  CURRENT_STEP="$1"
  STEP_START=$SECONDS
  log "STEP BEGIN $CURRENT_STEP"
}

end_step() {
  local note="${1:-}"
  local seconds=$(( SECONDS - STEP_START ))
  printf '%s\tok\t%s\t%s\n' "$CURRENT_STEP" "$seconds" "$note" >> "$STEPS_TSV"
  log "STEP OK    $CURRENT_STEP (${seconds}s)${note:+ — $note}"
  CURRENT_STEP=""
}

# adb against this run's device (set in step 3).
adb_run() { "$ADB_PATH" -s "$ADB_SERIAL" "$@"; }

# ---- preflight ------------------------------------------------------------
preflight() {
  log "M4-A SwiftUI acceptance $TS"
  log "workspace: $ROOT"
  log "host: $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m), $(sysctl -n hw.ncpu) CPUs, $(( $(sysctl -n hw.memsize) / 1073741824 )) GiB RAM"
  log "jidr home (throwaway): $JIDR_HOME"
  log "SDK (read-only): $SDK"
  log "image: $IMAGE"
  log "profile: $PROFILE"
  log "device: $DEVICE"

  command -v python3 >/dev/null || fail "python3 is required for the JSON assertions"
  local socket_path="$JIDR_HOME/data/daemon.sock"
  [ "${#socket_path}" -le 100 ] || fail "the daemon socket path would be too long: $socket_path"
  command -v file >/dev/null || fail "file(1) is required for the ramdisk preflight"
  [ -d "$SDK" ] || fail "SDK not found: $SDK (set JIDR_TEST_SDK to a read-only merged SDK)"
  [ -n "$SDK_ABS" ] || fail "SDK path is not a directory: $SDK"

  # Refuse a patched image ramdisk before starting anything: the emulator can
  # only boot the image's pristine LZ4 ramdisk. Never modify the user SDK.
  local ramdisk problem
  ramdisk="$(image_ramdisk_path "$IMAGE")"
  [ -n "$ramdisk" ] && [ -e "$ramdisk" ] || fail "no installed system image found for $IMAGE under $SDK; install it or point JIDR_TEST_SDK at an SDK that has it"
  if [ "${JIDR_M4_SKIP_RAMDISK_CHECK:-0}" != 1 ]; then
    problem="$(ramdisk_problem "$ramdisk")"
    [ -z "$problem" ] || fail "the system image ramdisk at $ramdisk is not the pristine LZ4 ramdisk (file says: $problem). A boot image there means the image was patched (e.g. by a root tool) and the emulator will not boot. Point JIDR_TEST_SDK at a merged read-only SDK with the pristine ramdisk (e.g. /tmp/m4-sdk); this script never modifies the user's SDK."
    log "ramdisk preflight: pristine LZ4 ramdisk at $ramdisk"
  else
    log "ramdisk preflight skipped by JIDR_M4_SKIP_RAMDISK_CHECK=1"
  fi

  # A stale /tmp home from an interrupted earlier run may still hold an
  # emulator; only kill emulators whose AVD sits under an m4-accept home.
  python3 -I <<'PY' || true
import glob, os, signal, sys
dirs = [
    os.path.expanduser("~/Library/Caches/TemporaryItems/avd/running"),
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"), "avd/running"),
    f"/tmp/android-{os.environ.get('USER', '')}/avd/running",
]
killed = []
for d in dirs:
    for f in glob.glob(os.path.join(d, "pid_*.ini")):
        try:
            vals = dict(line.strip().split("=", 1) for line in open(f) if "=" in line)
            pid = int(os.path.basename(f)[4:-4])
        except (OSError, ValueError):
            continue
        if not os.path.realpath(vals.get("avd.dir", "/")).startswith("/tmp/jidr-m4-accept."):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            killed.append(pid)
        except OSError:
            pass
if killed:
    print(f"preflight: asked stale m4-accept emulators to exit: {killed}", file=sys.stderr)
PY

  local avail_gib
  avail_gib="$(df -g "$JIDR_HOME" | awk 'NR==2 {print $4}')"
  [ -n "$avail_gib" ] && [ "$avail_gib" -ge 8 ] || fail "not enough free space under /tmp: ${avail_gib:-?} GiB (need about 8 GiB for the image data + snapshot)"
  log "free space under /tmp: ${avail_gib} GiB"
}

# ---- cleanup --------------------------------------------------------------
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  set +e
  if [ "$code" -eq 0 ] && [ -n "${CURRENT_STEP:-}" ]; then
    log "cleanup: step '$CURRENT_STEP' never completed; treating it as a failure"
    code=1
    FAILED_STEP="$CURRENT_STEP"
  fi
  if [ -S "$JIDR_HOME/data/daemon.sock" ]; then
    log "cleanup: stopping device $DEVICE, emulators of $JIDR_HOME and the daemon"
    "$JIDR" --json device stop "$DEVICE" >/dev/null 2>&1
    "$JIDR" --json device delete "$DEVICE" --yes >/dev/null 2>&1
    "$JIDR" --json daemon stop >/dev/null 2>&1
  else
    log "cleanup: no daemon socket under $JIDR_HOME; nothing to stop"
  fi
  # Kill any emulator still running an AVD under this run's home.
  python3 -I - "$JIDR_HOME" <<'PY' || true
import glob, os, signal, sys, time
home = os.path.realpath(sys.argv[1])
dirs = [
    os.path.expanduser("~/Library/Caches/TemporaryItems/avd/running"),
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"), "avd/running"),
    f"/tmp/android-{os.environ.get('USER', '')}/avd/running",
]
def pids():
    found = []
    for d in dirs:
        for f in glob.glob(os.path.join(d, "pid_*.ini")):
            try:
                vals = dict(line.strip().split("=", 1) for line in open(f) if "=" in line)
                pid = int(os.path.basename(f)[4:-4])
            except (OSError, ValueError):
                continue
            if os.path.realpath(vals.get("avd.dir", "/")).startswith(home):
                try:
                    os.kill(pid, 0)
                    found.append(pid)
                except OSError:
                    pass
    return found
found = pids()
for pid in found:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
deadline = time.time() + 15
while time.time() < deadline and pids():
    time.sleep(0.5)
for pid in pids():
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
if found:
    print(f"cleanup: stopped emulator pid(s) {found}", file=sys.stderr)
# Remove this run's stale AVD "running" pid files (killed emulators leave them).
for d in dirs:
    for f in glob.glob(os.path.join(d, "pid_*.ini")):
        try:
            vals = dict(line.strip().split("=", 1) for line in open(f) if "=" in line)
        except OSError:
            continue
        if os.path.realpath(vals.get("avd.dir", "/")).startswith(home):
            try:
                os.remove(f)
                print(f"cleanup: removed stale {f}", file=sys.stderr)
            except OSError:
                pass
PY
  # Belt and braces: an emulator launched for this device name.
  pkill -f -- "-avd $DEVICE" 2>/dev/null || true
  if [ "${JIDR_M4_KEEP:-0}" != 1 ]; then
    if can_remove_home "$JIDR_HOME"; then
      rm -rf -- "$JIDR_HOME"
    else
      log "cleanup: refusing to remove unexpected home: $JIDR_HOME"
    fi
  else
    log "cleanup: keeping JIDR_HOME=$JIDR_HOME (JIDR_M4_KEEP=1)"
  fi
  write_summary "$([ "$code" -eq 0 ] && echo ok || echo failed)" "$FAILED_STEP"
  log "cleanup done (exit $code)"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- steps ----------------------------------------------------------------
# ---- offline self-check (no daemon, no emulator) -------------------------
self_check() {
  local tmp fail_count=0
  tmp="$(mktemp -d /tmp/jidr-m4-selfcheck.XXXXXX)"
  log "self-check: helpers"

  printf '%s\n' '{"jidr_json":1,"ok":true,"result":{"name":"d"}}' > "$tmp/good.json"
  printf '%s\n' '{"jidr_json":1,"ok":false,"error":{"message":"nope"}}' > "$tmp/bad-ok.json"
  printf '%s\n' 'not json' > "$tmp/bad-json.json"
  envelope_ok "$tmp/good.json" || { log "self-check FAIL: a valid envelope was rejected"; fail_count=$((fail_count + 1)); }
  if envelope_ok "$tmp/bad-ok.json" 2>/dev/null; then log "self-check FAIL: ok=false was accepted"; fail_count=$((fail_count + 1)); fi
  if envelope_ok "$tmp/bad-json.json" 2>/dev/null; then log "self-check FAIL: non-JSON was accepted"; fail_count=$((fail_count + 1)); fi

  # field(): object and array results, the shapes the steps assert on.
  printf '%s\n' '{"jidr_json":1,"ok":true,"result":{"uid":0,"name":"x"}}' > "$tmp/last.json"
  [ "$(field 'r["uid"]' "$tmp/last.json")" = "0" ] || { log "self-check FAIL: field object lookup"; fail_count=$((fail_count + 1)); }
  printf '%s\n' '{"jidr_json":1,"ok":true,"result":[{"status":{"state":"running"}}]}' > "$tmp/last.json"
  [ "$(field 'r[0]["status"]["state"]' "$tmp/last.json")" = "running" ] || { log "self-check FAIL: field array lookup"; fail_count=$((fail_count + 1)); }

  # The ramdisk preflight: /tmp/m4-sdk must pass; the user's patched SDK must
  # be refused with a bootimg diagnostic; a missing path must be refused.
  local restored patched problem
  restored="$(image_ramdisk_path "$IMAGE")"
  [ -n "$restored" ] && [ -e "$restored" ] || { log "self-check FAIL: no installed image for $IMAGE under $SDK"; fail_count=$((fail_count + 1)); }
  [ -z "$(ramdisk_problem "$restored")" ] || { log "self-check FAIL: $restored was rejected"; fail_count=$((fail_count + 1)); }
  patched="/Volumes/External/SDK/android-sdk/system-images/android-36/google_apis/$ABI/ramdisk.img"
  if [ -e "$patched" ]; then
    problem="$(ramdisk_problem "$patched")"
    case "$problem" in
      *bootimg*) log "self-check: patched-SDK ramdisk refused correctly (${problem})" ;;
      *) log "self-check FAIL: patched-SDK ramdisk got: '${problem:-accepted}'"; fail_count=$((fail_count + 1)) ;;
    esac
  else
    log "self-check: no patched-SDK sample at $patched (skipped)"
  fi
  printf 'not-a-ramdisk' > "$tmp/patched.img"
  [ -n "$(ramdisk_problem "$tmp/patched.img")" ] || { log "self-check FAIL: a non-LZ4 file was accepted as a ramdisk"; fail_count=$((fail_count + 1)); }
  [ -n "$(ramdisk_problem "$tmp/missing.img")" ] || { log "self-check FAIL: a missing ramdisk was accepted"; fail_count=$((fail_count + 1)); }

  # cleanup safety: only /tmp/jidr-m4-accept.* homes may be removed.
  can_remove_home "/tmp/jidr-m4-accept.abc123" || { log "self-check FAIL: our own home was refused"; fail_count=$((fail_count + 1)); }
  if can_remove_home "$HOME/Library/Application Support/JIdr"; then log "self-check FAIL: the real Jidr home would be removed"; fail_count=$((fail_count + 1)); fi
  if can_remove_home "/tmp/jidr-m4-bench.abc"; then log "self-check FAIL: another M4 home pattern would be removed"; fail_count=$((fail_count + 1)); fi

  rm -rf -- "$tmp"
  [ "$fail_count" -eq 0 ] || fail "self-check: $fail_count check(s) failed"
  log "self-check: PASS (envelope, field, ramdisk preflight, cleanup guard)"
}

if [ "$MODE" = "self-check" ]; then
  self_check
  SUMMARY_WRITTEN=1  # no acceptance summary for a helper self-check
  rmdir -- "$ART" 2>/dev/null || true
  log "self-check done; no daemon and no emulator were started"
  exit 0
fi

preflight
if [ "$MODE" = "preflight-only" ]; then
  SUMMARY_WRITTEN=1  # no acceptance summary for a preflight
  rmdir -- "$ART" 2>/dev/null || true
  log "preflight-only: PASS (no daemon and no emulator were started)"
  exit 0
fi

# Prefer an up-to-date prebuilt binary: a rebuild of jidr-proto needs protoc,
# which is a local, uncommitted tool here (target/tools/protoc/bin/protoc).
# JIDR_M4_FORCE_BUILD=1 always rebuilds.
NEEDS_BUILD=1
if [ -x "$JIDR" ] && [ "${JIDR_M4_FORCE_BUILD:-0}" != 1 ]; then
  if [ -z "$(find "$ROOT/crates" "$ROOT/apps/jidr" -name '*.rs' -newer "$JIDR" -print -quit 2>/dev/null)" ]; then
    NEEDS_BUILD=0
    log "using the up-to-date prebuilt $JIDR ($(stat -f '%Sm' "$JIDR"))"
    log "set JIDR_M4_FORCE_BUILD=1 to rebuild (needs protoc)"
  fi
fi
if [ "$NEEDS_BUILD" = 1 ]; then
  PROTOC_BIN=""
  if [ -n "${PROTOC:-}" ] && [ -x "$PROTOC" ]; then
    PROTOC_BIN="$PROTOC"
  elif [ -x "$ROOT/target/tools/protoc/bin/protoc" ]; then
    PROTOC_BIN="$ROOT/target/tools/protoc/bin/protoc"
  else
    PROTOC_BIN="$(command -v protoc 2>/dev/null || true)"
  fi
  if [ -n "$PROTOC_BIN" ]; then
    export PROTOC="$PROTOC_BIN"
    log "protoc: $PROTOC_BIN"
  fi
  note "building jidr (inherited ANDROID_HOME=$INHERITED_ANDROID_HOME)"
  if cargo build -q -p jidr; then
    log "built $JIDR"
  elif [ -x "$JIDR" ]; then
    log "WARNING: cargo build failed; using the existing prebuilt binary $JIDR"
    log "WARNING: a rebuild needs protobuf — install it or set PROTOC (e.g. $ROOT/target/tools/protoc/bin/protoc)"
  else
    fail "cargo build -p jidr failed and no prebuilt $JIDR exists (install protobuf or set PROTOC; CI installs it)"
  fi
fi
[ -x "$JIDR" ] || fail "jidr binary missing: $JIDR"
JIDR_VERSION="$("$JIDR" --version 2>/dev/null | head -1)"
log "jidr: $JIDR_VERSION ($JIDR)"

# From here on, the daemon (auto-started by the CLI) must see the merged SDK.
export ANDROID_HOME="$SDK"
export JIDR_TEST_SDK="$SDK"
log "runtime ANDROID_HOME=$ANDROID_HOME"

# 1 — create ---------------------------------------------------------------
begin_step create
jidr_json device create "$DEVICE" --image "$IMAGE" --profile "$PROFILE"
save_json create
python3 -I - "$RUN/last.json" "$DEVICE" <<'PY' || fail "device create returned an unexpected device: $LAST"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
r = r[0] if isinstance(r, list) else r
assert r.get("name") == sys.argv[2], r
assert r.get("status", {}).get("state") in ("stopped", "starting"), r
PY
note "created $(field 'r["name"]') root=$(field 'r["root"]["mode"]') image=$(field 'r["image"]["api"]')/$(field 'r["image"]["tag"]')"
end_step "root=$(field 'r["root"]["mode"]')"

# 2 — start ----------------------------------------------------------------
begin_step start
START_AT=$SECONDS
jidr_json device start "$DEVICE" --timeout 300
save_json start
BOOT_SECONDS=$(( SECONDS - START_AT ))
[ "$(field 'r[0]["status"]["state"]')" = "running" ] || fail "device did not report running: $LAST"
note "booted $(field 'r[0]["runtime"]["adb_serial"]') in ${BOOT_SECONDS} s"
end_step "boot ${BOOT_SECONDS}s"

# 3 — connect-info ---------------------------------------------------------
begin_step connect-info
jidr_json device connect-info "$DEVICE"
save_json connect-info
ADB_PATH="$(field 'r["adb_path"]')"
ADB_SERIAL="$(field 'r["adb_serial"]')"
ENDPOINT="$(field 'r["grpc_endpoint"]')"
[ -x "$ADB_PATH" ] || fail "connect-info adb_path is not executable: $ADB_PATH"
[ -n "$ADB_SERIAL" ] || fail "connect-info has no adb_serial"
[ -n "$(field 'r["grpc_token"]')" ] || fail "connect-info has no grpc_token"
python3 -I - "$ENDPOINT" <<'PY' || fail "gRPC endpoint $ENDPOINT is not accepting TCP connections"
import socket, sys
host, port = sys.argv[1].rsplit(":", 1)
socket.create_connection((host, int(port)), timeout=5).close()
PY
note "grpc=$ENDPOINT adb=$ADB_SERIAL ($ADB_PATH) console=$(field 'r["console_port"]')"
end_step "grpc=$ENDPOINT"

# 4 — apps -----------------------------------------------------------------
begin_step apps
jidr_json call app.list "{\"device\":\"$DEVICE\"}"
save_json app-list
note "app.list: $(field 'len(r["apps"])') third-party app(s)"
jidr_json call app.launch "{\"device\":\"$DEVICE\",\"package\":\"com.android.settings\"}"
save_json app-launch
[ "$(field 'r["launched"]')" = "com.android.settings" ] || fail "app.launch launched the wrong package: $LAST"
[ "$(field 'r["focused"]')" = "True" ] || fail "com.android.settings did not report focused: $LAST"
FOCUS="$(adb_run shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
log "  dumpsys: ${FOCUS:-mCurrentFocus not reported}"
case "$FOCUS" in *com.android.settings*) note "com.android.settings is the focused window" ;; *) note "focused flag true; dumpsys did not name the window" ;; esac
end_step "settings focused"

# 5 — screenshot -----------------------------------------------------------
begin_step screenshot
SHOT="$RUN/screenshot.png"
jidr_json call media.screenshot "{\"device\":\"$DEVICE\",\"path\":\"$SHOT\"}"
save_json screenshot
[ "$(field 'r["path"]')" = "$SHOT" ] || fail "media.screenshot wrote to an unexpected path: $LAST"
[ -f "$SHOT" ] || fail "media.screenshot did not create $SHOT"
[ "$(wc -c < "$SHOT" | tr -d ' ')" -ge 10240 ] || fail "screenshot is suspiciously small: $(wc -c < "$SHOT") bytes"
head -c 8 "$SHOT" | od -An -tx1 | tr -d ' \n' | grep -qi '^89504e470d0a1a0a$' || fail "screenshot is not a PNG: $SHOT"
cp "$SHOT" "$EVID/screenshot.png"
DIMS="$(sips -g pixelWidth -g pixelHeight "$EVID/screenshot.png" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd 'x' -)"
note "screenshot: $(wc -c < "$SHOT" | tr -d ' ') bytes, ${DIMS:-unknown size} → target/m4/screenshot.png"
end_step "${DIMS} $(wc -c < "$SHOT" | tr -d ' ')B"

# 6 — snapshot round trip --------------------------------------------------
begin_step snapshot
MARKER="m4-marker-$TS"
MARKER_FILE="/sdcard/m4-acceptance-marker.txt"
adb_run shell "echo '$MARKER' > $MARKER_FILE" || fail "could not write the guest marker"
GOT="$(adb_run shell cat "$MARKER_FILE" 2>/dev/null | tr -d '\r')"
[ "$GOT" = "$MARKER" ] || fail "guest marker did not read back before the snapshot: '$GOT'"
note "guest marker written: $MARKER"

jidr_json snapshot save "$DEVICE" m4-marker
save_json snapshot-save
[ "$(field 'r["name"]')" = "m4-marker" ] || fail "snapshot save returned the wrong name: $LAST"
note "snapshot m4-marker saved in $SECONDS s (total elapsed)"

jidr_json call snapshot.list "{\"device\":\"$DEVICE\"}"
save_json snapshot-list
python3 -I - "$RUN/last.json" <<'PY' || fail "snapshot list does not contain m4-marker: $LAST"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
snaps = r["snapshots"]
assert any(s.get("name") == "m4-marker" for s in snaps), snaps
match = next(s for s in snaps if s.get("name") == "m4-marker")
assert match.get("root_mode") == r.get("device_root_mode"), (match, r)
PY
note "snapshot list: $(field 'len(r["snapshots"])') entries, device_root_mode=$(field 'r["device_root_mode"]')"

adb_run shell "rm -f $MARKER_FILE" || fail "could not delete the guest marker"
[ -z "$(adb_run shell cat "$MARKER_FILE" 2>/dev/null | tr -d '\r')" ] || fail "marker still readable after deletion"
note "marker deleted; restoring"

jidr_json snapshot load "$DEVICE" m4-marker
save_json snapshot-load
[ "$(field 'r["name"]')" = "m4-marker" ] || fail "snapshot load returned the wrong name: $LAST"

RESTORED=""
for _ in $(seq 1 90); do
  RESTORED="$(adb_run shell cat "$MARKER_FILE" 2>/dev/null | tr -d '\r' || true)"
  [ "$RESTORED" = "$MARKER" ] && break
  sleep 1
done
[ "$RESTORED" = "$MARKER" ] || fail "guest marker was not restored by snapshot.load (read '$RESTORED', wanted '$MARKER')"
adb_run shell "rm -f $MARKER_FILE" || true
note "snapshot restore proven: marker $MARKER is back"
end_step "save+load marker restored"

# 7 — root -----------------------------------------------------------------
begin_step root
jidr_json root verify "$DEVICE"
save_json root-verify-initial
INITIAL_UID="$(field 'r["uid"]')"
note "root.verify before set: mode=$(field 'r["mode"]') uid=$INITIAL_UID"
jidr_json root set "$DEVICE" adb
save_json root-set-adb
SET_UID="$(field 'r["verification"]["uid"]')"
[ "$SET_UID" = "0" ] || fail "root.set adb did not report uid 0: $LAST"
jidr_json root verify "$DEVICE"
save_json root-verify
[ "$(field 'r["uid"]')" = "0" ] || fail "root.verify after root.set adb did not report uid 0: $LAST"
note "adbd root verified: uid 0 (command $(field 'r["command"]'))"
end_step "uid 0"

# 8 — record ---------------------------------------------------------------
begin_step record
VIDEO="$RUN/record.mp4"
( set +e
  "$JIDR" --json call media.record "{\"device\":\"$DEVICE\",\"path\":\"$VIDEO\",\"max_seconds\":300}" \
      > "$RUN/record.json" 2> "$RUN/record.err"
  echo $? > "$RUN/record.code"
) &
REC_PID=$!
sleep 1
jidr_json jobs list
save_json jobs-recording
python3 -I - "$RUN/last.json" <<'PY' || fail "media.record did not start a running job"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
jobs = json.loads(lines[-1])["result"]
match = [j for j in jobs if j.get("kind") == "media.record"]
assert match and match[0].get("state") in ("pending", "running"), jobs
PY
sleep 2
jidr_json call media.record_stop "{\"device\":\"$DEVICE\"}"
save_json record-stop
[ "$(field 'r["stopping"]')" = "True" ] || fail "media.record_stop did not report stopping: $LAST"
for _ in $(seq 1 120); do
  kill -0 "$REC_PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$REC_PID" 2>/dev/null; then
  kill "$REC_PID" 2>/dev/null || true
  fail "media.record did not finish after media.record_stop"
fi
wait "$REC_PID" 2>/dev/null || true
REC_CODE="$(cat "$RUN/record.code" 2>/dev/null || echo 1)"
[ "$REC_CODE" = 0 ] || fail "media.record exited $REC_CODE: $(cat "$RUN/record.json" 2>/dev/null)"
cp "$RUN/record.json" "$ART/media-record.json"
python3 -I - "$RUN/record.json" <<'PY' || fail "media.record result is missing frames: $(cat "$RUN/record.json")"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
assert r.get("frames", 0) > 0, r
assert r.get("duration_s", 0) >= 2, r
PY
[ -f "$VIDEO" ] || fail "recording file missing: $VIDEO"
[ "$(wc -c < "$VIDEO" | tr -d ' ')" -ge 10240 ] || fail "recording is suspiciously small: $(wc -c < "$VIDEO") bytes"
head -c 12 "$VIDEO" | od -An -tx1 | tr -d ' \n' | grep -q '66747970' || fail "recording is not an MP4: $VIDEO"
cp "$VIDEO" "$EVID/record.mp4"
REC_NOTE="$(python3 -I - "$RUN/record.json" <<'PY'
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
print(f'{r["frames"]} frames, {r["duration_s"]}s')
PY
)"
note "recording: $(wc -c < "$VIDEO" | tr -d ' ') bytes, $(file -b "$VIDEO") → target/m4/record.mp4"
end_step "$REC_NOTE"

# 9 — stop -----------------------------------------------------------------
begin_step stop
jidr_json device stop "$DEVICE"
save_json stop
python3 -I - "$RUN/last.json" "$DEVICE" <<'PY' || fail "device stop did not report a stopped device: $LAST"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
r = json.loads(lines[-1])["result"]
r = r[0] if isinstance(r, list) else r
assert r.get("status", {}).get("state") == "stopped", r
PY
STOPPED=0
for _ in $(seq 1 30); do
  if python3 -I "$ROOT/scripts/lib/no_jidr_emulators.py" "$JIDR_HOME" 2>/dev/null; then STOPPED=1; break; fi
  sleep 1
done
[ "$STOPPED" = 1 ] || fail "a Jidr emulator is still running after device stop"
note "device stopped; no Jidr emulator of this home is running"
end_step

# 10 — delete --------------------------------------------------------------
begin_step delete
jidr_json device delete "$DEVICE" --yes
save_json delete
jidr_json device list
[ "$(field 'len(r)')" = "0" ] || fail "device list is not empty after delete: $LAST"
note "device and its data deleted; device list is empty"
end_step

# 11 — daemon quit ---------------------------------------------------------
begin_step daemon-quit
QUIT_CODE=0
QUIT_OUT="$("$JIDR" --json call daemon.quit 2>&1)" || QUIT_CODE=$?
printf '%s\n' "$QUIT_OUT" > "$ART/daemon-quit.json"
if [ "$QUIT_CODE" -eq 0 ]; then
  python3 -I - "$ART/daemon-quit.json" <<'PY' || fail "daemon.quit returned a bad envelope: $QUIT_OUT"
import json, sys
lines = [line for line in open(sys.argv[1]).read().splitlines() if line.strip()]
v = json.loads(lines[-1])
assert v.get("jidr_json") == 1 and v.get("ok") is True, v
assert v.get("result", {}).get("stopping") is True, v
PY
else
  note "daemon.quit client exit $QUIT_CODE (the connection may close while the daemon stops): $QUIT_OUT"
fi
GONE=0
for _ in $(seq 1 30); do
  if [ ! -S "$JIDR_HOME/data/daemon.sock" ]; then GONE=1; break; fi
  sleep 0.5
done
[ "$GONE" = 1 ] || fail "the daemon socket is still there after daemon.quit: $JIDR_HOME/data/daemon.sock"
note "daemon quit: socket gone"
end_step

# ---- result --------------------------------------------------------------
write_summary ok
TOTAL=$(( SECONDS - TOTAL_START ))
log "ACCEPTANCE PASSED in ${TOTAL} s; 11/11 steps ok"
log "log: $LOG"
log "evidence: $ART/"
log "rerun: JIDR_TEST_SDK=$SDK bash scripts/m4-swiftui-acceptance.sh"
exit 0
