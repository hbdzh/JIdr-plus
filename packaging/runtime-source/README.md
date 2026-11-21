# 本地模拟器核心源码记录

本目录保留本地测试的 arm64 运行时源码证据，**不代表对应源码或其他再分发义务已全部核实**；详情见[溯源审核](../../docs/runtime-provenance-local.md)。

- 上游：AOSP `platform/external/qemu`，提交 `5e51202879523d4df1bca8ca6944129ff05df02b`。
- `qemu-local.patch` 记录六个经过修改的源码或构建文件。它是按相关上游 QEMU 文件许可证提供的独立第三方补丁，不属于 Apache crate。`LICENSE-qemu.txt`、`COPYING-GPL-2.0` 和 `COPYING-LGPL-2.1` 来自该源码检出。
- `aosp-checked-out.xml` 固定了本次本地构建中实际存在的项目 HEAD；未检出的项目（包括可选 system-images 和其他主机平台）已省略。固定清单和构建尚未在全新检出环境中验证。
- `NOTICE-core.txt` 与 `NOTICE-core.csv` 来自 AOSP 构建树，须与 Google 运行时和 platform-tools 提供的声明一起审核。
- 源码快照及若干依赖归档仍在本地源码候选目录。公开发行前仍需完整对应源码包、依赖映射、构建说明和持续可用的源码获取方式。

记录的本地构建使用 AOSP `android/build/python/cmake.py`，参数为 `--target darwin-aarch64`、版本 `37.3.10`、CMake Release 模式和 Ninja 目标 `qemu-system-aarch64-headless`，并使用 Xcode 的 macOS 27.2 SDK 及 Apple 链接器。`qemu-local.patch` 包含与本机有关的链接器路径；现有构建方法和清单只是起点，尚未证明可在其他环境重建。准确的构建依赖及对应源码仍需审核。

## 本地审核和构建

使用 `cargo xtask collect-runtime-source --aosp-root /path/to/aosp --output /path/to/new-source-review`，可按固定版本归档已检出的源码项目，并检查 QEMU 的已记录修改是否与保存的补丁一致。结果仅供审核：它不能证明官方 SDK 二进制对应的准确源码，不能捕获未跟踪构建输入，也不能证明可从全新环境重建。

使用 `python3 scripts/build-runtime-core.py --aosp-root /path/to/aosp --output /path/to/new-build --verify-only` 检查记录的源码和本地工具链；移除 `--verify-only` 后可尝试新构建。脚本拒绝覆盖输出，并在重建核心的哈希与固定发行输入不一致时拒绝结果。该脚本曾完整运行：编译和签名验证成功，但核心并非与固定输入逐字节一致，因此被哈希检查拒绝。

`--verify-only` 使用临时 Git index 检查相关 macOS ARM64 Qt 文件，不会修复或修改已有检出。通用预构建检查排除已跟踪的 `x264/darwin-x86_64/.DS_Store` Finder 元数据，其余已跟踪文件仍需检查。

运行 `python3 scripts/audit-runtime-dependencies.py /path/to/aosp/prebuilts/android-emulator-build/archive`，可按上游校验算法检查源码归档哈希和声明的补丁路径。存在未解决项时命令返回非零；即使成功，也不能单独证明与发行二进制的对应关系。

`cargo xtask inventory-runtime-notices --sdk /path/to/prepared-sdk` 检查固定的模拟器 Mach-O 文件，并按文件名输出 `NOTICE.csv` 的审核线索。保存的 `emulator-notice-inventory.json` 是清单，不代表源码或许可证审核已经完成。

[0.10.0 发行版](https://github.com/hbdzh/miko-simulator/releases/tag/v0.10.0)包含不完整的源码审核包，其中有本地 QEMU 快照、补丁、部分依赖源码候选和许可证声明。未解决的对应关系和构建问题见上述审核记录。
