# Changelog

## 0.10.0 — miko 模拟器 (2026-11-20)

### 新增

- 更新应用图标，并同步更新 MCP 扩展图标。
- 设备搜索支持查找正在运行的设备中已安装的应用；首次设置时可选择设备、镜像和缓存的存储位置。

### 修复

- 改进 SDK 安装取消和覆盖安装时的处理：等待解压结束再清理，替换失败时尝试恢复原有组件。
- 改进存储迁移对自定义和历史 SDK 目录的处理，保留已有镜像的发现能力。
- 模拟器已经自行退出时正确完成停止清理；缺少音频输入设备时阻止可能导致模拟器崩溃的音频注入。
- 改进设备中心与后台通信、播放器画面解码及日志处理，减少请求阻塞和异常数据造成的问题。

### 优化

- 首次设置先准备模拟器和 ADB，创建设备时再按需选择或下载系统镜像。
- 设备、私有 SDK、下载缓存和日志统一保存在数据目录下，并改善迁移进度与错误提示。
- 改进快速启动遇到不支持保存的 Vulkan 应用时的提示，并更新设备创建、镜像管理和测试。

### 已知问题与安装

- 快速启动快照原地保存失败时，旧快照仍可能受损。
- 适用于 Apple Silicon Mac，要求 macOS 13 或更高版本。打开 DMG，将 miko simulator 拖入“应用程序”。
- 发行包使用 ad-hoc 签名，未经 Apple 公证；首次打开可能需要在系统设置中允许。

## 0.9.1 — miko 模拟器 (2026-11-20)

### 修复

- 停止设备或退出应用时，如果快速启动快照保存失败，会显示提示并保持设备运行，方便释放空间后重试。
- 检测到上次设备异常退出或快速启动快照不完整时，在设备启动后显示提示。

### 优化

- 将应用、命令行和内部组件统一为 miko 模拟器，包括后台服务、播放器桥接程序、设备数据目录和配置名称。
- 检查快照保存时的磁盘空间和可用内存；资源较少时显示提示。
- 更新命令行 JSON 输出、操作录制格式、设备池及休眠快照名称，并同步更新文档和测试。

### 升级说明

- 数据目录改为 `~/Library/Application Support/miko`。0.9.0 的数据和配置不会自动迁移，需重新配置设备与工具。
- 命令行改为 `miko`，相关环境变量改为 `MIKO_` 前缀；旧版操作录制文件无法直接使用；依赖旧 JSON 字段的脚本需要更新。

### 安装

- 适用于 Apple Silicon Mac，要求 macOS 13 或更高版本。打开 DMG，将 miko simulator 拖入“应用程序”。

## 0.9.0 — miko 模拟器 (2026-11-20)

### 新增

- 重新设计播放器键位编辑：支持在画面中放置、拖动和重绑触控键位，添加 WASD 或方向键虚拟摇杆，并提供 MOBA、射击和街机模板。
- 支持创建、复制、重命名、导入和导出多个键位方案；编辑时可调整标记透明度，并在关闭时提示未保存的修改。
- 播放器增加游戏手柄连接和断开入口，显示连接状态。

### 修复

- 键位方案损坏时保留原文件，提供重新加载、在访达中查看或重置后编辑的选项；保存前检查未绑定的选点和按键冲突。
- 设备数据迁移完成并验证新位置后清理旧目录；清理前检查当前存储位置和目录重叠，失败时提示手动清理。

### 优化

- 调整设备工具箱、Root 模式和系统分区操作的布局与文案，将设备配置入口和相关状态整理得更清晰。
- 改进播放器键位标记、窗口尺寸及全屏编辑交互，补充键位映射测试。
- 将小屏手机配置调整为 5.5 英寸 FHD（1080 × 1920、420 dpi），整理设备规格顺序并保留 6.1 英寸机型作为默认配置。

### 已知问题

- 快速启动快照原地保存失败时，旧快照仍可能受损。

## 0.7.0 — miko 模拟器 (2026-11-18)

### 新增

