# SwiftUI parity: 68 golden scene mapping (M0 audit)

> 这是 M0 的行为级审计记录，由 68 个 golden 场景逐行映射而来；摘要与模块矩阵见 [swiftui-parity.md](swiftui-parity.md)。判定口径：**有入口** = 场景的主要 UI 与行为都有对应实现，仅细节差异；**部分** = 有入口但一项以上可见/行为要素缺失；**缺失** = 无入口或无法到达该状态。

- 基线：`master@b46a2f3`（`feat(gui): add SwiftUI prototype`），只读审计，未修改任何已跟踪文件、未提交、未 push。
- 参考实现：Slint 正式 UI `crates/jidr-ui`（Rust 逻辑 + `ui/*.slint` + `tests/golden` 204 张 PNG，68 场景 × dark/light/rtl）。
- 待迁移实现：`apps/jidr-swiftui-prototype`（`Center/` 设备中心与设置、`Sources/` 播放器与工具、`bridge/` Rust 助手）。
- 方法：`team_task_list` / `team_task_get` 取证后，逐文件 read/grep；未运行 emulator、未启动 GUI、未跑构建。行号均来自本次实际读到的代码版本。凡依赖运行时行为、代码无法单独证明的，标“待确认”。
- 文件缩写（证据列）：Slint 侧相对 `crates/jidr-ui/`：`goldens.rs`=`src/goldens.rs`，`root/goldens.rs`=`src/root/goldens.rs`，`ui/*.slint`=`ui/*.slint`；SwiftUI 侧相对 `apps/jidr-swiftui-prototype/`：`Center/DeviceViews.swift`、`Center/DeviceModel.swift`、`Center/AdvancedTools.swift`、`Sources/GameWindow.swift` 等。

## 0. 结论摘要（数字）

| 状态 | 场景数 | 占比 |
|---|---|---|
| 有入口 | 7 | 10.3% |
| 部分 | 49 | 72.1% |
| 缺失 | 12 | 17.6% |
| 合计 | 68 | 100% |

跨场景的结构性结论（比单个场景更影响迁移）：

1. **设备窗口形态不同**：Slint 把「设备屏幕」做成主工作台内的 device tab（`ui/app.slint:297-367`；golden 的 11 个 `player-*` 由 `goldens.rs:246-276` 的 `device_tab` 生成，另三个 `launcher-device-*` 是 Library 视图，见 `goldens.rs:354-361,409-424`），SwiftUI 只有独立播放器窗口（`Sources/GameWindow.swift:570`，`Center/DeviceModel.swift:329-364`），主窗口没有设备 tab。
2. **小组件面板位置不同**：Slint 的 Battery/GPS/Network/Sensors/More 是设备 tab 右侧常驻面板（`ui/player.slint:225-257`、`ui/app.slint:337-366`），SwiftUI 是每设备一个独立「高级工具」窗口（`Center/AdvancedTools.swift:7-25`、`106-144`）。
3. **无 RTL、无全局快捷键、无重连、无任务列表**：这四项在 Slint 侧都是独立模块（`ui/theme.slint:7` 的 `rtl`、`ui/app.slint:194-255`、`src/bridge.rs:120-152`、`ui/shell.slint:130-153`），SwiftUI 侧 grep 不到实现（详见第 2 节）。
4. **Root 只做了“粗粒度状态”**：SwiftUI 有验证成功/失败文本与重试（`Center/DeviceViews.swift:938-969`），没有 Slint 的 5 步时间线、日志尾、停止并回退、Play Store 等待/授权倒计时/未验证分支（`src/root/root.slint:19-32`、`486-548`、`src/root/steps.rs:9-53`）。

---

## 1. 68 个 golden 场景逐项映射

判定口径：**有入口** = 场景意图的主要 UI 与行为都有对应实现，仅细节差异；**部分** = 有入口但场景中一项以上可见/行为要素缺失；**缺失** = 无对应入口或无法到达该状态。

