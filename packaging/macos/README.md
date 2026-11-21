# macOS 打包

当前应用的打包入口是 `cargo xtask release`。应用包含 SwiftUI 界面、Rust 后台和桥接程序、固定版本的模拟器运行时、platform-tools 与 Magisk APK；Android 系统镜像由用户按需下载。具体输入、校验和目录结构见 [SwiftUI 打包说明](../swiftui/README.md)。

## 本地验证

先按 [SwiftUI 打包说明](../swiftui/README.md) 准备并设置 `MIKO_BUNDLED_SDK`；还需要通过 `MIKO_BUNDLED_MAGISK` 指定已校验的 Magisk APK，或使用默认的 `target/magisk-input/Magisk-v30.7.apk`。然后可以运行：

```bash
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

`--dry-run` 生成本地检查包；`--rehearsal` 还会执行隔离安装、启动和卸载检查。两者使用 ad-hoc 签名，不发布或替换已安装的软件。`report.md` 记录演练结果和未验证项。

## 自动流程和正式发行

[手动打包检查](../../.github/workflows/release-check.yml)准备固定版本的运行时和 Magisk，执行打包与扫描；当前检查产物留在运行器上。

正式发行工作流会先执行 `cargo xtask release --preflight`。当前预检查会阻止正式打包：运行时组件的来源、对应源码及许可证审核尚未完成。运行时构建与审核材料见[运行时溯源记录](../../docs/runtime-provenance-local.md)和[源码记录](../runtime-source/README.md)。

`sign.sh` 和 `verify.sh` 是保留的签名工具；现有 SwiftUI 正式打包尚未为全部桥接程序接通 Developer ID 签名、公证和装订。不能将本地 ad-hoc 演练视为这些检查已通过。
