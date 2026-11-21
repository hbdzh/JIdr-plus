# 洁净室开发规则

本项目重新实现 Genymotion Desktop 公开功能的*行为*，不得从其代码或不打算继承许可的 GPL 代码派生实现。

## 允许参考的来源

| 来源 | 用途 |
|---|---|
| Genymotion 公开文档（docs.genymotion.com、genymotion.com/pricing、/features） | 功能列表、用户可见行为、CLI 命令名称和退出码语义 |
| AOSP 模拟器公开协议（SDK 附带的 `emulator_controller.proto`、`snapshot_service.proto`） | gRPC API；据此生成代码（Apache-2.0） |
| AOSP 模拟器源码（`platform/external/qemu`） | 独立许可的模拟器构建及源码记录；不得将 GPL 代码复制到 Apache 许可的 crate 中，发行须通过下述检查。 |
| developer.android.com 模拟器文档（命令行、控制台、AVD 管理） | 参数、控制台命令及 config.ini 键 |
| 用户机器上运行的 Android SDK 工具（`sdkmanager`、`avdmanager`、`adb`、`emulator`） | 观察行为和输出 |
| Magisk 和 rootAVD 脚本（GPL-3.0） | **只读**，了解公开记录的 ramdisk 布局；不得复制或翻译代码。 |
| avdroot（MIT） | 可参考并移植，但须在 `NOTICE` 中注明来源。 |
| 公开规范（cpio newc、gzip、lz4 legacy、xz） | 格式实现 |

## 禁止事项

- 反编译、反汇编、提取字符串或以其他方式检查 Genymotion 的二进制文件、安装包、镜像或网络流量。
- 向 Apache-2.0 crate 复制或逐行翻译 GPL 代码（Magisk、rootAVD）。
- 捆绑或再发行 Android 系统镜像。可以将固定哈希的官方 Magisk APK 作为独立 GPL 组件捆绑，附上许可证、署名以及获取对应源码的说明；不得将 GPL 代码复制进 Apache 许可的 crate。只有在核实并记录模拟器和 platform-tools 二进制文件的准确来源、适用的组件许可证、对应源码义务和声明后，才能捆绑它们；未经审核的运行时不得公开再发行。
- 在产品或网站的任何位置使用 Google、Android 或 Genymotion 标志。

<a id="log"></a>

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
