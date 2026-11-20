# Clean-room policy

Jidr re-creates the *behaviour* of Genymotion Desktop's public feature set. It must never derive from Genymotion's code, or from GPL code we don't want to inherit.

## Allowed sources

| Source | Use |
|---|---|
| Genymotion public docs (docs.genymotion.com, genymotion.com/pricing, /features) | Feature lists, user-visible behaviour, CLI command names, exit-code semantics |
| AOSP emulator public protos (`emulator_controller.proto`, `snapshot_service.proto`, shipped in the SDK) | gRPC API; we generate code from them (Apache-2.0) |
| AOSP emulator source (`platform/external/qemu`) | Separately licensed emulator build and source records; do not copy GPL code into Apache-licensed crates. Distribution requires the checks below. |
| developer.android.com emulator docs (command line, console, AVD management) | Flags, console commands, config.ini keys |
| Android SDK tools (`sdkmanager`, `avdmanager`, `adb`, `emulator`), run on the user's machine | Observed behaviour, outputs |
| Magisk and rootAVD scripts (GPL-3.0) | **Read only**, to learn the documented ramdisk layout. Never copy or translate code. |
| avdroot (MIT) | Prior art; may be ported with attribution in `NOTICE` |
| Public specs (cpio newc, gzip, lz4 legacy, xz) | Format implementations |

## Forbidden

- Decompiling, disassembling, string-dumping or otherwise inspecting Genymotion binaries, installers, images or network traffic.
- Copying or line-by-line translating GPL code (Magisk, rootAVD) into Apache-2.0 crates.
- Bundling or redistributing Android system images. An official, hash-pinned Magisk APK may be bundled as a separate GPL-licensed component with its licence, attribution and corresponding source materials; never copy GPL code into Apache-licensed crates. Emulator and platform-tools binaries may be bundled only after their exact provenance, applicable component licences, corresponding-source obligations and notices have been verified and recorded; an unreviewed runtime remains prohibited from public redistribution.
- Google, Android or Genymotion logos anywhere in the product or site.

## Log

Record any non-obvious source you used, so provenance can be audited later.

