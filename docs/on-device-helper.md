# 设备内辅助程序与丢包

miko 为 Android 客体构建一个 Apache-2.0 许可的 Rust 辅助程序。它在 Shell Root 或 Magisk 环境下按需启动，通过抽象 Unix socket 提供固定的类型化操作，Mac 端经 adb 转发到本机回环地址访问。客体会检查对端凭据，只接受 root 和 adb shell；Mac 端使用前检查可执行文件的 SHA-256 与协议。辅助程序不提供任意命令接口。源码和方法改编自上游 Jidr 的[辅助程序实现](https://github.com/jidr-dev/jidr/commit/6f3f9a0364d6db770b4d41ceeb1c58e2fbc90d73)。

`network.shaping.set` 使用客体中的 `tc` 和 `netem`，对具有 IPv4 默认路由的接口控制出站丢包。设备必须运行、具备 Root，内核也须支持 netem。miko 保存请求的丢包和 DNS 设置，并在启动后尝试恢复；53 和 853 端口支持模拟 DNS 延迟或失败。更改网络接口或路由后可能需要重新应用。多个接口部分失败时，部分设置可能已经生效，应读取状态后清除或重试。

设置丢包会替换所选接口的根 qdisc；清除操作会移除根 netem qdisc，因此不适合需要保留另行配置的自定义 qdisc 的场景。

开发构建对 arm64 客体使用 `cargo xtask helper --arch aarch64`，对 x86_64 客体使用 `--arch x86_64`。发行包将 arm64 辅助程序放入应用和 MCP 包；扫描器只允许它位于预定路径且与本次构建的文件一致。该辅助程序不是 Android SDK 二进制文件或系统镜像。