### 1.1 Launcher / 设备中心（17 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 1 | launcher-first-run | `goldens.rs:293-300` | `Center/DeviceViews.swift:1012-1022`（CenterView 空态） | 部分 | 无 `sdk-ready` 分支与三步 Setup 卡（`ui/launcher.slint:222-330`）；空态不区分 SDK 是否就绪，仅两个按钮 |
| 2 | launcher-loading | `goldens.rs:301-308` | `Center/DeviceModel.swift:65`（`notice="正在连接…"`）+ `Center/DeviceViews.swift:1118` | 部分 | 无居中加载态（`ui/app.slint:281-289`），空列表先显示“我的设备 0” |
| 3 | launcher-loading-devices | `goldens.rs:309-317` | `Center/DeviceModel.swift:243-260` | 部分 | 已加载过设备时无“正在刷新”提示；`library_loading` 语义无对应 |
| 4 | launcher-populated | `goldens.rs:318-321` | `Center/DeviceViews.swift:1009-1116` | 有入口 | 详情卡只有 CPU/RAM/屏幕/DPI（1064-1067），缺 Slint 的 Disk/Image/Profile 行（`ui/launcher.slint:45-55`）；无 toast（`src/app.rs:106-134`） |
| 5 | launcher-populated-1280 | `goldens.rs:322-325` | `Center/DeviceViews.swift:1008-1117` | 有入口 | 响应式靠固定 HStack+`ViewThatFits`（`1069-1075`），非设计断点 |
| 6 | launcher-default-size | `goldens.rs:326-329` | `Center/main.swift:15-17`（1050×700，min 800×550） | 有入口 | 默认尺寸 1050 与 Slint `1085×714`（`ui/app.slint:185-186`）不一致，属有意差异 |
| 7 | launcher-tasks | `goldens.rs:330-337` | 无 | 缺失 | 完全没有任务列表/取消 UI（`ui/shell.slint:130-153`、`ui/app.slint:412-418`）；仅 SDK 安装可取消（`Center/DeviceModel.swift:214-222`） |
| 8 | launcher-device-details | `goldens.rs:338-345` | `Center/DeviceViews.swift:56-155` | 部分 | 无 Session（uptime/上次启动）、无 Magisk 版本与 `Busy · in use by`；有 Root 验证/恢复（`Center/DeviceViews.swift:117-134`） |
| 9 | launcher-device-details-compact | `goldens.rs:346-353` | `Center/DeviceViews.swift:136`（固定 620×560） | 部分 | 无紧凑/滚动变体（Slint 面板 `min(680, w-40)`，`ui/launcher.slint:180-182`） |
| 10 | launcher-device-stopped | `goldens.rs:354-361` | `Center/DeviceViews.swift:983-986`、`1025-1034`、`1062` | 有入口 | 该场景是 Library 视图：列表+详情卡状态“已停止”+启动/删除/设置都在；差异为无 toast、状态用圆点+文字而非 Slint StatusPill（`ui/components/status.slint`） |
| 11 | launcher-game-list | `goldens.rs:362-387` | `Center/DeviceViews.swift:1085-1116` | 有入口 | 无 `games-note`/`games-message` 的 daemon 文案（`ui/launcher.slint:88,99`），空态文案硬编码（1096） |
| 12 | launcher-install-error | `goldens.rs:388-396` | `Center/DeviceModel.swift:301-303` + `Center/DeviceViews.swift:1118` | 部分 | 仅把“空间不足”本地化；无错误 toast（tone/9s 停留，`src/app.rs:111-133`），其余错误原样透出 |
| 13 | launcher-device-booting | `goldens.rs:409-416` | `Center/DeviceModel.swift:156-158`、`237-242`；`Center/DeviceViews.swift:1027`、`1062`、`1076-1078` | 有入口 | Library 状态+详情卡百分比有；列表行无百分比（`1027` 只显示状态词）、无过渡色状态点，未收到 `device.boot` 事件前无百分比 |
| 14 | launcher-boot-progress | `goldens.rs:417-424` | 同上 | 有入口 | 同上；`device.boot` 事件仅在 `receive` 里记百分比（`Center/DeviceModel.swift:156-158`），列表/详情视觉与 golden 有差异 |
| 15 | launcher-empty | `goldens.rs:425-428` | `Center/DeviceViews.swift:1012-1022` | 部分 | 无三步卡片/“未安装 SDK”说明；不可达“带设备但加载中”的居中态 |
| 16 | launcher-error | `goldens.rs:429-448` | `Center/DeviceViews.swift:72-79`、`Center/DeviceModel.swift:25-35` | 部分 | 设备 crashed 状态有文案，但无错误 toast、无 root 失败步骤原因；失败原因需另开详情 |
| 17 | launcher-reconnecting | `goldens.rs:751-759` | 无 | 缺失 | 无 `Conn::Reconnecting` 等价物，只进程退出后一条 notice（`Center/DeviceModel.swift:113-119`） |

### 1.2 创建 / 编辑设备（9 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 18 | create-google-apis | `goldens.rs:449-452` | `Center/DeviceViews.swift:485-576`（NewDeviceView） | 部分 | 无“未安装镜像→创建前先下载”（`src/launcher/mod.rs:822-837`）；无 Root 模式卡片说明、宿主 RAM/CPU 提示、`start_after` |
| 19 | create-play-store | `goldens.rs:453-456` | `Center/DeviceViews.swift:517-537`、`Sources/DeviceCreation.swift:21-23` | 部分 | Play Store 仅在选择未安装镜像时可识别；Shell root 只在校验期拒绝，无卡片禁用+说明（`ui/device_form.slint:121-131`） |
| 20 | edit-device | `goldens.rs:457-460` | `Center/DeviceViews.swift:157-296` | 部分 | 单页 Form，无 Hardware/Startup/Camera/Data/Performance 五页（`ui/device_form.slint:45-55`）；错误文案中文硬编码（253、268） |
| 21 | edit-device-compact | `goldens.rs:461-464` | `Center/DeviceViews.swift:283`（固定 560×660） | 部分 | 固定高度，900×600 下会超屏；无分页/滚动适配 |
| 22 | edit-device-preset | `goldens.rs:465-468` | `Center/DeviceViews.swift:179`、`188-189`、`207-217` | 部分 | 预设与自定义屏宽高有，但无页签 UI；预设表含 1080×2400 可命中该场景 |
| 23 | edit-device-startup | `goldens.rs:469-472` | `Center/DeviceViews.swift:220-230`、`249` | 部分 | 快速启动/自动休眠/摄像头控件存在但混在同一页；无“冷启动一次…”在页面内（有整窗按钮 249） |
| 24 | edit-device-camera | `goldens.rs:473-476` | `Center/DeviceViews.swift:228-230` | 部分 | 前后摄 Picker 有；缺 Slint 的“仅后摄支持 virtualscene”提示与分页布局 |
| 25 | edit-device-data | `goldens.rs:477-480` | 无 | 缺失 | 编辑页没有数据位置/磁盘占用/管理快照/“不是完整备份”说明（`ui/device_form.slint:320-328`）；磁盘占用只在详情弹窗（`Center/DeviceViews.swift:115`） |
| 26 | edit-device-performance | `goldens.rs:481-484` | `Center/DeviceViews.swift:231-247` | 部分 | 画质 Picker+保存有（只写本地文件），但无页签、无 Slint 的保存反馈样式 |

### 1.3 命令面板（2 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 27 | palette | `goldens.rs:485-494` | 无（仅设备搜索框 `Center/DeviceViews.swift:1001`） | 缺失 | 无 ⌘K 命令面板，无跨设备/设置命令检索（`ui/palette.slint:9-148`、`src/palette/mod.rs`） |
| 28 | palette-filtered | `goldens.rs:495-505` | 无 | 缺失 | 同上；过滤/键盘上下选择/`Nothing matches` 空态全缺 |