| Date | Stream | Source | What it informed |
|---|---|---|---|
| 2026-11-17 | Integration | Upstream Jidr Apache-2.0 [v0.7.0](https://github.com/jidr-dev/jidr/tree/v0.7.0) and [recording audio](https://github.com/jidr-dev/jidr/commit/13e3b79d84378829728e5ce1ac6a8ff253bdd806) | Ported and adapted network shaping, device IDs, sync, gamepad, ZIP classification and recording audio. GUI is independently adapted to SwiftUI. |
| 2026-10-13 | A | SDK `emulator/lib/emulator_controller.proto`, `snapshot_service.proto` (emulator 35.6.11) | gRPC bindings (`jidr-proto`) |
| 2026-10-13 | C | `man 5 cpio` (newc), the Linux kernel's initramfs buffer-format doc, RFC 1952 (gzip), the lz4 frame-format doc (legacy frame), the `.xz` format spec; the local SDK `ramdisk.img` files, read-only, decompressed with the `lz4`/`gzip` CLIs to observe the layout | `jidr-cpio` (Phase 9b) |
| 2026-10-14 | C | Magisk's `scripts/boot_patch.sh` (read-only, GPL) and avdroot's `internal/{magisk,cpio,adb}` (MIT) — the documented ramdisk entries (`init` → `magiskinit`, `overlay.d/sbin/{magisk,stub,init-ld}.xz`, `.backup/.magisk`), the payload/ABI layout inside the APK, the `/data/adb/magisk` environment, and the su-policy grant (`magisk --sqlite`). avdroot's algorithm is ported with attribution in `NOTICE`; no GPL code was copied. | `jidr-root` Magisk mode (Phase 9d) |
| 2026-10-15 | C | Magisk v30.7 `app/core` `Config.kt`, `SuRequestHandler.kt`, `PreferenceConfig.kt` and `native/src/core/su/db.rs` (read-only, GPL) — learned that the superuser "automatic response" is the SharedPreferences key `su_auto_response` (values `0` prompt / `1` deny / `2` allow), not a `magisk --sqlite` `settings` row; the native `uid_granted_root` only consults per-uid `policies`. No GPL code was copied. | `jidr-root` `root.auto_grant` (G15) |
| 2026-11-02 | B | `emulator_controller.proto` comments on `Touch.x`/`y` ("physical location on the screen") and `ImageFormat.rotation`; a temp tablet AVD with `pointer_location` on and `dumpsys input`, read over `adb` | Player touches are sent in unrotated panel pixels, mapped through the frame's rotation (#51) |
| 2026-11-04 | C | The Android emulator's public command-line docs (`-writable-system`) and AOSP's public adb and `fs_mgr` overlayfs docs (`adb remount`, `adb enable-verity`, the reboot the first remount asks for) | `jidr-root` `root.writable_system` (#25) |
| 2026-11-04 | B | `emulator_controller.proto` comments on `injectAudio`, `AudioPacket` and `AudioFormat` (U8/S16, mono/stereo, the ~300 ms buffer, format honoured on the first packet only, `MODE_REAL_TIME` experimental, `INVALID_ARGUMENT` / `FAILED_PRECONDITION`); Microsoft's public RIFF/WAVE and `WAVEFORMATEXTENSIBLE` format docs | `audio.inject` / `audio.stop` and the WAV parser in `jidr-backend` (#70) |
| 2026-11-15 | C | Upstream Jidr Apache-2.0 [fix #78](https://github.com/jidr-dev/jidr/commit/73b855d47172d759ec3e5a0da9af967306e690e0), citing AOSP Wi-Fi shutdown and buffered storage behavior | Android shutdown before Root cold boots, adapted to Plus lifecycle handling |
| 2026-11-15 | C | Upstream Jidr Apache-2.0 [Magisk base support](https://github.com/jidr-dev/jidr/commit/22b10e2b3234dbcf33d07b1a520b50a28e0936a7) | Pool bases and isolated clone ramdisks, with local ownership checks |
| 2026-11-15 | C | Upstream Jidr Apache-2.0 [on-device helper](https://github.com/jidr-dev/jidr/commit/6f3f9a0364d6db770b4d41ceeb1c58e2fbc90d73) and [network shaping](https://github.com/jidr-dev/jidr/commit/0a0aba92743a9210943068889f07974f3991e1c8) | Rooted guest helper and outgoing packet-loss control |
| 2026-11-09 | B | Android SDK emulator's public Apache-2.0 `emulator/lib/snapshot.proto` (`Snapshot.images`, `Image.path`, and `Snapshot.launch_parameters`); locally observed `qemu-img info --backing-chain` and an isolated temporary AVD snapshot | Lossless snapshot path relocation and staged QCOW2 verification; no emulator binary inspection. |
| 2026-11-16 | Snapshot investigation | AOSP public [`snapshot_service.proto`](https://android.googlesource.com/platform/tools/base/+/studio-master-dev/emulator/proto/snapshot_service.proto); isolated emulator save/restore observations. AOSP QEMU [`savevm.c`](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/migration/savevm.c) and [`Quickboot.cpp`](https://android.googlesource.com/platform/external/qemu/+/refs/heads/aosp-emu-30-release/android/android-emu/android/snapshot/Quickboot.cpp) were also consulted in error, outside the allowed source list; no implementation code was copied or translated. | Diagnose quick-boot snapshot storage and recovery; implementation-file contents must not be used to implement a fix. |

| 2026-11-10 | SwiftUI validation | Magisk public [developer guide](https://topjohnwu.github.io/Magisk/guides.html) (module metadata and removal marker); no source code copied | An empty isolated test module and its removal after reboot. |
| 2026-11-10 | Storage validation | QEMU public [qemu-img documentation](https://www.qemu.org/docs/master/tools/qemu-img.html) (check exit codes and leak-only repair); no source code copied | Diagnose an isolated disk-image copy without changing the original; leak-only findings remain a migration stop. |
| 2026-11-20 | B | Android Emulator's public `EmulatorStatus.guestConfig` in `emulator_controller.proto` and an isolated Apple Silicon build from AOSP | A patched emulator reports its audio input fallback through `getStatus` so miko can inject audio without a host microphone. |
| 2026-11-20 | Audio playback | Public AOSP emulator source at `5e5120287952` and isolated Android 36 playback on 44.1 kHz HDMI | Updated the standalone local emulator to preserve the CoreAudio output buffer size on short writes and refill playback every 5 ms. |