- **多设备输入同步器（Synchronizer）**：新增 `jidr-sync` 逻辑库、守护进程 `sync.*` 会话控制面（`sync.start` / `stop` / `status` / `add_follower` / `remove_follower` / `set_leader` / `set_options` / `report` 与 `sync.state` / `sync.follower_error` 事件）、CLI `jidr input-sync`、MCP 工具（`sync_start` / `sync_stop` / `sync_status`）、桥接端 `leader`/`follower` 实时转发与坐标适配（`stretch` / `letterbox`），以及液态玻璃风格“同步器”面板（`⇧⌘Y`、命令面板与播放器工具栏入口）、窗口内状态胶囊和锁定跟随端一键接管为主控功能。
- **双向与单向文件夹同步**：新增 `file.sync.start`（支持 `one_way` 与 `bidirectional`）、`file.sync.stop`、`file.sync.list`、`file.sync.resolve` 协议命令与 `file.sync.*` 事件，CLI 同步新增 `jidr sync start [--bidirectional]`、`list`、`stop` 与 `resolve`。双向模式通过 SHA-256 内容基线与设备端扫描同步两端更改与删除，冲突时保留双方内容供手动选择（`keep_local` / `keep_remote` / `keep_both`）。
- **独立文件夹同步面板**：在设备概览页操作栏、菜单栏「设备」及命令面板（`⌘K`）新增“文件夹同步”入口，支持在独立面板中切换双向/单向方向、可选自定义设备目录、查看实时 `↑pushed ↓pulled` 计数、在访达中显示目录以及一键处理冲突。
- **网络丢包与 DNS 模拟增强**：`network.shaping.set` 新增 `dns`（`normal` / `slow` / `fail`）与 `dns_delay_ms` 参数，配置持久化到设备并在重启后恢复；同步更新 CLI（`jidr network dns`）与 SwiftUI 工具页。
- **设备标识、手柄转发与刷机分类**：新增 `identity.get` / `identity.set`（读取 Android ID / IMEI、Root 修改 Android ID）、`input.gamepad.*`（转发 Mac 游戏手柄到设备）及 `file.flash`（安装受支持的 Magisk 模块或复制普通 ZIP，拒绝 recovery 与分区镜像）。
- **录屏音频支持**：`media.record` 新增可选 `audio` 参数（默认开启），并回报是否包含音轨及是否接收到有效音频包。

### 修复

- 修复单向同步删除宿主目录时可能误删设备端自有或忽略文件的问题，改为仅移除本次同步记录过的文件；文件状态读取失败不再直接视为删除；首次镜像与增量传输失败后自动重试；监听器在首次扫描前启动以缩小漏变更窗口。
- 修复文件夹同步面板弹出时与主界面同时闪烁、顶部刷新与添加按钮未对齐及误触发重复选中的问题。

### 优化

- 文件夹同步面板统一采用与“设备设置”一致的原生分组表单、下拉方向选择器与毛玻璃弹窗交互。
- 同步更新协议文档、CLI 文档、MCP 文档、Agent Skill（`skills/jidr/SKILL.md`）以及同步、网络、标识、手柄和音视频相关测试。

### 已知问题与验证限制

- 延续 0.6.0 已知问题：快速启动快照原地保存失败时，旧快照仍可能受损；`jidr-daemon --test stop_sync` 中的 `failed_save_preserves_previous_quick_boot` 未通过。
- 本机未安装 `protoc`，`jidr-proto` 重编译与全工作区 `--all-features` 测试未在本地通过；`test-center-ui.sh --interactive` 与真实 Android 模拟器实机端到端验收尚未执行。
- 本地或未配置 Developer ID 凭据构建的产物仅使用 ad-hoc 签名且未公证。

## 0.6.0 — miko 模拟器 (2026-11-16)

### 新增

- 新增系统镜像管理：查看各 SDK 中已安装镜像的来源、占用和关联设备，在界面中安装镜像，或删除未被 Jidr 设备使用的 Jidr SDK 镜像。外部 Android SDK 保持只读；删除前会重新检查目录、设备引用和并发操作。
- 新建设备向导支持直接复用现有 SDK 和已安装镜像，也可按需安装工具或其他镜像；支持自定义分辨率、设备规格、Root 模式、内存、CPU、存储及声音。
- 安装前可查看适用的完整 SDK 许可，包括已同意的许可；只有用户明确同意后才记录许可。安装支持进度、取消、错误提示与重试。
- 新增 `image.inventory`、`image.remove` 和 `sdk.license_details` 控制协议命令，分别用于查询镜像副本、删除可安全移除的 Jidr 镜像和查看许可详情。

### 修复