### 1.4 快照（3 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 29 | snapshots-manager | `goldens.rs:506-514` | `Center/DeviceViews.swift:871-936`（SnapshotsView） | 部分 | 列表代替 3 列卡片+缩略图（`ui/snapshots.slint:111-203`）；无 banner（126-183 的 root-mode 汇总），无 Auto 标签、无大小/时间行 |
| 30 | snapshots-refusal | `goldens.rs:515-532` | `Center/DeviceViews.swift:924-926` | 部分 | 只有一行“不可恢复”+禁用恢复；无拒绝对话框、原因/提示/“Set up Full root…”动作（`ui/snapshots.slint:263-306`、`src/snapshots/mod.rs:242-311`） |
| 31 | snapshots-save | `goldens.rs:533-545` | `Center/DeviceViews.swift:904-909` | 部分 | 内联命名保存；无保存对话框、无“将标记为 Full root”root tag、无同设备其它快照体积提示（`ui/snapshots.slint:206-260`） |

### 1.5 播放器 / 设备窗口（12 个场景，含 game-install-error）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 32 | game-install-error | `goldens.rs:397-408`（GameWindow notice） | `Sources/GameWindow.swift:219-232`、`541-553` | 部分 | 仅状态条一行；无独立错误提示框、无重装动作；空间不足/签名冲突有映射（225-231） |
| 33 | player-running | `goldens.rs:546-549`（device_tab） | `Sources/GameWindow.swift:570`、`674-734`、`458-568` | 部分 | 是独立窗口而非设备 tab；无右侧组件面板、无底部 logcat 条；窗口恒为深色（`692`） |
| 34 | player-running-1280 | `goldens.rs:550-553` | 同上 | 部分 | 同上；窗口按流尺寸等比（`712-721`） |
| 35 | player-pixel-perfect | `goldens.rs:554-562` | `Sources/GameWindow.swift:512`、`699-711` | 部分 | 工具可切换原始像素；无 Slint 的 chip 文案与 `frame-w×frame-h` 显示（`ui/player.slint:447-475`） |
| 36 | player-fullscreen | `goldens.rs:563-570` | `Sources/GameWindow.swift:513` | 部分 | 直接 `toggleFullScreen`，无“设备画面 letterbox 占满窗口、隐藏 chrome”的视图态（`ui/player.slint:268-272,314-315`、`src/player/fullscreen.rs:1-9`） |
| 37 | player-fullscreen-reveal | `goldens.rs:571-585` | 无 | 缺失 | 无边缘热区唤出工具栏/面板（`ui/player.slint:596-609`） |
| 38 | player-apk-drop | `goldens.rs:586-599` | `Sources/GameWindow.swift:260-270` | 部分 | 拖放安装/复制有；无拖入时的标题/说明浮层（`ui/player.slint:477-518`） |
| 39 | player-logcat | `goldens.rs:600-608` | `Center/AdvancedTools.swift:262-303` | 部分 | 日志在独立“高级工具”窗口，不在设备窗口；无 `⌘L`、无折叠条、无错误计数徽标（`ui/player.slint:139-222,544-594`） |
| 40 | player-overlay | `goldens.rs:609-620` | 无 | 缺失 | 无 FPS/latency 调试浮层（`src/player/mod.rs:427-465`、`ui/player.slint:528-541`），也无性能面板（`ui/app.slint:861-874`） |
| 41 | player-recording | `goldens.rs:678-686` | `Sources/GameWindow.swift:95-112`、`507` | 部分 | 有开始/停止与状态文本；无录制时钟 Pill（`ui/player.slint:519-526`、`src/recording.rs:138-180`） |
| 42 | player-booting | `goldens.rs:687-694` | 无 | 缺失 | 设备未 running 时窗口打不开（`Center/DeviceModel.swift:348-350` 弹“设备尚未就绪”）；无启动中占位 |
| 43 | player-stopped | `goldens.rs:695-702` | 无 | 缺失 | 同上；无停止态设备视图+Start |

### 1.6 首次设置（4 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 44 | setup-1-find-sdk | `goldens.rs:703-706` | `Center/DeviceViews.swift:307-484`（InstallSDKView，`328-346` 读 sdk.status/image.list） | 部分 | 无独立 SetupWindow/步骤条；不扫描常见 SDK 路径（无 detect 行），只有 `sdk.status` 的 tools_sdk/private_sdk（427-439） |
| 45 | setup-2-license | `goldens.rs:707-710` | `Center/DeviceViews.swift:412-420`、`459-475` | 部分 | 有许可全文+勾选；无“滚到底才能接受”的门槛（`ui/wizard.slint:334-397`）、无 Decline 流程 |
| 46 | setup-3-download | `goldens.rs:711-714` | `Center/DeviceViews.swift:399-411`、`462-464` | 部分 | 有进度/取消/后台；无逐下载行（DownloadRow）与 ETA/字节明细（`ui/wizard.slint:50-111`） |
| 47 | setup-4-first-device | `goldens.rs:715-718` | `Center/DeviceViews.swift:485-576` | 部分 | 用 NewDeviceView 代替向导第 4 步；无向导内创建后自动进设备等衔接 |

### 1.7 设置（5 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 48 | settings-general | `goldens.rs:719-722` | `Center/DeviceViews.swift:751-755`、`776-790` | 部分 | 语言/外观在“通用”，默认 Root/快速启动在“设备默认值”，地图瓦片在“高级”；Slint 全在 General（`ui/settings.slint:282-379`） |
| 49 | settings-storage | `goldens.rs:723-726` | `Center/DeviceViews.swift:791-821` | 部分 | 路径/迁移 preflight/用量/清缓存都有；缺 SDK 状态 chip 与“Show in Finder”式入口（`ui/settings.slint:380-497`） |
| 50 | settings-agents | `goldens.rs:727-730` | `Center/DeviceViews.swift:756-775`（高级页内 MCP） | 部分 | 没有独立 Agents 页；缺 “Busy · in use by agent” 说明、工具清单、Claude Code/其它客户端片段（`ui/settings.slint:498-566`） |
| 51 | settings-about | `goldens.rs:731-734` | `Center/DeviceViews.swift:822-832` | 部分 | 有版本/更新/源代码/许可证链接；缺许可证表格与全文入口、Sponsor（`ui/settings.slint:633-672`） |
| 52 | settings-about-update | `goldens.rs:735-750` | `Center/DeviceViews.swift:710-731` | 部分 | 有“发现新版本/已最新”+链接；版本比较用 `compare(.numeric)` 而非 Slint 的 semver 解析（`src/settings/update.rs:36-46`），预发布/多段版本行为可能不同（待确认） |

