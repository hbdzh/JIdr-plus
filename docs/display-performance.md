# Native player measurements

Build and run the current harness with `bash apps/jidr-swiftui/bench-player.sh --help`.
`--self-test` runs offline checks. Live measurements use an already running disposable
device and explicit panel size; latency probes require show-taps to be enabled. Results
are written with `--json-out PATH`. Compare like-for-like device, scene, screen refresh
rate, window size and quality. These measurements do not prove game/audio compatibility.

## Historical Slint measurements (2026-11-09)

The implementation and command described below were retired on 2026-11-11; this is
retained measurement evidence, not a runnable current entry point.


`cargo run -p jidr-ui --example display_bench -- "<running device name>"` opens a separate, read-only window connected to an already running device. It does not send keys, touch, clipboard operations or application launches. The test requests half the device's width and height. It measures three 10-second intervals: visible, minimized, and restored. Set `JIDR_DISPLAY_BENCH_SECS` to 3–60 to change each interval. CPU is process CPU as a percentage of one core; on systems without `ps` it is reported as unavailable. Frame rate and throughput are receiver-side measurements, not the Android game's own render rate. Minimize/restore transitions can cause a few frames in the adjacent interval.

The source uses the same `Session` and native occlusion notification used by the game window. Compare runs on the same device, screen, window size, game scene and machine; record emulator CPU and RAM separately. This benchmark does not prove touch latency, audio playback, game correctness, or long-running memory stability. It briefly creates an additional screenshot stream, which adds load to the running emulator.

A local debug-build observation on 2026-11-09, Android 15 arm64, 1080×2400 device, 540×1200 stream, 8 seconds per interval:

| Interval | Received fps | Displayed fps | MB/s | GUI CPU, one core = 100% |
| --- | ---: | ---: | ---: | ---: |
| Visible | 59.97 | 58.72 | 155.45 | 61.3% |
| Minimized, including animation | 4.37 | 0.25 | 11.34 | 0.7% |
| Restored, including animation | 56.00 | 55.88 | 145.15 | 55.8% |

This measures the optimization for a minimized/occluded window. It is not a claim that foreground streaming uses less CPU than the previous version. For a separate foreground baseline, hold a comparable scene and window size constant, and compare builds in isolated runs.
