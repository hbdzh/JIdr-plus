<p align="center">
  <img src="assets/brand/app-icon.svg" width="112" alt="JIdr Plus 图标">
</p>

<h1 align="center">JIdr Plus</h1>

<p align="center">在 Mac 上运行和管理 Android 设备。</p>

<p align="center">
  <a href="https://github.com/hbdzh/JIdr-plus/releases/latest">下载安装包</a> ·
  <a href="docs/device-center.md">使用指南</a> ·
  <a href="https://github.com/hbdzh/JIdr-plus/issues">反馈问题</a>
</p>

## 项目简介

JIdr Plus 基于开源项目 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 开发，使用 SwiftUI 和 AppKit 构建设备中心与模拟器窗口。你可以在 Mac 上创建 Android 虚拟设备，运行应用和游戏，也可以通过命令行或 MCP 管理设备。

## 主要功能

- **设备管理**：创建、启动和停止虚拟设备，调整处理器、内存、分辨率等配置。
- **应用与快照**：安装 APK、管理已安装应用，以及创建和恢复快照。
- **模拟器窗口**：使用键盘和鼠标操作设备，设置键位映射、截图、录屏或传输文件。
- **操作录制**：录制并回放点击、按键和文本操作，设置回放次数、间隔和速度，导入或导出录制文件。
- **设备工具**：调整 GPS、网络、摄像头和电量，查看 Logcat，使用音频文件模拟麦克风输入。
- **Root 管理**：配置和验证 Root，管理模块、证书及系统分区写入设置。
- **开发工具**：通过 CLI 和 MCP 控制设备，使用外部 Android SDK 或配置 JIdr 的 SDK 安装位置。在设置中管理系统镜像，查看来源和设备引用，删除不再使用的 JIdr 镜像；外部 SDK 保持只读。

## 安装和编译

### 下载安装

需要 Apple Silicon Mac。系统要求和安装包见 [GitHub Releases](https://github.com/hbdzh/JIdr-plus/releases/latest)。

打开下载的 DMG，将 JIdr 拖入“应用程序”文件夹。首次启动后，在设备中心配置 Android SDK 和系统镜像。安装包未经 Apple 公证，首次打开时 macOS 可能提示无法验证开发者。

### 从源码编译

需要 [Rust](https://rustup.rs/)、Xcode 和 `protoc`。

```bash
git clone https://github.com/hbdzh/JIdr-plus.git
cd JIdr-plus
cargo build --release -p jidr
bash apps/jidr-swiftui/build-center.sh
```

构建与测试说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。其他文档：[设备中心](docs/device-center.md) · [命令行](docs/cli.md) · [MCP](docs/mcp.md) · [Root](docs/root.md) · [控制协议](docs/control-protocol.md)。

## 致谢和许可

感谢 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 及其贡献者。Swift/AppKit 界面采用 [GPL 许可](apps/jidr-swiftui/LICENSE-GPL)；Rust 桥、CLI 和后台采用 [Apache 许可](LICENSE-APACHE)。第三方组件许可见 [NOTICE](NOTICE)。
