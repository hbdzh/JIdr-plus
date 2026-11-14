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

JIdr Plus 基于开源项目 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 开发，使用 SwiftUI 和 AppKit 构建设备中心与模拟器窗口。

### 管理设备

在设备中心创建、启动和管理 Android 虚拟设备，调整 CPU、内存和分辨率。应用、快照和设备设置都可以在这里找到。

### 用键盘和鼠标操作

在独立窗口中运行应用，设置键位映射，截图、录屏或向设备发送文件。

### 录制与回放

记录点击、按键和文本操作，设置回放次数、间隔和速度。录制文件可以导入和导出。

### 设备工具

设置 GPS、网络和摄像头，查看 Logcat，管理 Root。也可以使用音频文件模拟麦克风输入。

## 安装

需要 Apple Silicon Mac。系统要求和安装包见 [GitHub Releases](https://github.com/hbdzh/JIdr-plus/releases/latest)。

打开下载的 DMG，将 JIdr 拖入“应用程序”文件夹。首次启动后，在设备中心配置 Android SDK 和系统镜像。

安装包未经 Apple 公证，首次打开时 macOS 可能提示无法验证开发者。

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

Swift/AppKit 界面采用 [GPL 许可](apps/jidr-swiftui/LICENSE-GPL)；Rust 桥、CLI 和后台采用 [Apache 许可](LICENSE-APACHE)。第三方组件许可见 [NOTICE](NOTICE)。