### 1.8 Root（12 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 53 | root-progress | `root/goldens.rs:96-98` | `Center/DeviceViews.swift:938-969`（FullRootView，`947-954`） | 部分 | 只有 spinner+进度消息；无 5 步时间线/秒表/日志尾/“Stop and revert”/“Continue in background”（`src/root/root.slint:486-548`） |
| 54 | root-success | `root/goldens.rs:100-112` | `Center/DeviceViews.swift:955-957` | 部分 | 只有“Root 验证成功 + Magisk 版本”；无 su 证明、boot image 状态、耗时、“Save snapshot…”（`src/root/root.slint` Proof 区 `298-322`） |
| 55 | root-failed | `root/goldens.rs:114-136` | `Center/DeviceViews.swift:958-962` | 部分 | 有失败+重试；无失败步骤、日志尾、复制日志、回退未 root（`src/root/mod.rs:269-358`） |
| 56 | root-playstore-beta | `root/goldens.rs:138-150` | `Center/DeviceViews.swift:949`（仅一句提示） | 部分 | 无“等首次启动完成再装”的 waiting 态与 beta 标记（`src/root/root.slint:425-447`、`src/root/mod.rs:177-212`） |
| 57 | root-awaiting-grant | `root/goldens.rs:152-161` | 无 | 缺失 | 无引导授权态、无剩余时间 (`grant-left`)、无“Tap Grant on the device”交互（`src/root/root.slint:467`、`src/root/steps.rs:50-53`） |
| 58 | root-unverified | `root/goldens.rs:163-180` | `Center/DeviceViews.swift:958-962`（泛化失败） | 部分 | 无专门“未验证”状态与“重新授权/回退”说明；仅详情页显示“尚未验证”（`Center/DeviceViews.swift:72-79`） |
| 59 | root-devtools | `root/goldens.rs:182-184` | `Center/AdvancedTools.swift:348-374` | 部分 | 有模块安装/自动授权/系统证书/系统属性；无 Root badge/验证时间、无 Verify again/Revert（在设备详情里） |
| 60 | root-devtools-failed | `root/goldens.rs:186-188` | 无 | 缺失 | 无失败历史/失败步骤展示（`src/root/root.slint` RootDevTools 的 failed 分支 `751-800`） |
| 61 | root-devtools-no-auto-grant | `root/goldens.rs:190-194` | 无 | 缺失 | 没有 `commands.list` 能力探测（Slint `src/root/mod.rs:88-111`）；自动授权按钮恒显示、失败后才报错 |
| 62 | root-devtools-props | `root/goldens.rs:196-200` | `Center/AdvancedTools.swift:368-371` | 部分 | 6 个属性文本框+保存；无“已保存/下次冷启动生效”的对比展示与 props-supported 门控（`src/root/root.slint` PropsBlock） |
| 63 | root-devtools-props-edit | `root/goldens.rs:201-205` | `Center/AdvancedTools.swift:369-371` | 部分 | 无逐字段校验/错误定位（Slint `props::field_error`，`src/root/goldens.rs:296-299`），错误只进全局 message |
| 64 | root-devtools-certs | `root/goldens.rs:206-211` | `Center/AdvancedTools.swift:361-367` | 部分 | 有列表/安装/移除/验证；列表只读 subject/file，不显示 trusted 状态（`src/root/goldens.rs:235-252`） |

### 1.9 小组件（4 个场景）

| # | 场景 | Slint golden 渲染入口 | SwiftUI 入口（文件:行） | 状态 | 缺口 |
|---|---|---|---|---|---|
| 65 | widgets-gps | `goldens.rs:621-653` | `Center/AdvancedTools.swift:198-227`、`377-399` | 部分 | 有经纬度读写/地图/GPX-KML 路线播放暂停继续停止；缺高度/方位字段、路线进度/剩余时间、地图路线折线（`ui/widgets/panels.slint:499-716`） |
| 66 | widgets-network | `goldens.rs:654-661` | `Center/AdvancedTools.swift:228-261` | 部分 | 有 Wi-Fi/移动数据/速度档/代理；缺信号格、延迟档说明、网络说明文案（`ui/widgets/panels.slint:165-292`） |
| 67 | widgets-sensors | `goldens.rs:662-669` | `Center/AdvancedTools.swift:249-259` | 部分 | 有 8 类传感器读写；缺旋转控制、姿态预设（upright/flat/upside-down）、环境量滑杆与接近传感器（`ui/widgets/panels.slint:316-362`） |
| 68 | widgets-more | `goldens.rs:670-677` | `Center/AdvancedTools.swift:304-339` | 部分 | 有电话/SMS/信号/剪贴板/指纹/开发者选项；缺媒体键、摄像头选择、Auto-grant（`ui/widgets/panels.slint:364-497`） |

---

## 2. golden 未覆盖、但迁移必需的流程

