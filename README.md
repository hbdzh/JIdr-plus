# JIdr Plus

在 Mac 上创建和管理 Android 虚拟设备。JIdr Plus 基于开源项目 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr)，提供 SwiftUI/AppKit 设备中心、独立模拟器窗口，以及 CLI 和 MCP 接口。

**[下载 0.5.0 安装包](https://github.com/hbdzh/JIdr-plus/releases/download/v0.5.0/Jidr-0.5.0-arm64.dmg)** · [查看所有版本](https://github.com/hbdzh/JIdr-plus/releases) · [设备中心指南](docs/device-center.md) · [报告问题](https://github.com/hbdzh/JIdr-plus/issues)

## 下载与安装

- **系统要求：**Apple Silicon Mac，macOS 13 或更高版本。Android SDK、模拟器和系统镜像需要额外磁盘空间。
- 下载上方 DMG，打开后将 Jidr 拖入“应用程序”文件夹，再启动 Jidr。
- 安装包使用临时签名，**未经 Apple Developer ID 签名和公证**；macOS 可能提示无法验证开发者。
- 根据设备中心提示配置或安装 Android SDK 和系统镜像。首次安装 Google SDK 组件时，需由用户本人阅读并接受相应许可。

设备数据默认位于 `~/Library/Application Support/Jidr`；替换应用程序不会自动删除该目录。升级或切换版本前，请保存模拟器中的工作。旧版可能无法兼容新版创建或修改的数据，回退前请自行备份需要保留的数据。

需要历史版本？[查看 0.4.0 历史重建版](https://github.com/hbdzh/JIdr-plus/releases/tag/v0.4.0)；它不包含 0.5.0 的后续修复。[Release 页面](https://github.com/hbdzh/JIdr-plus/releases)同时提供 MCP 包和 SHA-256 校验文件。JIdr Plus 与上游 Jidr 的发布包不同，上游的 DMG 不包含本仓库的界面改动。

## 能做什么

- **管理设备：**创建、启动和停止虚拟设备，配置硬件，查看设备信息、应用和快照。
- **操作模拟器：**使用独立窗口进行触控、键盘输入、旋转、截图、录屏和文件传输；支持基础键位映射。
- **录制操作：**记录点击、按键及文本输入，按次数或时长回放，并调整速度与间隔。回放在窗口本地执行，暂不提供 CLI/MCP 回放接口。
- **调试设备：**通过设备工具使用 GPS、网络、摄像头、Logcat 和 Root 管理；支持将 WAV 文件注入模拟器麦克风，而非 Mac 实时麦克风透传。
- **连接开发工具：**使用命令行或 MCP 控制后台。可选择外部 Android SDK 路径，或配置 Jidr 自己的 SDK 安装位置。

功能可用性取决于系统镜像、Root 模式及 Android 应用。例如系统分区写入要求 Shell Root、Android 12（API 31）及以上和支持 adb root 的镜像；切换会冷启动。详见 [Root 文档](docs/root.md)和[设备中心指南](docs/device-center.md)。

## 版本更新

- **[0.5.0](https://github.com/hbdzh/JIdr-plus/releases/tag/v0.5.0)：**新增全部设备视图，优化模拟器与操作录制窗口，并改进启动取消、停止和退出处理。
- **[0.4.0](https://github.com/hbdzh/JIdr-plus/releases/tag/v0.4.0)：**桌面界面迁移至 SwiftUI/AppKit，整合设备中心，并加入操作录制及设备工具中的系统写入、麦克风入口。

各版本的完整变更和验证范围见 [Release](https://github.com/hbdzh/JIdr-plus/releases) 与 [CHANGELOG](CHANGELOG.md)。

## 从源码构建

需要 Xcode 的 Swift 工具链、[rustup](https://rustup.rs/) 和 `protoc`（例如 `brew install protobuf`）。Rust 版本由 [rust-toolchain.toml](rust-toolchain.toml) 指定。

```bash
git clone https://github.com/hbdzh/JIdr-plus.git
cd JIdr-plus
cargo build --release -p jidr           # CLI、daemon 和 MCP
bash apps/jidr-swiftui/build-center.sh   # 桌面应用开发构建
```

本地打包及验证：

```bash
cargo xtask release --rehearsal          # 生成 DMG、MCP 包及打包报告
cargo xtask ci                           # Rust 格式、静态检查、测试及许可检查
bash apps/jidr-swiftui/test.sh           # Swift 逻辑与本地化检查
bash apps/jidr-swiftui/test-player-lifecycle.sh
```

部分测试需要 macOS 图形会话或已安装的 Android SDK 和系统镜像。开发与测试说明见 [CONTRIBUTING.md](CONTRIBUTING.md)；请勿将测试指向需要保留的真实设备数据。

## 文档与贡献

[设备中心](docs/device-center.md) · [CLI](docs/cli.md) · [MCP](docs/mcp.md) · [Root](docs/root.md) · [控制协议](docs/control-protocol.md) · [贡献指南](CONTRIBUTING.md)

设备状态由 Rust daemon 管理，SwiftUI/AppKit 界面和其他客户端通过本地 JSON-RPC 协议与后台通信。遇到问题或希望提出建议，可在 [GitHub Issues](https://github.com/hbdzh/JIdr-plus/issues) 反馈。

## 许可与致谢

本项目基于 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr)，感谢原项目及其贡献者。桌面界面的 Swift/AppKit 源码使用 **GPL-3.0-only**；Rust 桥、CLI、daemon 及其他标明 Apache 许可的部分使用 **Apache-2.0**。详见 [NOTICE](NOTICE)、[LICENSE-APACHE](LICENSE-APACHE)及对应目录的许可证。随包字体使用 OFL 许可。

Android SDK、系统镜像及 Magisk 不随本项目打包，各自受相应许可约束。Android 是 Google LLC 的商标。
