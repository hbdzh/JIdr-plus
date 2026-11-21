# 内置的模拟器协议定义

这里保存 AOSP 模拟器公开 gRPC 定义的备用副本（Apache-2.0，版权所有 © The Android Open Source Project），取自 Android Emulator 35.6.11 的 `$ANDROID_SDK_ROOT/emulator/lib/`：

- `emulator_controller.proto`
- `snapshot_service.proto`
- `snapshot.proto`

`build.rs` 优先使用已安装 SDK 模拟器附带的协议；找不到 SDK 或设置 `MIKO_PROTO_VENDORED=1` 时使用这些副本。最低支持的模拟器版本发生变化时更新副本。