| # | 流程 | Slint 侧实现（文件:行） | SwiftUI 侧现状（文件:行） | 状态 | 迁移要补 |
|---|---|---|---|---|---|
| 1 | 任务列表 / 取消长任务 | `ui/shell.slint:52-153`（JobRow/TasksDialog）、`ui/app.slint:412-418`、`src/launcher/mod.rs:305-320`（`jobs.cancel`）、`src/bridge.rs:29-36`（Data.jobs）、`src/app.rs:65-77`（任务列表渲染） | 只有 SDK 安装可取消：`Center/DeviceModel.swift:184-222`、`Center/DeviceViews.swift:462-464`；无任务列表 | 部分/缺失 | 中心级 job 模型 + 列表 + 逐项取消 |
| 2 | daemon 断线与自动重连 | `src/bridge.rs:17-27,96-153`（3s 健康检查、2s 重试、`Conn::Reconnecting`）、`src/app.rs:241-257`、`goldens.rs:751-759` | 中心桥只 `connect_or_spawn` 一次（`bridge/src/bin/jidr-center-bridge.rs:66-73`），进程结束仅一条 notice（`Center/DeviceModel.swift:113-119`）；播放器侧有重连策略（`Sources/GameWindowState.swift:22-26`、`Center/DeviceModel.swift:375-380`） | 缺失 | 中心连接状态机 + 重试 + 断线 UI；重连后重新拉取设备/任务 |
| 3 | 配置文件损坏 | `src/settings/mod.rs:57-62`（prefs 静默默认）、`src/player/window_state.rs:97-125`（校验+拒绝覆盖）、`src/player/keymap.rs:144-155`、`src/player/game_shortcuts.rs:114-141` | 窗口状态/画质/键位有校验与“未覆盖”提示（`Sources/GameWindowState.swift:51-58`、`Sources/WindowQuality.swift:30-48`、`Sources/KeyMapping.swift:39-83`）；中心 prefs 解析失败被忽略（`bridge/src/bin/jidr-center-bridge.rs:114-121` + `Center/DeviceModel.swift:121-127` 无失败分支） | 部分 | 中心偏好损坏提示与恢复；统一“拒绝覆盖”口径 |
| 4 | 安全退出（设备/任务/录屏/窗口） | `src/app.rs:366-410`（`begin_native_quit`）、`src/macos_dock.rs:138-163`、`src/shutdown.rs:9-44`、`src/app.rs:345-363`；测试 `tests/quit.rs` | `Center/main.swift:24-50`：有外部播放器/录屏/忙任务/游戏窗口四道拦截，`center.quit` 只 `daemon.quit`+等 pid（`bridge/src/bin/jidr-center-bridge.rs:253-275`），无 Slint 的 AVD 静止校验（`src/shutdown.rs:38-44`） | 部分 | 退出前 AVD/快照静止校验；把“等待任务”从硬拦截改可取消（对齐 Slint 语义需产品确认） |
| 5 | 多窗口与 Dock 菜单 | `src/app.rs:150-168`（多窗口容器）、`src/player/game.rs:350-554`（每设备一窗）、`src/macos_dock.rs:170-234`（Dock 列出游戏窗口） | 每设备播放器 `Center/DeviceModel.swift:95-97,329-364`、高级工具窗 `Center/AdvancedTools.swift:7-25`、中心单主窗 `Center/main.swift:15-21`；无 Dock 菜单 | 部分 | Dock/窗口菜单、窗口间一致性；旧版独立播放器互斥（`Center/DeviceModel.swift:383-385`）需移除 |
| 6 | APK 签名冲突重装 | `src/player/mod.rs:656-723`（`app.inspect`→`app.uninstall`→`file.install`，确认框 666-676）、`src/player/drop.rs:74-77`；游戏窗口仅提示 `src/player/game.rs:257-258` | 中心：`Center/DeviceModel.swift:419-424` 直接 `file.install replace:true`，无 inspect/uninstall，无重装确认；播放器：`Sources/GameWindow.swift:227-228` 只映射文案 | 部分/缺失 | 中心侧冲突→确认→卸载重装（会删数据）完整流程 |
| 7 | APK 安装后自动启动应用 | `src/player/mod.rs:703-721`（安装后 `app.launch`，失败降级“已安装”） | 中心安装后不启动（`Center/DeviceModel.swift:291-307`）；播放器仅提示状态（`Sources/GameWindow.swift:219-232`） | 部分 | 安装成功后启动或至少提示“启动” |
| 8 | 录屏中关闭窗口/退出 | Slint 游戏窗口关闭不拦录屏（`src/player/game.rs:1165-1174`），录屏是 daemon job（`src/recording.rs:138-180`），窗口关闭后任务是否继续**待确认** | 双层拦截：游戏窗 `Sources/GameWindow.swift:735-738`、中心退出 `Center/main.swift:32`；录屏集合仅内存（`Center/DeviceModel.swift:67,437-452`） | 部分 | 关闭前确认/自动 stop，并把“保存中”持久化到 job 状态 |
| 9 | 截图（保存+剪贴板） | `src/recording.rs:112-136`（存 `~/Pictures/Jidr` 并复制到粘贴板）、`src/launcher/mod.rs:189-214`（打开截图目录） | 中心 `Center/DeviceModel.swift:425-436` 用 NSSavePanel 单文件保存 + 打开 `Pictures/Jidr`；播放器 `Sources/GameWindow.swift:86-93` 也是 NSSavePanel；不复制到粘贴板 | 部分 | 默认目录/自动复制语义需对齐或产品确认 |
| 10 | 拖放分类（APK / 文件 / Magisk 模块） | `src/player/drop.rs:18-43`（classify）、`74-77`（签名冲突识别）、`src/player/mod.rs:577-654`（module→`root.module.install`，未知方法降级 `file.push`） | `Sources/GameWindow.swift:260-270` 只 `sendFile`（apk 也走 send_file）；中心 `Center/DeviceModel.swift:419-424` 有 APK/文件两种但无模块分类 | 部分 | 拖放按扩展名与 root 模式分派；模块安装入口已在高级工具（`Center/AdvancedTools.swift:352`） |
| 11 | 键位映射编辑与损坏恢复 | `src/player/keymap.rs:144-169`（校验/原子写）、`src/player/game.rs:1384+` 测试；映射面板 `ui/app.slint:795-823` | `Sources/KeyMapping.swift:39-83`（校验/基线对比/原子写，测试 `Tests/Mapping/main.swift`）；编辑 UI `Sources/GameWindow.swift:521-540` | 有入口 | 与 Slint 的右键删除/旋转分方案（`ui/app.slint:814`）待确认是否需要 |
| 12 | 可配置游戏快捷键 | `src/player/game_shortcuts.rs:56-141`（保存/读取/冲突）、按键面板 `ui/app.slint:875-890` | 无对应实现（播放器快捷键固定：`Sources/GameWindow.swift:379-387`） | 缺失 | 快捷键配置面板+文件（`game-shortcuts/*.json`） |
| 13 | 快照跨 Root 恢复拒绝 | `src/snapshots/mod.rs:242-311`（拒绝弹窗+“Set up Full root…”动作）、`ui/snapshots.slint:263-306` | 只有 `restorable` 禁用 + 一行说明（`Center/DeviceViews.swift:924-926`） | 部分 | 拒绝原因、目标 root 模式、恢复动作按钮 |
| 14 | 首次启动无 SDK 引导 | `ui/launcher.slint:249-327`（三步卡）、`ui/wizard.slint:113-587`、`src/wizard/mod.rs` | 空态两按钮（`Center/DeviceViews.swift:1012-1022`）+ InstallSDKView sheet | 部分 | Setup 向导步骤条/检测/许可/下载/首设备串联 |
| 15 | 存储迁移 | 两侧都只做 preflight：Slint `src/settings/mod.rs:355-443`、`ui/settings.slint:398-403`“Data migration is not yet available”；SwiftUI `Center/DeviceViews.swift:669-706`、`bridge/src/bin/jidr_center/migration_preflight.rs` | 同左（README:38 也声明未实现） | 一致（都未实现） | M0 不要求；迁移要补的是“真正切换数据目录+快照恢复验证”，属后续里程碑 |
| 16 | 语言切换即时生效 + RTL 镜像 | `src/i18n.rs:1-13`、`ui/theme.slint:7` 的 `rtl`、golden 的 `Variant::Rtl`（`goldens.rs:14-18`，204 张图的 1/3） | 语言切换即时生效部分实现（`Center/DeviceModel.swift:409-418`、播放器语言下发 `413`）；RTL grep 无任何实现 | 部分（本地化）/缺失（RTL） | RTL 是 D33 要求，需补布局方向策略；本地化细节见 task-2 审计 |

