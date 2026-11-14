# JIdr Plus

JIdr Plus 是一款 macOS Android 模拟器，基于开源项目 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 开发。

[下载安装包](https://github.com/hbdzh/JIdr-plus/releases/latest) · [更新日志](https://github.com/hbdzh/JIdr-plus/releases) · [反馈问题](https://github.com/hbdzh/JIdr-plus/issues)

## 功能

- 创建和管理 Android 虚拟设备，配置 CPU、内存和分辨率
- 使用键盘映射、截图、录屏及文件传输
- 录制和回放点击、按键与文本操作
- 管理应用、快照、Root 和设备设置
- 通过 CLI 和 MCP 操作模拟器

## 安装

需要 Apple Silicon Mac 和 macOS 13 或更高版本。

从 [Releases](https://github.com/hbdzh/JIdr-plus/releases) 下载 DMG，打开后将 JIdr 拖入“应用程序”文件夹。首次使用时，在设备中心配置 Android SDK 和系统镜像。

安装包未经 Apple 公证，首次打开时 macOS 可能提示无法验证开发者。Android SDK、系统镜像和 Magisk 需另行安装，相关许可由各自项目提供。

## 从源码构建

需要 [Rust](https://rustup.rs/)、Xcode 和 `protoc`。

```bash
git clone https://github.com/hbdzh/JIdr-plus.git
cd JIdr-plus
cargo build --release -p jidr
bash apps/jidr-swiftui/build-center.sh
```

构建与测试说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 文档

[设备中心](docs/device-center.md) · [命令行](docs/cli.md) · [MCP](docs/mcp.md) · [Root](docs/root.md) · [控制协议](docs/control-protocol.md)

## 许可

Swift/AppKit 界面采用 [GPL-3.0-only](apps/jidr-swiftui/LICENSE-GPL)；Rust 桥、CLI 和后台采用 [Apache-2.0](LICENSE-APACHE)。第三方组件许可见 [NOTICE](NOTICE)。
