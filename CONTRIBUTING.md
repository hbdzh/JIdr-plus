# 参与 miko 模拟器开发

欢迎提交问题、修复、功能和文档。本指南说明环境、项目约定和 PR 流程；项目文档入口见[文档总览](docs/README.md)。

## 开始之前

- **报告问题**：请提供 macOS 版本、Mac 型号、Android 镜像（如 `35:google_apis`）、操作步骤和实际结果。`miko --json …` 输出与后台日志有助于排查。
- **提出功能**：先查看 [GitHub Issues](https://github.com/hbdzh/miko-simulator/issues)；较大的变更建议先讨论方案。
- **报告安全问题**：不要创建公开 Issue，请按照[安全策略](SECURITY.md)私下报告。

## 准备环境

应用面向 macOS 13 及以上的 Apple Silicon Mac；arm64 模拟器测试需要合适的 macOS 测试环境。CLI、后台服务和离线测试也可在 Linux 上构建。

```bash
brew install protobuf                     # gRPC 绑定所需的 protoc
curl https://sh.rustup.rs -sSf | sh       # 首次构建时安装项目固定的 Rust 工具链
cargo install cargo-nextest --locked      # 测试运行器
git clone https://github.com/hbdzh/miko-simulator.git && cd miko-simulator
cargo xtask ci                            # 格式、clippy、测试和许可证检查
bash apps/miko-swiftui/test.sh             # Swift 逻辑和本地化检查，需要 Xcode
```

模拟器测试需要包含模拟器和系统镜像的 Android SDK。可以只读使用 Android Studio 的 SDK，测试不会修改它。默认镜像为 `system-images;android-31;google_apis;arm64-v8a`；可通过 `MIKO_TEST_SDK`、`MIKO_TEST_IMAGE` 和 `MIKO_TEST_API` 指定测试环境。

```bash
cargo nextest run -p miko-widgets --features emulator
```

## 项目结构与约定

项目由 `crates/` 中的核心、后台和客户端、`apps/miko` 命令行及 `apps/miko-swiftui` 原生界面组成；[架构决策](docs/decisions/)记录产品和技术决定。若改动与已有决策冲突，请先提出讨论。

- **避免崩溃**：测试之外禁止 `unwrap`、`expect`、`panic!`、`todo!`、`unimplemented!` 和 `dbg!`；返回 `miko_core::MikoError`。
- **默认禁止 `unsafe`**：确有必要时仅在相关 crate 局部允许，并解释原因。
- **修复要有回归测试**。
- **许可证分离**：`apps/miko-swiftui` 的 Swift/AppKit 代码使用 GPL-3.0-only；Rust 桥、CLI、后台及其他 Apache crate 使用 Apache-2.0，不得依赖 Slint 或 GPL GUI crate。`cargo xtask license-check` 检查此边界。
- **Clean room**：使用 Genymotion 公开文档、公开 AOSP 模拟器 proto 和公开 SDK 工具的可观察行为；不得反编译或检查 Genymotion 二进制文件，不得复制 Magisk、rootAVD 的 GPL 代码，也不得打包系统镜像。固定校验值的官方 Magisk APK 可作为独立组件随许可证及源码获取说明一起提供；模拟器工具须完成相应审核。详见 [clean-room 规则](docs/clean-room.md)。
- **协议变更**：修改线协议、现有命令参数或结果、错误码或事件时，更新[控制协议](docs/control-protocol.md)的变更记录；用 `MIKO_UPDATE_DOCS=1 cargo nextest run -p miko-daemon protocol_doc` 更新命令参考。
- **Android Studio SDK 与 AVD 只读**：测试在临时目录中创建 AVD，不修改用户现有数据。
- **保持仓库精简**：本地协作指令、个人工具和临时产物留在本机；提交时只包含产品、用户文档、构建测试或许可证履约所需文件。

## 提交 PR

1. 从仓库默认分支创建工作分支，保持改动聚焦。
2. 使用[约定式提交](https://www.conventionalcommits.org/)，如 `feat(widgets): …`、`fix(root): …`、`docs: …`、`test: …` 或 `ci: …`；类型影响版本和变更日志。
3. 运行 `cargo xtask ci`；若改动涉及模拟器测试且具备镜像，也运行相关测试。
4. 更新受影响的文档，向默认分支提交 PR，并说明实际验证结果。
5. CI 会运行 Linux 格式、clippy、测试和许可证检查、macOS clippy，以及 Linux KVM 模拟器测试（API 30、33、35）；纯文档或 Markdown 改动会跳过模拟器任务。合并前需要维护者审查。

共享 CI 的模拟器测试可能较慢；如果与本次改动无关的测试失败，请在 PR 中说明，维护者可重新运行。

## 发行

当前正式发行预检查因内置运行时再分发审核未完成而阻止发布；SwiftUI helper 的 Developer ID 签名和公证也尚未全部接通。本地演练输入、手动打包检查和当前限制见 [macOS 打包](packaging/macos/README.md)及 [SwiftUI 打包](packaging/swiftui/README.md)。

## 贡献的许可证

提交贡献即表示同意使用所修改文件对应的许可证：通常为 Apache-2.0；`apps/miko-swiftui` 的 Swift/AppKit 代码为 GPL-3.0-only，Rust 桥为 Apache-2.0。