---

## 3. 每个模块的实现状态 / 验证状态建议值

验证状态口径：**未验证** = 无自动化测试也无验收记录；**离线测试** = 有单元/集成测试（不依赖 emulator/GUI）；**真机** = 有真实设备或真实游戏验收记录。本次审计未发现 SwiftUI 原型的“真机/真实游戏验收”证据，README 也自述未完成（`apps/jidr-swiftui-prototype/README.md:24,38`），故绝大多数只能是“未验证”，本表中没有任何模块达到“真机”。Slint 参考侧另有 golden 快照测试（`crates/jidr-ui/examples/snapshot.rs:1-97`）与 quit/emulator 集成测试（`crates/jidr-ui/tests/quit.rs`、`tests/player_emulator.rs`）。

| 模块 | 实现状态 | 验证状态 | 证据（SwiftUI 现状 / 已有测试） |
|---|---|---|---|
| 设备中心（列表/空态/状态/操作） | 部分 | 未验证 | `Center/DeviceViews.swift:996-1136`；无 UI 测试 |
| 设备详情 | 部分 | 未验证 | `Center/DeviceViews.swift:56-155`；无 UI 测试 |
| 创建 / 编辑设备 | 部分 | 离线测试 | `Center/DeviceViews.swift:157-296,485-576`；`Sources/DeviceCreation.swift` + `Tests/Creation/main.swift`（`test.sh:23-26`） |
| 任务列表 / 取消 | 未做 | 未验证 | 无；Slint 参考 `ui/shell.slint:130-153` |
| 命令面板 | 未做 | 未验证 | 无；Slint 参考 `ui/palette.slint:9-148` |
| 快照管理 | 部分 | 未验证 | `Center/DeviceViews.swift:871-936`；无测试 |
| 屏幕渲染 / 帧解码 | 部分 | 离线测试 | `Sources/FrameDecoder.swift` + `Tests/main.swift`（`test.sh:7-10`）；播放器桥 `bridge/src/main.rs` |
| 输入 / 键位映射 | 部分 | 离线测试 | `Sources/KeyMapping.swift` + `Tests/Mapping/main.swift`（`test.sh:11-14`） |
| 游戏窗口状态 / 画质 | 部分 | 离线测试 + GUI 测试 | `Sources/GameWindowState.swift`、`Sources/WindowQuality.swift`（`Tests/WindowState/main.swift`、`test.sh:15-22`）；窗口生命周期 `Tests/Window/main.swift:1-70`（由 `test-window.sh` 驱动） |
| 录屏 / 截图 | 部分 | 未验证 | `Sources/GameWindow.swift:86-112`；`Center/DeviceModel.swift:425-452`；无测试 |
| Logcat | 部分 | 离线测试 | `Sources/LogStream.swift:6-80`、`Sources/LogFilter.swift` + `Tests/LogFilter/main.swift`（`test.sh:40-44`）；`bridge/src/bin/jidr-center-bridge.rs:56-65,288-318` |
| 全屏 / 像素完美 / 性能面板 | 部分 | 离线测试（仅像素完美） | `Sources/GameWindow.swift:512-513,699-711`；像素完美在 `Tests/Window/main.swift:47-60`；性能面板无实现 |
| 拖放 / APK 安装（含签名冲突） | 部分 | 未验证 | `Sources/GameWindow.swift:114-127,260-270,219-232`；`Center/DeviceModel.swift:419-424`；无测试 |
| 小组件面板（电池/GPS/网络/传感器/更多） | 部分 | 未验证 | `Center/AdvancedTools.swift:184-374,377-399`；无测试 |
| Root 设置流程 | 部分 | 未验证 | `Center/DeviceModel.swift:308-328`、`Center/DeviceViews.swift:938-969`；无测试 |
| Root 开发工具（模块/证书/属性/自动授权） | 部分 | 未验证 | `Center/AdvancedTools.swift:348-374`；无测试 |
| SDK 安装 / 许可 | 部分 | 离线测试 + 集成脚本（合成源） | `Center/DeviceViews.swift:307-484`、`Sources/SDKInstallPlan.swift` + `Tests/SDK/main.swift`（`test.sh:27-31`）；`Tests/SDK/integration.py`、`Tests/SDK/cancel_integration.py`（合成许可/镜像） |
| 首次设置向导 | 未做（以 sheet 代替） | 未验证 | `Center/DeviceViews.swift:307-484,485-576` |
| 设置：通用 / 存储 / 高级 / 关于 / 更新 | 部分 | 离线测试（MCP 配置） | `Center/DeviceViews.swift:589-860`；`Center/MCPConfiguration.swift` + `Tests/MCP/main.swift`（`test.sh:32-35`）；更新检查 `710-731` 无测试 |
| MCP / Claude Desktop 配置 | 完整 | 离线测试 | `Center/MCPConfiguration.swift:4-39` + `Tests/MCP/main.swift` |
| 应用列表 | 部分 | 离线测试 | `Sources/AppListLoader.swift` + `Tests/AppList/main.swift`（`test.sh:36-39`）；UI `Center/DeviceViews.swift:1085-1116` |
| 本地化（中/英） | 部分 | 离线测试（覆盖率脚本） | `Tests/localization_coverage.py:1-20`（仅扫 Center 直接字面量）；播放器本地化 `Sources/GameWindow.swift:472-482` |
| RTL（D33） | 未做 | 未验证 | 无实现；Slint 参考 `goldens.rs:14-18`、`ui/theme.slint:7` 的 `rtl` |
| daemon 连接 / 事件 / 重连 | 部分 | 未验证 | `bridge/src/bin/jidr-center-bridge.rs:66-80`、`Center/DeviceModel.swift:148-179`；无重连 |
| 安全退出 | 部分 | 未验证 | `Center/main.swift:24-50`；无测试（Slint 参考 `crates/jidr-ui/tests/quit.rs`） |
| 多窗口 / 停靠 | 部分 | GUI 测试（窗口生命周期） | `Sources/GameWindow.swift:570-746`、`Center/DeviceModel.swift:95-97`；`Tests/Window/main.swift` |
| 存储迁移 | 未做（两侧同） | 离线测试（仅 preflight） | `bridge/src/bin/jidr_center/migration_preflight.rs:103+`（Rust 单测）；`Center/DeviceViews.swift:669-706` |
| 设计 token / 主题 | 未做 | 未验证 | SwiftUI 用系统色/硬编码；Slint token 由 `docs/design/tokens.json` 生成（`crates/jidr-ui/build.rs:1-15,146`） |