- 启用快速启动的设备停止或退出时，先显式保存并验证快照；保存失败时保持设备运行，避免继续关闭。重新接管的模拟器不会在退出时覆盖已验证的快照；终止前须确认虚拟机已暂停。
- 修复设置窗口从较高页面切回较低页面时可能出现画面重叠、控件无法点击的问题。
- 修复面板切换、关闭与重复打开之间的竞态，避免丢失未保存的设备设置或让后台快捷键误操作设备；安装向导需要前台时防止窗口关闭或意外退出。
- 修复安装任务取消与任务 ID 尚未返回之间的竞态，并避免由安装页面处理的进度覆盖全局提示。
- 修复清理下载缓存时超大天数参数可能造成整数溢出的问题。
- 修复设备选择、搜索和刷新时旧请求可能留下过期详情；删除设备后重新核对设备列表，避免将未生效的删除显示为成功。

### 优化

- 重新设计空设备库引导、环境准备和创建设备流程，改善加载、无镜像、缺少工具、许可确认、安装进度和失败状态。
- 统一设备创建、设备设置、快照、系统镜像、命令搜索和后台任务面板的原生材质、动画、焦点与交互；兼顾减少动态效果设置及深浅色外观。
- 设置窗口按页面内容调整大小，最多占当前屏幕宽高的 70%；内容过多时可滚动，并适配显示器变化。
- 快照按自动和手动分类，展示不可恢复的原因；刷新时保留已有内容，减少概览按钮跳动。
- 改善设备侧边栏选择状态、播放器启动和连接状态、表单输入、工具栏及中英文文案。
- 增加镜像删除保护、许可读取、快速启动保存、窗口交互、面板协调、创建设备和界面截图回归测试。
- 增加可选的内部开发技能与使用说明，覆盖 macOS 界面、SwiftUI/AppKit 和 Rust 开发。

### 待解决

- 快速启动快照原地保存失败时，旧快照仍可能损坏。完整设备级恢复方案尚未集成；相关回归测试未通过。

## 0.5.1 — miko 模拟器 (2026-11-15)

### 设备和网络

- 支持从 Magisk Root 设备创建基础镜像和设备池克隆，克隆保留独立的 Root 配置。
- 新增出站网络丢包模拟，可查看、设置和清除丢包比例；需要 Root 和系统镜像的 netem 支持。
- 改进 Root 冷启动前的关机流程，先正常关闭 Android，再启动新配置。

### 稳定性和界面

- 持久化设备池租约，修复等待启动时租约提前过期及续期与回收竞态。
- 创建基础镜像时保留源设备动画设置，在克隆交付前关闭动画。
- 改进设备中心、播放器窗口、原生命令搜索与设备工具界面，并更新交互及截图测试。

## 0.5.0 — miko 模拟器 (2026-11-15)

### 界面和交互

- 新增全部设备视图，优化设备概览、侧边栏、搜索框、卡片层次与深浅色外观。
- 调整模拟器标题栏、工具栏及操作录制窗口；长设备名自动截断，标题栏控件对齐。
- 优化键位设置和设备工具的原生材质及布局。

### 稳定性

- 关闭正在启动的模拟器窗口时取消启动，无需等待启动完成。
- 设备停止期间重开应用后可正常退出，停止操作继续在后台执行。
- 为模拟器关闭请求增加超时保护，并改进后台状态持久化和客户端消息处理。
- 更新窗口生命周期测试及界面截图基准。

## 0.4.0 — miko 模拟器 (2026-11-14)

### Features

- Replace the device grid/list and separate inspector with a native device sidebar and responsive overview.
- Consolidate APK installation/drop targets, app management and snapshot actions; keep device settings/tools in the header and capture/send actions in a compact row.
- Share native search controls across device search, the command palette and operation recordings.
- Expose writable `/system` configuration in Root tools with eligibility checks, cold-boot confirmation and read-only restoration.
- Add a Microphone page for WAV injection, looping, progress and cancellation, retaining playback controls across tool-page changes.
- Keep camera editing in Device tools and link to it from device settings without discarding other staged changes.

### Maintenance

- Bundle stopped-device artwork in development and release applications, with a packaging regression test.
- Update scoped UI fixtures, screenshot baselines, localization checks and device-tool operation tests.
- Set workspace and release metadata to 0.4.0. Local build/install outputs stay outside version control.

