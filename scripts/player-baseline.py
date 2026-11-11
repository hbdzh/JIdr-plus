#!/usr/bin/env python3
"""Release baseline on a disposable real emulator. Never uses the normal Jidr home."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def cleanup_device(call, device):
    cleanup = {}
    # The backend allows 120s to save quick-boot state plus 10s for a
    # forced exit. Await that operation before deleting its locked AVD.
    for command, timeout in [(('device', 'stop', device), 180),
                             (('device', 'delete', device, '--yes'), 60)]:
        try:
            call(*command, timeout=timeout)
            cleanup[command[1]] = 'ok'
        except Exception as error:
            cleanup[command[1]] = str(error)
            break
    return cleanup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--image", default="system-images;android-36;google_apis;arm64-v8a")
    parser.add_argument("--runs", type=int, default=3, choices=range(1, 11))
    parser.add_argument("--seconds", type=int, default=10, choices=range(3, 121))
    parser.add_argument("--taps", type=int, default=30, choices=range(1, 101))
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    image_path = sdk.joinpath(*args.image.split(";"))
    ramdisk = image_path / "ramdisk.img"
    if not ramdisk.is_file() or "LZ4 compressed" not in subprocess.check_output(["file", "-b", str(ramdisk)], text=True):
        parser.error("a clean installed image with an LZ4 ramdisk is required; no SDK downloads or license acceptance are performed")
    if shutil.disk_usage("/private/tmp").free < 12 * 1024**3:
        parser.error("at least 12 GiB free in /private/tmp is required")
    out = (args.out or ROOT / "target/performance" / datetime.now(timezone.utc).strftime("baseline-%Y%m%dT%H%M%SZ")).resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    for key in ["JIDR_HOME", "JIDR_CENTER_FIXTURE", "JIDR_PLAYER_FIXTURE", "JIDR_UI_PREVIEW", "ANDROID_AVD_HOME",
                "ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME", "ANDROID_SDK_HOME"]:
        env.pop(key, None)
    env["JIDR_BENCH_PROFILE"] = "release"
    env.update(ANDROID_HOME=str(sdk), JIDR_TEST_SDK=str(sdk))
    # Build before booting, so compilation cannot contaminate the timing runs.
    with (out / "build.log").open("w") as log:
        subprocess.run(["cargo", "build", "--release", "--locked", "-p", "jidr", "-p", "jidr-swiftui-bridge"],
                       cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["bash", "apps/jidr-swiftui/bench-player.sh", "--self-test"],
                       cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    cli = ROOT / "target/release/jidr"
    home = Path(tempfile.mkdtemp(prefix="jidr-perf.", dir="/private/tmp"))
    env.update(JIDR_HOME=str(home), JIDR_DAEMON_BIN=str(cli), ANDROID_HOME=str(sdk), JIDR_TEST_SDK=str(sdk))
    env.update(ANDROID_USER_HOME=str(home / "android-user"), ANDROID_EMULATOR_HOME=str(home / "emulator-home"))
    initial_ramdisk_hash = hashlib.sha256(ramdisk.read_bytes()).hexdigest()
    manifest = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "profile": "release", "measurement_path": "GameWindowController/PlayerTransport/ScreenView",
        "isolated_home": str(home), "sdk_read_only": str(sdk), "image": args.image,
        "configuration": {"profile": "phone-6.1-fhd", "panel": [1080, 2400], "ram_mb": 4096,
                          "cpus": 4, "quality": 1, "window_screen_points": [340, 752], "root": "none"},
        "ramdisk_sha256_before": initial_ramdisk_hash,
        "host": {"os": subprocess.check_output(["sw_vers"], text=True).strip(),
                 "ram_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
                 "logical_cpus": int(subprocess.check_output(["sysctl", "-n", "hw.logicalcpu"], text=True))},
        "unverified": ["manual game compatibility", "hardware keyboard/IME and copy/cut", "other Space/fullscreen transitions"],
    }
    write_json(out / "manifest.json", manifest)
    device = None
    success = False

    def call(*arguments, timeout=180):
        result = subprocess.run([str(cli), "--json", *arguments], env=env, cwd=ROOT,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"jidr {arguments[0]} failed: {result.stderr[-1000:]}")
        reply = json.loads(result.stdout.strip().splitlines()[-1])
        if not reply.get("ok"):
            raise RuntimeError(f"jidr {arguments[0]} failed: {reply.get('error')}")
        return reply["result"]

    try:
        print("Creating disposable real device under", home, flush=True)
        created = call("device", "create", "Release performance baseline", "--image", args.image,
                       "--profile", "phone-6.1-fhd", "--root", "none", "--agent-owned")
        if isinstance(created, list):
            created = created[0]
        device = created["id"]
        manifest["device_id"] = device
        details = call("device", "details", device)
        manifest["actual_avd_config"] = details["config"]
        for key, expected in {"hw.cpu.ncore": "4", "hw.ramSize": "4096", "hw.lcd.width": "1080", "hw.lcd.height": "2400"}.items():
            if details["config"].get(key) != expected:
                raise RuntimeError(f"baseline configuration mismatch: {key}")
        write_json(out / "manifest.json", manifest)
        started = time.monotonic()
        call("device", "start", device, timeout=300)
        manifest["boot_seconds"] = time.monotonic() - started
        call("call", "dev.set", json.dumps({"device": device, "show_taps": True}))
        for run in range(1, args.runs + 1):
            call("call", "app.launch", json.dumps({"device": device, "package": "com.android.settings"}))
            report = out / f"run-{run}.json"
            print(f"Release run {run}/{args.runs}: real player, {args.seconds}s fps, {args.taps} taps, 3 restores", flush=True)
            with (out / f"run-{run}.log").open("w") as log:
                subprocess.run(["bash", "apps/jidr-swiftui/bench-player.sh", "--device", device,
                                "--seconds", str(args.seconds), "--taps", str(args.taps), "--settle", "7",
                                "--fps-drive", "--restore-probes", "3", "--json-out", str(report)],
                               cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240, check=True)
            value = json.loads(report.read_text())
            if value["build"]["profile"] != "release" or value["build"]["tracked_dirty"] != "false" or value["exit_code"] != 0:
                raise RuntimeError("invalid release measurement")
            if value["latency"]["detected"] != args.taps or value["latency"]["missed"] != 0:
                raise RuntimeError("touch probes were missed; partial latency samples are not a passing baseline")
            if value["restore"]["attempts"] != 3 or value["restore"]["timeouts"] or value["restore"]["fresh_frame_ms"]["count"] != 3:
                raise RuntimeError("window restore measurements were incomplete")
            if not all(value["memory"][part].get("available") for part in ["player", "bridge"]):
                raise RuntimeError("physical footprint measurements were unavailable")
            print("  drawn fps:", round(value["fps"]["displayed_fps"], 2),
                  "touch p95 ms:", value["latency"]["p95_ms"], flush=True)
        success = True
    finally:
        cleanup = {}
        if device:
            cleanup = cleanup_device(call, device)
        try:
            call("daemon", "stop", timeout=30)
            cleanup["daemon_stop"] = "ok"
        except Exception as error:
            cleanup["daemon_stop"] = str(error)
        manifest["cleanup"] = cleanup
        manifest["ramdisk_sha256_after"] = hashlib.sha256(ramdisk.read_bytes()).hexdigest()
        manifest["sdk_ramdisk_unchanged"] = manifest["ramdisk_sha256_after"] == initial_ramdisk_hash
        if all(value == "ok" for value in cleanup.values()):
            shutil.rmtree(home)
            manifest["isolated_home_removed"] = True
        else:
            print("Cleanup incomplete; isolated home retained:", home, file=sys.stderr)
        manifest["complete"] = success and manifest["sdk_ramdisk_unchanged"] and manifest.get("isolated_home_removed", False)
        write_json(out / "manifest.json", manifest)
    print("Baseline evidence:", out, flush=True)
    return 0 if manifest["complete"] else 1


if __name__ == "__main__":
    sys.exit(main())
