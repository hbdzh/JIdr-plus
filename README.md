# JIdr Plus

JIdr Plus 是基于开源项目 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr) 的 macOS 安卓模拟器项目。本仓库在原项目基础上改进设备中心、独立游戏窗口和中文使用体验，同时保留原项目的 Rust 后台、命令行工具和 MCP 服务。

目前界面使用 **Slint**，SwiftUI 尚处于可行性验证阶段。项目仍在开发中，建议在更新软件或调整设备配置前保存游戏进度。

## 主要功能

- **设备中心**：查看、启动、停止和管理设备，配置 CPU、内存、分辨率和屏幕密度。
- **独立游戏窗口**：适配横竖屏，提供导航、音量、旋转、截图、全屏和侧栏控制。
- **游戏与应用**：查看运行中设备已安装的可启动应用，支持启动应用和安装 APK。
- **电脑输入**：支持鼠标触控、键盘输入、中文输入法和常见文本编辑快捷键；文本输入与粘贴效果取决于安卓应用是否支持相应操作。
- **基础键位映射**：添加屏幕点击位置、绑定按键、保存设备方案并显示提示。
- **截图和快照**：提供截图、录屏与快照管理；退出应用时会尝试安全停止运行中的设备。
- **SDK 和工具路径**：设置中可选择 Android SDK 等工具路径。JDK 路径供需要它的工具使用，JIdr 本身目前不要求安装 JDK。
- **开发工具**：保留 CLI、MCP、Root 和设备管理等上游功能。Root 及第三方组件需遵守各自许可。

### 数据迁移现状

设置中的数据位置入口目前**只保存目标位置并进行初步检查，不会迁移设备数据或快照**。迁移功能尚未开放；请勿因为选择了新位置就删除原有数据。具体设计见 [存储迁移设计](docs/storage-migration-design.md)。

## 系统要求

- Apple Silicon Mac，macOS 14 或更高版本。
- 安卓 SDK、模拟器和系统镜像需要额外磁盘空间；实际需求取决于镜像、设备、游戏数据和快照大小。
- 首次安装 Google SDK 组件或系统镜像时，需要由用户本人接受对应许可。

## 从源码构建

本仓库与上游 Jidr 的官方发布包是不同的版本；上游的 Homebrew 包和 DMG 不包含本仓库的改动。当前可从源码构建：

```bash
git clone https://github.com/hbdzh/JIdr-plus.git
cd JIdr-plus
cargo build --release -p jidr -p jidr-gui
```

需要安装 [rustup](https://rustup.rs/) 和 `protoc`（例如使用 `brew install protobuf`）。Rust 版本由 [rust-toolchain.toml](rust-toolchain.toml) 指定。构建命令生成二进制文件，并不自动安装 macOS 应用包。

## 验证

```bash
cargo test -p jidr-ui --lib
cargo xtask ci
```

部分模拟器集成测试需要已安装的 Android SDK、系统镜像及相应运行环境，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。不要将测试指向需要保留的真实设备数据。

## 项目结构

- `apps/jidr-gui`、`crates/jidr-ui`：桌面界面。
- `apps/jidr`：命令行程序及 daemon 入口。
- `crates/jidr-daemon`、`crates/jidr-backend`：设备管理与模拟器控制。
- `crates/jidr-sdk`：SDK、镜像和虚拟设备管理。
- `crates/jidr-client`、`crates/jidr-mcp`：后台协议客户端与 MCP 服务。

设备状态由 Rust daemon 管理，界面通过本地 JSON-RPC 协议与之通信。详细说明见 [控制协议](docs/control-protocol.md)、[CLI 参考](docs/cli.md)、[MCP 说明](docs/mcp.md)和 [Root 模式](docs/root.md)。

## 许可与致谢

本项目基于 [Jidr](https://github.com/AbdurahmanAlmehdi/jidr)，感谢原项目及其贡献者。沿用原项目的分许可方式：桌面界面相关的 `crates/jidr-ui` 和 `apps/jidr-gui` 为 **GPL-3.0-only**；CLI、daemon 和其余标明 Apache 许可的部分为 **Apache-2.0**。详见 [NOTICE](NOTICE)、[LICENSE-APACHE](LICENSE-APACHE)及相应目录下的许可证。

Android SDK、系统镜像及 Magisk 不随本项目源码打包，其下载和使用受各自许可约束。Android 是 Google LLC 的商标。