---

## 4. 结论

### 4.1 明确的缺失清单（按影响排序）

1. **daemon 连接无重连**（第 2 节 #2）：中心进程一旦断开，所有数据与操作失效且无法恢复；这是可用性级别缺口，也是 Slint 迁移的核心基础设施。
2. **无任务列表/取消**（#1）：SDK/镜像下载、root 设置、设备启停等长任务在 SwiftUI 只能等或看底部一行 notice；退出时还会被硬拦截（`Center/main.swift:34`）。
3. **设备窗口未进入工作台**：11 个 `player-*` 场景依赖 device tab（`ui/app.slint:297-367`、`goldens.rs:246-276`）；SwiftUI 只有独立窗口，导致 `player-booting`/`player-stopped` 完全不可达（`Center/DeviceModel.swift:348-350`）。三个 `launcher-device-*` 是 Library 视图，已判为有入口（1.1 #10/#13/#14），差距集中在列表/状态视觉细节。
4. **Root 体验降级为“粗状态”**：缺 5 步进度、日志尾、停止并回退、Play Store 等待/授权倒计时、未验证分支（`src/root/root.slint:19-32,486-548`），影响 12 个 root 场景与迁移验收。
5. **小组件面板未内嵌**：4 个 `widgets-*` 与 5 个 root 工具场景的可发现性/常驻性与 golden 不一致（独立窗口 `Center/AdvancedTools.swift:7-25` vs 常驻面板 `ui/player.slint:225-257`）。
6. **无全局快捷键**：⌘K/⌘L/⌘J/⌥⌘0/⌃⌘F/⌘N/⌘,/Esc 全部缺失（Slint `ui/app.slint:194-255`），也直接导致命令面板无法使用。
7. **无 RTL（D33）**：68 场景三分之一的 golden 是 RTL；SwiftUI 无任何布局方向处理。
8. **无命令面板**：⌘K 是 Slint 的主发现入口（`ui/palette.slint`、`goldens.rs:485-505`）。
9. **快照拒绝/保存对话框缺失**：只剩一行禁用说明（`Center/DeviceViews.swift:924-926`），跨 root 恢复会静默不可点，用户无法理解原因。
10. **编辑设备五页 UI 缺失，`edit-device-data` 完全没有入口**（`ui/device_form.slint:45-55,320-328`）。
11. **APK 签名冲突无重装流程**（第 2 节 #6）：中心只会失败，不提供“卸载重装（会删数据）”的确认路径。
12. **全屏/调试浮层/性能面板缺失**（`player-fullscreen-reveal`、`player-overlay` 两个场景为 0）。
13. **首次设置向导被 sheet 拼合**：步骤条、SDK 检测、许可滚到底、逐下载行均无（`ui/wizard.slint:113-587`）。
14. **设置 IA 与 Agents 页**：无独立 Agents 页与 agent 运行说明（`ui/settings.slint:498-566`）。
15. **录音/日志/性能等右侧状态显示**：无录制时钟、无窗口内 logcat 折叠条与错误计数徽标（`ui/player.slint:139-222,519-526`）。