The [0.4.0 release](https://github.com/hbdzh/JIdr-plus/releases/tag/v0.4.0) was rebuilt later from the merged 0.4.0 source; it is not an upstream Jidr release or the original binary. Developer ID signing, notarization, and real-emulator acceptance of the system-write and microphone UI flows remain unverified.

## [0.3.1](https://github.com/AbdurahmanAlmehdi/jidr/compare/v0.3.0...v0.3.1) (2026-11-03)


### Bug Fixes

* **release:** retry hdiutil create when the image is busy ([f6f0be4](https://github.com/AbdurahmanAlmehdi/jidr/commit/f6f0be4fb82e0f0f969fc320347a843c64bd7b38))
* **release:** retry hdiutil create when the image is busy ([3277063](https://github.com/AbdurahmanAlmehdi/jidr/commit/3277063a8c96b7a4ee392cae5ed8d657c65a086b))

## [0.3.0](https://github.com/AbdurahmanAlmehdi/jidr/compare/v0.2.0...v0.3.0) (2026-11-03)


### Features

* **daemon:** bases, pool leases and a reaper for agents (Phase 13d, D42) ([c780dc5](https://github.com/AbdurahmanAlmehdi/jidr/commit/c780dc5355797bbf8d2ee51913d307ed612a9dbb))
* **daemon:** hibernate, auto-hibernate and a working quick-boot save (Phase 13c, D42) ([a186692](https://github.com/AbdurahmanAlmehdi/jidr/commit/a18669279bf4cc6c3205e2d2eec28a548575cf03))
* **daemon:** host RAM budget, lean profile and host.budget (Phase 13a, D42) ([b06e0a6](https://github.com/AbdurahmanAlmehdi/jidr/commit/b06e0a6123da5317f248db6493f2d382580b45dc))
* many devices on one machine (D42, Phases 13a–13d) ([48a8289](https://github.com/AbdurahmanAlmehdi/jidr/commit/48a8289d64a28674fc1f34d4ae20082f32cba7ab))
* **root:** trust CA certificates as system certs on Full-root devices ([68c79b8](https://github.com/AbdurahmanAlmehdi/jidr/commit/68c79b8a01d1c3ece68e351508c606dd6e023427))
* **root:** trust CA certificates as system certs on Full-root devices ([0bf3c20](https://github.com/AbdurahmanAlmehdi/jidr/commit/0bf3c20b4887c1fe634f8937dbfdbd6e94b19450))
* **sdk:** snapshot-keeping copy-on-write clones (Phase 13b, D42) ([3fe675d](https://github.com/AbdurahmanAlmehdi/jidr/commit/3fe675da6ce7cf71da6fbd78700296f836721899))
* **site:** take the download's version, size and checksum from GitHub ([3f5f8d3](https://github.com/AbdurahmanAlmehdi/jidr/commit/3f5f8d3cb1356ca9455807447fbcc542e93f9862))
* **site:** take the download's version, size and checksum from GitHub ([e287b93](https://github.com/AbdurahmanAlmehdi/jidr/commit/e287b9304b828ec634625d16882b21b4b757ae70))
* **skills:** jidr and jidr-app-testing agent skills with xtask skills-check (D43) ([cec4fcb](https://github.com/AbdurahmanAlmehdi/jidr/commit/cec4fcb6b69f0e05744ff27c759d46552399b351))
* **skills:** jidr and jidr-app-testing agent skills with xtask skills-check (D43) ([db26b30](https://github.com/AbdurahmanAlmehdi/jidr/commit/db26b30a3baaa7fca215bdacac8c5134aa71188f))
* **widgets:** set and clear a device's HTTP proxy ([8b44aab](https://github.com/AbdurahmanAlmehdi/jidr/commit/8b44aab0e957d6629e4c06c7569ea3bbebf41d94))
* **widgets:** set and clear a device's HTTP proxy ([340e11d](https://github.com/AbdurahmanAlmehdi/jidr/commit/340e11d9778c5f572c61cc678201c3010a3d54de))


### Bug Fixes

* CI and test failures after the merge batch ([ebb571d](https://github.com/AbdurahmanAlmehdi/jidr/commit/ebb571df793c07fc2ae972cd3759236ebaa5d734))
* **daemon:** save quick-boot state when stopping a resumed run ([4566dde](https://github.com/AbdurahmanAlmehdi/jidr/commit/4566ddecbd33251a1b80a6cb166720696e3d8bdb))
* Full-root su hang recovery, Magisk version text, new-device auto start ([ba9cb20](https://github.com/AbdurahmanAlmehdi/jidr/commit/ba9cb20dfc764cb20b98ae7d475dac422d993daa))
* **packaging:** keep the template placeholders out of the cask's comment ([0a1a9f6](https://github.com/AbdurahmanAlmehdi/jidr/commit/0a1a9f66758b3f7d3a475369c67b5aa5b8c35330))
* **root:** recover a shell su that hangs right after the Full-root grant ([ff1beeb](https://github.com/AbdurahmanAlmehdi/jidr/commit/ff1beeb9160581424c2f71a58ca6e92bee6bcbf9))
* **root:** report the Magisk version without magisk -v's variant suffix ([a69eb44](https://github.com/AbdurahmanAlmehdi/jidr/commit/a69eb4474d929f30fca9b1a19843f1dd0b8de039))
* **root:** take one Zygote pid when pidof prints several ([a344019](https://github.com/AbdurahmanAlmehdi/jidr/commit/a3440198b1d10e5f8b551168bafc5283ca62b5ea))
* **site:** run the site tests on Node 22 ([e4b0892](https://github.com/AbdurahmanAlmehdi/jidr/commit/e4b08925970dbcfc4e066aa8b53570615e1d6171))
* **ui:** map player touches through the display rotation ([b29b53a](https://github.com/AbdurahmanAlmehdi/jidr/commit/b29b53a3dd69565258e629a4b5d23f178d4bd823))
* **ui:** map player touches through the display rotation ([2b01155](https://github.com/AbdurahmanAlmehdi/jidr/commit/2b01155dbabf3028864852729834b66d93628fc5)), closes [#51](https://github.com/AbdurahmanAlmehdi/jidr/issues/51)
* **ui:** start a new Full-root device's setup when the device list arrives ([edcde01](https://github.com/AbdurahmanAlmehdi/jidr/commit/edcde01fae1fb77dc168b6af8d51b9d1aa107e2a))

## [0.2.0](https://github.com/AbdurahmanAlmehdi/jidr/compare/v0.1.0...v0.2.0) (2026-10-18)


### Features

* **site:** blog with two technical guides ([7264e14](https://github.com/AbdurahmanAlmehdi/jidr/commit/7264e1464fcb3f4b632f0c11bb9f5f8397426600))
* **site:** show the brew install and upgrade lines now the cask is in the tap ([3a30c65](https://github.com/AbdurahmanAlmehdi/jidr/commit/3a30c652052c8a192ba313898d445a87f7a62a14))
* **site:** switch jidr.ly to the launch page for v0.1.0 ([094c642](https://github.com/AbdurahmanAlmehdi/jidr/commit/094c642b5c61b338b2a98d10b1b073b8a42ed6ed))
* **site:** switch jidr.ly to the launch page for v0.1.0 ([3fcc5ad](https://github.com/AbdurahmanAlmehdi/jidr/commit/3fcc5ad4ba4ff58779ebb8adf8e07965cdf57a11))
* **ui:** Check for updates compares with the latest GitHub release ([45ee1d6](https://github.com/AbdurahmanAlmehdi/jidr/commit/45ee1d6d63b20673d1c4e83b0695b536e57c5311))
* **ui:** Check for updates compares with the latest GitHub release ([f907b68](https://github.com/AbdurahmanAlmehdi/jidr/commit/f907b685204da59e3ca8c1ebd13480a32d3aa646)), closes [#44](https://github.com/AbdurahmanAlmehdi/jidr/issues/44)

## 0.1.0 (2026-10-18)


### Features

* **backend:** AOSP emulator launch, boot wait and graceful stop (Phase 3b) ([80e15e7](https://github.com/AbdurahmanAlmehdi/jidr/commit/80e15e722962da2149ae69a676d314af2758a27c))
* **backend:** camera options in LaunchOptions and Device.launch (R7, D36) ([732662f](https://github.com/AbdurahmanAlmehdi/jidr/commit/732662f8c40c8de688f64ce6e54b416ad7c84020))
* **backend:** crash detection, re-adopt, double-launch refusal, console client (Phase 3c) ([9c1dfaa](https://github.com/AbdurahmanAlmehdi/jidr/commit/9c1dfaa3203245edb8cce08f0e2de0996b0dccd3))
* build-prop spoofing for Full-root devices (Phase 9f) ([eef1509](https://github.com/AbdurahmanAlmehdi/jidr/commit/eef1509c28987e954f2b611140efb54f47925db7))
* **cli,sdk:** download cache, uninstall --purge and device log bundles (Phase 5b) ([683c2c5](https://github.com/AbdurahmanAlmehdi/jidr/commit/683c2c5ebd83461a94c150f9d6f9941b64e5d33b))
* **cli:** jidr command line over the daemon protocol (Phase 5a) ([b8abad3](https://github.com/AbdurahmanAlmehdi/jidr/commit/b8abad3a59730a41d953daeb664572471fe5c6b2))
* **cli:** register the root provider ([83e4ea3](https://github.com/AbdurahmanAlmehdi/jidr/commit/83e4ea355d579c13b9743bf2c8b2b24e3c761bda))
* **cpio:** ramdisk cpio reader/writer with gzip, lz4-legacy and xz (Phase 9b) ([452a1fa](https://github.com/AbdurahmanAlmehdi/jidr/commit/452a1faedae63fe88f216ac973019a846eb89561))
* daemon settings, byte progress, pristine ramdisk hash, full command reference (B4, B5, G14, G16) ([ca9df9e](https://github.com/AbdurahmanAlmehdi/jidr/commit/ca9df9e53d48bcc905567a83c74683cc49ca8d26))
* daemon settings, byte progress, pristine ramdisk hash, full command reference (B4, B5, G14, G16) ([9203b99](https://github.com/AbdurahmanAlmehdi/jidr/commit/9203b998997f568652f9eed9e6f4d3da1ed5424d))
* **daemon,client:** jobs, events, idle exit and the jidr-client library (Phase 4b) ([e4b1d08](https://github.com/AbdurahmanAlmehdi/jidr/commit/e4b1d0816d3ffbd2701f7fd7a7227970b3b431ab))
* **daemon:** freeze control protocol v0.1 with generated docs and fuzzing (Phase 4c) ([e7f591d](https://github.com/AbdurahmanAlmehdi/jidr/commit/e7f591de20bd4fcc50874ef22206f56ac7a464f5))
* **daemon:** JSON-RPC daemon core, provider contract and device commands (Phase 4a) ([d56990c](https://github.com/AbdurahmanAlmehdi/jidr/commit/d56990c6cbf345643a1e69917fc243180802f663))
* **jidr:** register the widgets provider in jidr daemon (G6) ([83cb597](https://github.com/AbdurahmanAlmehdi/jidr/commit/83cb597bf993c6be5a5c06b1e27da1f9be6f1c90))
* **jidr:** register the widgets provider in jidr daemon (G6) ([d21876f](https://github.com/AbdurahmanAlmehdi/jidr/commit/d21876f8062e5c9b4e087b73636d2a166aa05a31))
* **mcp:** jidr mcp server with generic and typed device tools (Phase 6) ([1a1e20f](https://github.com/AbdurahmanAlmehdi/jidr/commit/1a1e20f627d72201ac1ce2c6855a2a1dcc51124c))
* **proto,adb:** emulator gRPC bindings with vendored fallback and adb wrapper (Phase 3a) ([485ed78](https://github.com/AbdurahmanAlmehdi/jidr/commit/485ed780c6834184102dcbdcf2774a7c7c58663e))
* **release:** Homebrew cask and MCP bundle with every release ([dc6af6d](https://github.com/AbdurahmanAlmehdi/jidr/commit/dc6af6d4c2e275f050d112899874f54fbb494ecf))
* **release:** publish the Homebrew cask and an MCP bundle with every release ([521e05d](https://github.com/AbdurahmanAlmehdi/jidr/commit/521e05debca849667a77a9dfd3f97737057750f9))
* **release:** unsigned macOS app bundle, DMG, checksum and forbidden-content scan (Phase 12a) ([e13a935](https://github.com/AbdurahmanAlmehdi/jidr/commit/e13a935cde2bd8cef0024173409286abc8556ced))
* **root:** adb root mode with live switching, boot hook and verification (Phase 9c) ([285543f](https://github.com/AbdurahmanAlmehdi/jidr/commit/285543fe7093f39e4b4b481076687afe1ed1b34a))
* **root:** device.props.get/set — build-prop spoofing through the Magisk ramdisk (9f) ([c7d3da6](https://github.com/AbdurahmanAlmehdi/jidr/commit/c7d3da673319977a00cdc660c65dc8327f6ab9a5))
* **root:** Magisk mode (Phase 9d) ([cc9d1e9](https://github.com/AbdurahmanAlmehdi/jidr/commit/cc9d1e904324a1794db039fcaea152e83d665457))
* **root:** root.auto_grant for D22 auto-grant all (G15) ([418b583](https://github.com/AbdurahmanAlmehdi/jidr/commit/418b583a95582268c9a96432d94f9fae11ce6878))
* **root:** root.auto_grant for D22 auto-grant all (G15) ([3834178](https://github.com/AbdurahmanAlmehdi/jidr/commit/3834178c4c93034be9f96f8e9ff2fea7dd0700c6))
* **sdk:** core model, error codes, native SDK installer and AVD lifecycle (Phase 2) ([93d494c](https://github.com/AbdurahmanAlmehdi/jidr/commit/93d494c67f5743ac81f2d6fb885be505712a1af2))
* **site:** coming-soon landing page for jidr.ly (Phase 11a) ([92f1185](https://github.com/AbdurahmanAlmehdi/jidr/commit/92f11850fc6f5dc00e9c883665c0454442c21b94))
* **site:** go live as the coming-soon page with links that work ([991f78e](https://github.com/AbdurahmanAlmehdi/jidr/commit/991f78e41a71f1f140409269ecb2aada03637cf1))
* **site:** launch page with download, agents, CI and docs, plus Arabic RTL (Phase 11b) ([f0858e9](https://github.com/AbdurahmanAlmehdi/jidr/commit/f0858e91c5f9a32c78f826d86c013a9cc6e32324))
* **site:** rebuild the coming-soon page to the Workbench design (Phase 11a, D41) ([8a318ea](https://github.com/AbdurahmanAlmehdi/jidr/commit/8a318ea0c609421dcfe495a94e7f3430b4e73e62))
* **site:** use the brand kit for favicon, header symbol and social card (Phase 11a, D39) ([816e53f](https://github.com/AbdurahmanAlmehdi/jidr/commit/816e53f4b0a2a5b7e1fcf10c77f46116f828a804))
* **spike:** display + input spike passes, ADR-0001 frame transport (Phase 1) ([a09c8a2](https://github.com/AbdurahmanAlmehdi/jidr/commit/a09c8a20dd46482c18dc74dfd1a99fe55e939af9))
* **ui,widgets:** player window with direct gRPC frames, input, drag-drop and logcat (Phase 7c) ([463bda3](https://github.com/AbdurahmanAlmehdi/jidr/commit/463bda3d4577703215666bdb441e7687cef71130))
* **ui:** Build identity form for Full-root devices; docs for 9f ([4ca2a9b](https://github.com/AbdurahmanAlmehdi/jidr/commit/4ca2a9b7c0ea01ec1da5029af314f7fe9752f34a))
* **ui:** first-run setup, create/edit sheet, settings and command palette (Phase 7b) ([c877981](https://github.com/AbdurahmanAlmehdi/jidr/commit/c877981cbaa49dc9eaa7b80892bcaca90ff27e18))
* **ui:** root UX for Phase 9e (src/root) ([e1f8597](https://github.com/AbdurahmanAlmehdi/jidr/commit/e1f8597bd9bbd0e40f3c419a75691c3c69503d00))
* **ui:** root UX slots for Phase 9e (gap B8) ([a70ee36](https://github.com/AbdurahmanAlmehdi/jidr/commit/a70ee36a981e0618db7ee3e21f97b21da264a7db))
* **ui:** Workbench shell, generated theme, daemon bridge and snapshot harness (Phase 7a) ([a9de977](https://github.com/AbdurahmanAlmehdi/jidr/commit/a9de9773104292d4182a419e0ff7c78702c5c78f))
* **widgets,ui:** battery, sensors, network, phone, controls, dev tools, clipboard, fingerprint and camera widgets (Phase 8a) ([d9daeb4](https://github.com/AbdurahmanAlmehdi/jidr/commit/d9daeb47ce1f511f79e422af2e9e78ea83abdf32))
* **widgets,ui:** GPS fix and GPX/KML route replay with an OSM map panel (Phase 8b) ([05fabf5](https://github.com/AbdurahmanAlmehdi/jidr/commit/05fabf5d38e46835b24662a275610d3f37d4d917))
* **widgets,ui:** PNG screenshots and MP4/H.264 recording via VideoToolbox (Phase 10a) ([3fd4314](https://github.com/AbdurahmanAlmehdi/jidr/commit/3fd43140ccb7fcc5ef47e37b50c2a72bc80d37ec))
* **widgets,ui:** snapshot manager with root-mode tags and cross-mode refusal (Phase 10b) ([d702a26](https://github.com/AbdurahmanAlmehdi/jidr/commit/d702a26ca9c835a23ccd10f100e386f159d70812))


### Bug Fixes

* **backend:** launch the emulator with -sysdir for the device's image ([2c5e54b](https://github.com/AbdurahmanAlmehdi/jidr/commit/2c5e54b4ed2522d312699effc3df7793e09a5335))
* **backend:** launch the emulator with -sysdir for the device's image ([f70a090](https://github.com/AbdurahmanAlmehdi/jidr/commit/f70a0905fd6e36580a95e4cc280a0cd1af853cb2))
* **client:** never spawn the GUI as the daemon from Jidr.app ([7c5c8d3](https://github.com/AbdurahmanAlmehdi/jidr/commit/7c5c8d3fffbeacc493a84019c86669751c629cbb))
* **client:** never spawn the GUI as the daemon from Jidr.app ([fb93687](https://github.com/AbdurahmanAlmehdi/jidr/commit/fb93687e5f71a1506b77b70945432e25ee362949))
* **design:** Arabic landing type sizes in tokens.json (G13) ([f6d1462](https://github.com/AbdurahmanAlmehdi/jidr/commit/f6d14622c72c3bb1e04151341cd79086dbc2a2f1))
* **root:** back up the stock init so Magisk devices boot ([820df53](https://github.com/AbdurahmanAlmehdi/jidr/commit/820df53cf25692296665115e88e3d92e26f087fe))
* **root:** never leak the e2e emulator on failure, panic or a killed test run ([757f087](https://github.com/AbdurahmanAlmehdi/jidr/commit/757f087933489c9eae1e201744cd9d627bcb6c73))
* **root:** one guarded adbd switch for adb and Magisk modes; kick hung transports ([e610d7b](https://github.com/AbdurahmanAlmehdi/jidr/commit/e610d7b3b100cea1e10c31f36d1dba62ff25a5f3))
* **root:** wait and retry once when adb root hits a closed transport ([4fdea93](https://github.com/AbdurahmanAlmehdi/jidr/commit/4fdea937a4a130e3127de3aeeb04b5e34ed2067b))
* **root:** wait for adb after a cold boot or an adbd restart ([9a25719](https://github.com/AbdurahmanAlmehdi/jidr/commit/9a2571962231b4dc4043b902d44a6fa0baf2bf88))
* **root:** wait for adb after a cold boot or an adbd restart ([143c510](https://github.com/AbdurahmanAlmehdi/jidr/commit/143c5101284f2c5029d97be1be0923af4a4c4798))
* **scripts:** accept an absolute CARGO_TARGET_DIR in the e2e scripts ([8fc9680](https://github.com/AbdurahmanAlmehdi/jidr/commit/8fc96802c8acf1a16a9b58adcab544e51ce24a79))
* **site:** take the Arabic landing type sizes from jidr.css until tokens.json has them (G13) ([4d284af](https://github.com/AbdurahmanAlmehdi/jidr/commit/4d284af36b224f4254c00180257ca9994003873a))
* **ui:** room for the Play Store card's three-line note ([5395e6a](https://github.com/AbdurahmanAlmehdi/jidr/commit/5395e6a6c5b5686f2b7894ce5ee31820582afca2))
* **ui:** show the auto-grant toggle as disabled without root.auto_grant ([7dff8ae](https://github.com/AbdurahmanAlmehdi/jidr/commit/7dff8aec4fd1885fb1041faa6424139f37dd5b2f))
* **widgets,ui:** snapshot path traversal, AppleScript injection, stuck recordings, per-device record state ([64e78ab](https://github.com/AbdurahmanAlmehdi/jidr/commit/64e78abbb985f2c36a9915dcdf9e62399750b4aa))
* **widgets:** app.launch starts the launcher activity with am start -W and confirms it ([3564e70](https://github.com/AbdurahmanAlmehdi/jidr/commit/3564e70481d55ac9d85512c70fb4ba3a425199c7))
* **widgets:** build on Linux and keep snapshot tags when the emulator renames folders ([c0c1832](https://github.com/AbdurahmanAlmehdi/jidr/commit/c0c1832b38824014700a17001aa7159f4db57e71))
* **widgets:** network.set checks the radio took gsm data; retry mobile waits ([b3d14ab](https://github.com/AbdurahmanAlmehdi/jidr/commit/b3d14abd5ff3cb9b784bbb4436dafc3c1b90a66f))
* **widgets:** network.set checks the radio took gsm data; retry mobile waits ([c993da8](https://github.com/AbdurahmanAlmehdi/jidr/commit/c993da871fb767d3f2eeee2408a998c6c713f43c))
* **widgets:** snapshot.load waits until the device answers adb again ([1074699](https://github.com/AbdurahmanAlmehdi/jidr/commit/10746993cba4235867fedbe8aad8b555ace0b1a3))
* **widgets:** switch mobile data at the emulated radio; wait for voice service before calling ([a5c7dc7](https://github.com/AbdurahmanAlmehdi/jidr/commit/a5c7dc702eecef1276738c363bd79e7bb771213b))
