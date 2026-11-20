<div align="center">

<img src="assets/brand/app-icon-512.png" width="112" alt="miko 模拟器 图标">

# miko 模拟器

**在 Mac 上运行和管理 Android 设备。**

miko simulator 是面向 Apple Silicon Mac 的开源 Android 模拟器管理工具。

<p>
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-macOS-343A40?style=flat-square&logo=apple&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/Desktop-SwiftUI-46556B?style=flat-square">
  <img alt="Rust" src="https://img.shields.io/badge/Core-Rust-46556B?style=flat-square&logo=rust&logoColor=white">
  <img alt="MCP" src="https://img.shields.io/badge/AI-MCP-46556B?style=flat-square">
</p>

[功能介绍](#功能介绍) · [安装与使用](#安装与使用) · [AI 与自动化](#ai-与自动化) · [文档](#文档)

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/readme/devices-dark.webp">
    <img src="docs/assets/readme/devices.webp" alt="miko 模拟器 设备中心" width="100%">
  </picture>
</p>

</div>

## 功能介绍

### 管理 Android 设备

在设备中心创建、启动、停止和切换模拟器，管理设备配置、快照和内存预算。将 APK 拖入模拟器窗口即可安装。发行包内置模拟器运行时和 platform-tools，创建设备时按需下载系统镜像。

### 键位映射与手柄

在画面上布置点击键位和虚拟摇杆，使用 WASD 或方向键操作。内置 MOBA、射击和街机模板，支持保存多套方案及导入导出；连接 Mac 的物理手柄也可以转发到 Android 设备。

<p align="center"><img src="docs/assets/readme/keymapping.webp" alt="键位映射编辑与方案管理" width="360"></p>

### 多设备输入同步

选择主控设备，将触控、按键和文字输入同步到多台跟随设备。支持拉伸或等比留黑的坐标适配、锁定跟随端输入，以及切换主控设备。

<p align="center"><img src="docs/assets/readme/sync.webp" alt="多设备同步器及主控、跟随设备" width="700"></p>

### 操作录制与回放

在模拟器窗口中录制触控、按键和文本输入，保存为本地脚本；回放时可以设置次数、循环间隔和播放速度，也可以配合多设备同步使用。

### 开发调试与 AI 自动化

配置设备的 Root 模式，使用网络、日志、定位、传感器、摄像头、系统证书和文件同步等工具。通过 CLI 或 MCP，AI 智能体可以读取设备画面与界面结构，执行点击、滑动和文字输入，并使用临时设备池。

<p align="center"><img src="docs/assets/readme/automation.webp" alt="智能体客户端配置与 Android 沙盒" width="800"></p>

<details>
<summary><strong>查看更多功能</strong></summary>

| 功能 | 说明 |
| --- | --- |
| 屏幕与媒体 | 窗口缩放、旋转、截图、录屏和设备音频录制 |
| 应用与文件 | APK 安装、应用管理、文件推送与拉取 |
| 文件夹同步 | Mac 与 Android 单向或双向同步，支持冲突处理 |
| 网络工具 | HTTP 代理、丢包和 DNS 状态模拟 |
| 设备模拟 | GPS 路线、电池、传感器、摄像头、指纹、电话和短信 |
| 存储管理 | SDK 与镜像管理、设备数据迁移 |
| 效率工具 | `⌘K` 命令面板、任务中心、快捷键及中英文界面 |

</details>

## 安装与使用

需要 **Apple Silicon Mac，macOS 13 或更高版本**。

1. 从 [GitHub Releases](https://github.com/hbdzh/miko-simulator/releases/latest) 下载 DMG。
2. 打开 DMG，将 miko simulator 拖入“应用程序”文件夹。
3. 启动 miko simulator。创建设备时可使用已有镜像，或下载选中的镜像。

设备、私有 SDK、下载缓存和日志默认保存在 `~/Library/Application Support/miko` 中，可在「设置 → 数据与工具」更改位置。

## AI 与自动化

miko 模拟器 提供 `miko` 命令行和 MCP 服务。打开「设置 → 智能体」配置 Codex 或 WorkBuddy，命令行和其他客户端的配置方法见 [MCP 使用指南](docs/mcp.md)。

## 从源码编译

需要 [Rust](https://rustup.rs/)、Xcode 和 `protoc`。

```bash
git clone https://github.com/hbdzh/miko-simulator.git
cd miko-simulator
cargo build --release -p miko --bin miko
bash apps/miko-swiftui/build-center.sh
```

## 文档

[设备中心](docs/device-center.md) · [命令行](docs/cli.md) · [MCP](docs/mcp.md) · [Root](docs/root.md) · [控制协议](docs/control-protocol.md) · [贡献指南](CONTRIBUTING.md)

## 开源与致谢

miko 模拟器 基于 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 开发，感谢原项目及其贡献者。Swift/AppKit 界面采用 [GPL-3.0-only](apps/miko-swiftui/LICENSE-GPL)，Rust 桥、CLI 和后台采用 [Apache-2.0](LICENSE-APACHE)。第三方组件许可见 [NOTICE](NOTICE)。

发行包中的模拟器运行时源码、补丁和许可证材料：

- [定制核心源码、补丁与许可证](https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0/miko-runtime-source-review-0.10.0.tar.gz)
- [AOSP 项目源码快照](https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0/miko-runtime-source-projects-0.10.0.tar)
- [AOSP 依赖源码候选包](https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0/miko-runtime-dependency-sources-0.10.0.tar.gz)

上述材料包含已整理的源码和许可证；部分上游二进制的完整对应源码仍在核实，详情见[运行时溯源记录](docs/runtime-provenance-local.md)。
