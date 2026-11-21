# SwiftUI 打包

`cargo xtask release` 是应用的唯一打包实现：构建 `miko simulator.app`、arm64 DMG、MCP 包和 `SHA256SUMS`，默认输出到 `target/release-artifacts`。应用元数据模板为 `Miko-Info.plist.in`，bundle 标识为 `ly.miko.Miko`。工作区版本用于 CLI、应用 plist 和资源文件名；模板中的 `@VERSION@` 刻意保留为占位符。

## 准备运行时和本地演练

使用已校验的上游归档和固定的本地构建核心准备新运行时目录；命令不会覆盖已有目标：

```bash
cargo xtask prepare-runtime \
  --emulator-zip /path/to/emulator-darwin_aarch64-16970787.zip \
  --platform-tools-zip /path/to/platform-tools_r37.0.3-darwin.zip \
  --core /path/to/qemu-system-aarch64-headless \
  --output /path/to/new-runtime
export MIKO_BUNDLED_SDK=/path/to/new-runtime
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

本地候选包要求 `MIKO_BUNDLED_SDK` 包含 `emulator/` 和 `platform-tools/`。打包时依据固定的 SHA-256 清单核对每个文件、37.3.10 运行时、核心库和声明，再将两个目录复制进应用。输入清单保留全部固定的上游文件用于验证；应用中排除 FlatBuffers C++ 开发头文件和未使用的设备皮肤覆盖 APK。系统镜像保持独立，由用户按需获取。这些输入是外部构建材料，不存储在仓库中。

上述命令属于本地开发验证。按照 clean-room 规则，只有组件来源、许可证、对应源码义务与声明均已核实后才可再分发；目前审核仍未完成。

`--rehearsal` 使用 ad-hoc 签名、隔离临时数据及安装/卸载检查，生成 `target/release-rehearsal/report.md`；不会发布或替换已安装应用。`apps/miko-swiftui/package-test.sh` 调用同一流程，没有第二套测试专用打包链或独立播放器应用。

## 自动流程与发行限制

GitHub Actions 通过 `prepare-release-inputs` action 准备 Magisk 和运行时。运行时 action 接受 `MIKO_RUNTIME_CORE_URL`，或从校验通过的 0.10.0 DMG 中提取固定核心；两种方式都依赖外部托管输入，且会核对哈希与运行时清单。归档地址和哈希记录在 `packaging/runtime-source/runtime-inputs.json`。

`cargo xtask prepare-runtime-sources --out dist` 下载固定审核归档，并依据当前清单和补丁校验。手动打包检查执行 dry-run 和扫描，不上传未经审核的产物。普通 CI 在缺少必要输入时不运行打包演练。

正式发行会在准备输入前运行 `cargo xtask release --preflight`；运行时再分发审核完成前，该检查会阻止发行，直接运行正式发行命令也受相同门槛约束。审核范围和限制见[运行时溯源记录](../../docs/runtime-provenance-local.md)。

## 应用结构

```text
miko simulator.app/Contents/
  Info.plist, PkgInfo
  MacOS/Miko                     SwiftUI/AppKit 设备中心和播放器窗口（GPL）
  Helpers/miko                   CLI / daemon / MCP（Apache）
  Helpers/miko-center-bridge     设备中心 JSON-RPC 桥（Apache）
  Helpers/miko-swiftui-bridge    画面与输入桥（Apache）
  Resources/sdk/                 本地候选：模拟器和 platform-tools
  Resources/Miko.icns
  Resources/en.lproj, zh-Hans.lproj
  Resources/device-list.png, device-detail.png, device-stopped.png
  Resources/fonts/               TTF 与 OFL 声明
  Resources/licenses/            LICENSE-APACHE、LICENSE-GPL、NOTICE
```

正常启动时，主程序从应用包内寻找 helper，并使用标准 miko 数据目录。开发模式下显式传入 `CENTER_BRIDGE PLAYER_BRIDGE` 时必须设置 `MIKO_HOME`。

候选包扫描会将 SDK 工具与输入比对，拒绝系统镜像和未经批准的 APK；固定版本的官方 Magisk APK、许可证和在线源码获取说明会打包在内。ad-hoc 签名按由内到外的顺序检查。Developer ID 签名和公证尚未覆盖全部 helper，不得报告为已通过。