### 4.2 不建议迁移的项目（附理由）

1. **Slint 自绘窗口装饰与红绿灯对齐**（`src/macos_dock.rs:16-75`）：SwiftUI 用原生标题栏；`Center/DeviceViews.swift:1005` 的 `padding(.leading,94)` 只是给原生红绿灯留位。移植会与 macOS 原生窗口行为打架。
2. **golden/offscreen/fixtures 渲染管线**（`goldens.rs`、`src/offscreen.rs`、`examples/snapshot.rs`）：这是 Slint 快照测试基础设施，应换成 SwiftUI 的 snapshot harness（XCUITest/ImageRenderer），而不是移植代码。
3. **Slint 主题文件**（`crates/jidr-ui/build.rs` 从 `docs/design/tokens.json` 生成 `ui/theme.slint`）：SwiftUI 应直接消费 `tokens.json`（或生成 Swift 常量），不要手抄 `theme.slint` 的色值/字号。
4. **gettext/.po 本地化管线**（`crates/jidr-ui/translations/`、`src/i18n.rs:1-13`）：SwiftUI 已有 `Resources/*.lproj/Localizable.strings` + 覆盖率脚本（`Tests/localization_coverage.py`），迁移期不要维护两套机制；只迁字符串内容。
5. **MockScreen 假屏与设备美术 fixtures**（`ui/player.slint:13-65`、`ui/assets/*generated.png`）：仅用于 golden 的固定画面；生产窗口不应内嵌假屏，golden 重做时可用截图 fixture 代替。
6. **开发/测试用环境变量钩子**（`src/app.rs:412-447` 的 `JIDR_PLAYER_DEVICE`、`src/player/mod.rs:726-735` 的 bench/drop、SwiftUI 的 `JIDR_PROTOTYPE_TEST_PASTEBOARD`）：不进产品路径。
7. **把独立旧版播放器 App 作为迁移目标**（`Sources/GameWindow.swift` + `Player/main.swift` + `build.sh`）：中心已内嵌同一套播放器代码（`build-center.sh` 编译 `Sources/GameWindow.swift`），双 App 还引入“旧版测试窗口互斥”（`Center/DeviceModel.swift:383-385`）。只保留一个入口。
8. **Slint 的 `draw-lights` 等 golden-only 属性**（`ui/app.slint:50-51`、`goldens.rs:41-51` 的 Reduce Motion 冻结）：测试伪影，不迁。
9. **把“主窗口内 device tab”当作纯 UI 细节照抄**：若要保留 tab 形态需产品决策（D41 Workbench 的窗口模型与 SwiftUI 原生窗口差异大）；建议先以“独立设备窗口 + 中心导航”达到功能 parity，再单独立项决定形态。
10. **Slint 的 RTL 逐像素镜像实现**（`ui/player.slint:319,607`）：RTL 目标要保留，但应在新布局体系里实现语义化 leading/trailing，而不是复制 Slint 的 `Theme.rtl ? … : …` 分支。

### 4.3 M0 建议的最小收口（供 lead 排期）

P0（否则无法验收迁移）：daemon 重连 + 任务列表/取消 + 设备窗口整合（tab 或中心内嵌）+ Root 5 步/停止回退 + 全局快捷键 + RTL 方案。
P1（golden 场景直接可见）：命令面板、快照拒绝/保存对话框、编辑设备分页（尤其 data 页）、设置 IA/Agents、全屏 reveal、调试浮层、录制时钟。
P2（细节对齐）：首次设置向导、小组件面板常驻化、截图/录屏语义、Dock 菜单、通知/toast 样式。

---

## 附录 A：待确认项

1. `media.record` 在关闭游戏窗口/设备停止时是否自动结束：Slint 关闭窗口不拦录屏（`src/player/game.rs:1165-1174`），SwiftUI 选择硬拦截（`Sources/GameWindow.swift:735-738`）；daemon 侧行为本次未验证。
2. 中心参数 `gameExecutable` 被保存但从未使用（`Center/DeviceModel.swift:98,104`），是否为遗留/未来用途。
3. 更新检查版本比较：SwiftUI `compare(.numeric)`（`Center/DeviceViews.swift:727`）与 Slint semver 解析（`src/settings/update.rs:36-46`）对 `1.2` vs `1.2.0`/预发布的行为是否一致。
4. Golden 未提供独立 `widgets-battery` 场景（只有设备默认 tab 隐含电池面板），是否有意。
5. `snapshots-save` 中“同设备其它快照体积”提示的来源（Slint `src/snapshots/mod.rs:316-363` 计算；SwiftUI 无）。
6. 设置存储页 SDK 状态 chip 与 Slint `sdk-state`（`ui/settings.slint:190`）的语义差异。
7. 语言切换对已打开播放器/高级工具窗口中动态错误文本（`OperationMessages`）的影响，见 task-2 审计。

## 附录 B：本次审计的覆盖与未覆盖

- 覆盖：`crates/jidr-ui` 的 `goldens.rs`/`root/goldens.rs` 全部 68 个 Case、`ui/*.slint`、`src/` 主要模块（app/bridge/shutdown/launcher/player/root/widgets/settings/snapshots/wizard/device_form/palette/recording/model/i18n/macos_dock/window_state/keymap/game_shortcuts）；SwiftUI 原型 `Center/*`、`Sources/*`、`bridge/src/*`、`Tests/*`、构建/测试脚本。
- 未覆盖（只读分析限制）：实际 UI 渲染与像素对比、真实 SDK/镜像安装、真实设备/游戏验收、daemon 运行时协议行为、RTL 视觉验证、macOS 辅助功能/输入法实测。
