# SwiftUI localization: English-mode gaps (M0 audit)

> 决定（2026-11-11）：保留现有三条本地化机制（中文 key 的 `.strings`、`t()`、内联三元），通过 CI 规则收口；动态错误改为英文或 code 化，allowlist 随 M2 修复收缩。只有新增第三种语言时才考虑英文 source 目录。RTL 不要求。

> M0 的本地化走查记录。三条机制、缺口清单、CI 规则建议与英文模式 top 10 见正文；摘要见 [swiftui-migration.md](swiftui-migration.md) 的 M0 一节。

- 基线：`master@b46a2f3`（工作区无已跟踪改动；本报告为未跟踪草稿）
- 范围：`apps/jidr-swiftui-prototype` 的 `Center/*.swift`、`Sources/*.swift`、`Player/*.swift`、`Resources/{en,zh-Hans}.lproj/Localizable.strings`，以及 `apps/jidr-swiftui-prototype/bridge` 的 Rust 诊断消息
- 方法：只读代码分析；辅助脚本 `target/m0/scan_localization.py`（输出 `target/m0/scan_raw2.txt`）做字面量扫描与分类，所有结论行号均已人工逐条核对；未启动 GUI、未运行构建
- 非测试 Swift 中 CJK 字面量：**629 处 / 去重 514 个**；`en.lproj` 214 个唯一 key（215 行，1 个重复键），`zh-Hans.lproj` 193 个唯一 key（194 行，同样重复 `"系统镜像"`）
- 结论先行：**去重后约 43 个中文 UI 串未走任何机制；扣除 3 个被英文固定文案临时遮住的日志错误和 4 个当前调用点不可达的桥接参数错误，英文模式可达路径上约 36 个**

---

## 1. 机制清单：三条本地化路径的使用位置与规模

### 1.1 机制 (a)：`.strings` 键值（中文串作 key，`en.lproj` 提供英文）

- 资源规模：`Resources/en.lproj/Localizable.strings` 214 个唯一 key；`Resources/zh-Hans.lproj/Localizable.strings` 193 个唯一 key，**21 个 key 只在 en 侧存在**（全部是播放器/高级工具文案，见 §4.6）。
- 代码里以 `LocalizedStringKey` 使用的 CJK 字面量：**192 处、154 个唯一 key**，全部在 `en.lproj` 有对应条目（现有检查与本次独立扫描均通过）。也就是说：**只要字符串出现在可本地化的初始化器字面量位置，机制 (a) 的翻译是齐的**；缺口全部在“不是 LocalizedStringKey”的地方。
- 代表位置：
  - `Center/DeviceViews.swift:84` `Text("设备详情")`；`:138` `.alert("更改 Root 模式？", …)`；`:228` `Picker("后置摄像头") { Text("默认") … }`；`:1132-1135` 删除确认 `alert` 的标题/按钮/正文
  - `Sources/GameWindow.swift:524-527` 键位编辑条 `Text("按键绑定中…")` / `Button("清空")/("取消")/("保存")`；`:547` `Button("重新连接")`
- 生效前提（本报告按成立处理）：视图树上有 `.environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))`。共 12 处显式 locale 注入：`Center/DeviceViews.swift:573/839/1121/1124/1126-1131`、`Center/AdvancedTools.swift:145`、`Sources/GameWindow.swift:555`。所有 sheet 和两个窗口都覆盖到。
- 重载细节（已验证，决定三元字面量算不算机制 (a)）：SwiftUI 的 `Text`/`Button` 等同时提供 `LocalizedStringKey` 初始化器与 `@_disfavoredOverload init<S: StringProtocol>`（见 SDK 的 `SwiftUICore.swiftinterface:23987`、`SwiftUI.swiftinterface:5312`）。用等价 mock 做 `swiftc` 重载实验（`target/m0/overload_probe2.swift`）确认：纯字面量、**字面量三元**、含插值的字面量都会选 `LocalizedStringKey`，只有 String 变量会落到 `StringProtocol` 重载。→ `Text(cond ? "A" : "B")` 走 .strings；A5 的第二支是因为缺 `"Root：%@"` 键，而不是没走机制。
- 打包事实：`build.sh` / `build-center.sh` 用裸 `swiftc` 出 app，并把两个 `.lproj/Localizable.strings` 拷进 `Contents/Resources`；center 的 `Info.plist` 里 `CFBundleDevelopmentRegion=zh-Hans`，独立 player 的 `Info.plist` 未写该键（默认 en）。中文 key + 双语表能工作，但“哪边是开发语言”在两个产物里不一致。

### 1.2 机制 (b)：显式双语助手 `t("中文","English")` / `model.text("中文","English")`

- 定义：`Center/DeviceModel.swift:183` `func text(_ chinese:String,_ english:String)->String { language == 0 ? english : chinese }`；`Center/AdvancedTools.swift:72` `private func t(_ zh:String,_ en:String)->String { model.text(zh,en) }`
- 规模：**249 个调用点**，传入 **238 个唯一中文源串**：
  - `t(…)` 127 处，全部在 `Center/AdvancedTools.swift`（该文件 129 个 CJK 字面量里 127 个走 t()，几乎全量覆盖）；
  - `model.text(…)` 122 处：`Center/DeviceViews.swift` 114、`Center/main.swift` 6、`Center/AdvancedTools.swift` 2。
- 代表位置：`AdvancedTools.swift:109`（`Text(t("环境模拟","Simulation")`）、`:352`（含插值的模块安装确认）；`DeviceViews.swift:92`（`LabeledContent(model.text("状态","Status"),…)`）、`:200`、`:1016`；`DeviceModel.swift:187/200/239/298`（notice/进度）；`Center/main.swift:31-44`（安全退出全部提示）。
- 这是**设备中心主界面的主力机制**，也是三条机制里唯一“不依赖视图环境、不可能漏”的路径。

### 1.3 机制 (c)：内联 `language == 0 ? "English" : "中文"` 与 `localized()` 前缀映射

- `language == 0 ?` 共 **26 处**，其中 12 处是上文 locale 注入（基础设施），真正用于选显示文案的 **12 处**：
  - `Center/DeviceModel.swift:27-32`（设备状态六态 `statusText`）；`:298`（操作完成）；`:302`（存储不足安装失败）
  - `Sources/GameWindow.swift:617-619`（侧边栏按钮 tooltip/无障碍标签）、`:649-651`（置顶按钮）、`:705`（原始像素放不下屏幕）
  - `Center/AdvancedTools.swift:283`（Logcat 流错误：英文模式用固定英文句遮住 `streamError`）
- 外加一个**变体 `localized()`**：`Sources/GameWindow.swift:472-482`，英文模式用 en.lproj 精确查键，并硬编码 3 个前缀映射（`连接已结束（`、`已绑定 `、`无法启动桥接：`）；播放器状态气泡在 `:545` 统一走它。**这个函数只认识 3 个前缀 + 精确键，播放器新增中文状态若没有 en 键就会原样露中文**（§2-B/§2-C 的根因）。
- 代表位置：`Sources/GameWindow.swift:462/541` 的 `"准备中"`/`"已连接"` 是内部哨兵值（不属机制 (c)，见 §2 排除项）。

### 1.4 语言状态与运行链路

- 中心：`Center/DeviceModel.swift:70` `@Published var language = 1`（默认中文），`:123` 从 `center.prefs.get` 读回，`:409-418` 通过 `center.prefs.set` 持久化并同步给已打开的播放器。
- 播放器：`Sources/GameWindow.swift:202` 从 `gui-prefs.json` 读 `language`；中心打开播放器时 `DeviceModel.swift:354` 注入 `player.transport.language = self.language`。
- 现有自动检查：`apps/jidr-swiftui-prototype/Tests/localization_coverage.py`（由 `test.sh:45` 调用），只扫 `Center/*.swift` 且只认 `Text|Button|Section|Picker|TextField|Label|LabeledContent|Toggle|.help` + 首参中文字面量；在当前基线**通过**。它覆盖不到 §2 的任何一条缺口（见 §4.1）。
- README 自述：`README.md:38` 已承认 “its language coverage is partial”。

---

## 2. 缺口清单：未走任何机制的 UI 可见中文串

> 统计：去重 **43 个中文串**（分组：A 10、B 2、C 10、D 7、E 14；B3 是无障碍泄露不是新串）；其中英文模式可达 **36 个**（扣除 §2-E7 的 3 个被遮日志错误、§2-D4 的 4 个当前不可达桥接校验错误）。所有条目的 `文件:行` 都已按基线核对；“显示处”给出最终渲染到界面的位置。

### 2-A 设备中心：String 状态 / AppKit 直接赋值（9 处 / 10 个串）

| # | 文件:行 | 原文 | 为什么可能漏 | 建议修法 |
|---|---|---|---|---|
| A1 | `Center/DeviceViews.swift:241`（显示 `:246`） | `画质已保存，下次打开窗口生效。` | `qualityMessage` 是 `@State String`，`Text(qualityMessage)` 走 `Text(String)` 重载**原样渲染**，不查 .strings；en.lproj 也没有该键 | 改为 `model.text("画质已保存，下次打开窗口生效。","Quality saved; it applies next time the window opens.")` |
| A2 | `Center/DeviceViews.swift:253`（显示 `:250`） | `请检查名称、内存、CPU、分辨率和 DPI。` | 同上，保存校验失败直接给 `error` 赋 String | `model.text(…)`；或复用 `DeviceCreation` 的 Validation + `CenterModel.creationError` 映射模式 |
| A3 | `Center/DeviceViews.swift:268`（显示 `:250`） | `自动休眠时间必须介于 0 到 1440 分钟。` | 同上 | `model.text(…)` |
| A4 | `Center/DeviceViews.swift:286`（显示 `:246`） | `无法读取数据目录` | 同上；同类文案在 `DeviceModel.swift:351` 已有 `self.text("无法读取数据目录","Cannot read the data directory")` 版本，此处未复用 | 复用 `model.text("无法读取数据目录","Cannot read the data directory")`（建议抽常量） |
| A5 | `Center/DeviceViews.swift:921` | `Text(snapshot.quick_boot ? "快速启动快照" : "Root：\(snapshot.root_mode ?? "未知")")` | 三元第一支有 en 键（`"快速启动快照"` → “Quick-boot snapshot”），第二支是带插值的 LocalizedStringKey，查的是 `"Root：%@"`，en.lproj 没有 → 只有**非快启动快照行**露中文 `Root：`；`root_mode` 为空时还露 `未知` | 改成 `model.text("Root：\(mode)","Root: \(mode)")` 的字符串分支（或给 `"Root：%@"`/`未知` 补 en 条目） |
| A6 | `Center/main.swift:18` | `window.title = "Jidr SwiftUI 设备中心预览"` | `NSWindow.title` 是 AppKit String，不参与 LocalizedStringKey；`titleVisibility = .hidden` 只隐藏标题栏，Mission Control / Window 菜单 / 无障碍仍取该标题 | `model.text("Jidr SwiftUI 设备中心预览","Jidr SwiftUI Device Center Preview")` |
| A7 | `Center/DeviceModel.swift:426`、`:444`；`Sources/GameWindow.swift:89`、`:100` | `Jidr 截图.png`、`Jidr 录屏.mp4` | `NSSavePanel.nameFieldStringValue` 是 AppKit 字符串，完全绕开 SwiftUI 机制；且同一文案在两处重复 | 按 `language` 生成：英文模式 `Jidr screenshot.png` / `Jidr recording.mp4`（或中文文件名也保留为“Jidr screenshot”+时间戳） |
| A8 | `Sources/GameWindow.swift:630/632/633` | `隐藏侧边栏`（`NSImage` 的 accessibilityDescription、初始 toolTip、初始 accessibilityLabel） | AppKit 硬编码中文；`updateSidebarButton()` 之后会覆盖 toolTip/label（`:698`/`:613`），但 `image` 的 accessibilityDescription 不再更新，VoiceOver 仍可能读到中文 | 在 `addSidebarButton` 里用 `transport.language == 0 ? "Hide sidebar" : "隐藏侧边栏"`，或先调 `updateSidebarButton()` 再挂载 |
| A9 | `Center/DeviceModel.swift:65`（显示 `Center/DeviceViews.swift:1118`） | `@Published var notice = "正在连接…"` | 启动初始值；`displayNotice` → `OperationMessages.notice` 的 7 组 pair 里没有它，EN 模式下退回原值 → **每次启动中心都会短暂露中文**，直到首个 `device.list` 返回（`DeviceModel.swift:255` 才清空） | 初始值改为 `text("正在连接…","Connecting…")`，或让 `OperationMessages.notice` 覆盖它 |

### 2-B 播放器窗口：静态状态经 `localized()` 但无 en 键（3 条）

| # | 文件:行 | 原文 | 为什么可能漏 | 建议修法 |
|---|---|---|---|---|
| B1 | `Sources/GameWindow.swift:226`（显示 `:545`） | `安装失败：模拟器存储空间不足，请先释放空间。` | `JIDR_OPERATION` 诊断 → `readable` → `onStatus` → `Text(localized(status))`；`localized()` 只做 en.lproj 精确查键，键不存在 → 原样返回中文 | 加 en.lproj 条目（如 `"安装失败：模拟器存储空间不足，请先释放空间。" = "Install failed: the emulator is out of storage. Free some space first.";`）或把这条并入 `localized()` 前缀映射/统一消息目录 |
| B2 | `Sources/GameWindow.swift:228`（显示 `:545`） | `安装失败：应用签名不匹配，原应用及数据未删除。` | 同上；对应 APK 签名冲突重装流程 | 同上（`"Install failed: app signature mismatch; the existing app and data were not removed."`） |
| B3 | `Sources/GameWindow.swift:566` | `.accessibilityValue(status)` | 状态气泡的可见文本已 `localized(status)`，但无障碍值直接传原始中文 `status`；EN 模式 VoiceOver 会读中文（`"已连接"`/`"准备中"` 等也包含在内） | `.accessibilityValue(localized(status))`，并把 `"已连接"`/`"准备中"` 哨兵映射为英文/空值 |

### 2-C 播放器侧 bridge 的 Rust 中文诊断（3 组协议来源 / 10 个串；JIDR_* 协议 → `onStatus` → `localized()` 无键）

| # | 文件:行 | 原文 | 为什么可能漏 | 建议修法 |
|---|---|---|---|---|
| C1 | `bridge/src/main.rs:559`（消费于 `GameWindow.swift:219-232`） | `截图已保存` / `应用已安装` / `文件已发送到设备下载目录` | bridge 把成功文案直接塞进 `JIDR_OPERATION.message`；Swift 侧只滤 `INSTALL_FAILED_*`，其余原样进状态气泡；en.lproj 无这些键 | 二选一：bridge 改发稳定 code（`{"code":"screenshot.saved"}`）由 Swift 查表；或给 `localized()` 增加这些精确键 |
| C2 | `bridge/src/main.rs:396`、`:404` | `请选择有效的本地文件路径` / `请选择本地文件，不支持文件夹` | `run_file_operation` 的 `bail!` → `JIDR_OPERATION {"ok":false,...}` → 同 C1 路径 | 同上（bridge 侧用英文 + code，Swift 侧映射中文） |
| C3 | `bridge/src/main.rs:526/534/538/539/547` | `录屏路径无效或文件已存在` / `正在录屏` / `录屏已保存` / `录屏失败：{error}` / `停止录屏失败：{error}` | `JIDR_RECORD.message` → `GameWindow.swift:205-217` → `onStatus` → `localized()` 无键；**每次开始/结束录屏都会露** | 同 C1；至少把 5 条加入 `localized()` 的精确键/前缀映射并补 en.lproj 条目 |
| C4 | 同上文件，其余英文诊断（如 `Frame stream failed: …`、`Input failed: …`） | 英文 | 不含中文，EN 模式无问题；但它们反向说明 bridge 诊断没有语言契约：英文行原样进中文 UI（见 §3.4） | 统一走 code + 参数，而不是预制显示文案 |

### 2-D 中心侧 bridge 的 Rust 中文诊断（4 处来源 / 7 个串）

| # | 文件:行 | 原文 | 为什么可能漏 | 建议修法 |
|---|---|---|---|---|
| D1 | `bridge/src/bin/jidr-center-bridge.rs:121` | `偏好设置格式错误` | `gui-prefs.json` 内容不是 JSON object 时 `center.prefs.get/set` 返回该 message → `NSError.localizedDescription` → `notice`/`message` → `displayNotice`（`OperationMessages.notice` 无此 pair）或 `Text(message)` 原样中文；对应“配置损坏”流程 | bridge 返回 `code:"prefs.invalid"`，Swift 查表；或扩展 `OperationMessages` 双向词表 |
| D2 | `jidr-center-bridge.rs:150` | `数据目录不可用` | `center.prefs.set` 时数据目录不存在 → 同上（数据目录被删/迁移失败后） | 同上 |
| D3 | `jidr-center-bridge.rs:269` | `后台进程没有正常退出` | `center.quit` 100×100ms 未退出 → `main.swift:44` 拼“无法安全退出：”+该中文，EN 模式得到 `Unable to quit safely: 后台进程没有正常退出` | 同上（安全退出主流程，建议优先修） |
| D4 | `jidr-center-bridge.rs:128/220/224/237` | `无效的界面设置` / `缺少工具类型` / `缺少路径` / `未知工具类型` | 当前 UI 参数固定（语言/外观 0-2、kind `"sdk"/"jdk"`），实际不可达；但同属“桥接层直出中文”的隐患 | 同 D1，改 code；或在 Rust 侧直接改成英文常量（中心已有 ZH 翻译层） |

### 2-E Swift 动态错误（LocalizedError / NSError，中文 message 进入 UI 文案）

| # | 文件:行 | 原文 | 为什么可能漏 | 建议修法 |
|---|---|---|---|---|
| E1 | `Sources/WindowQuality.swift:52` | `设备标识无效。` / `游戏画质配置无效。` | `error.localizedDescription` 是普通 String；在 `DeviceViews.swift:242/289`（`Text(qualityMessage)`）、`DeviceModel.swift:362`（`notice` → `displayNotice`）、`GameWindow.swift:684`（`onWarning` → 中心 notice）直接展示，无翻译层 | 改成 `LocalizedError.errorDescription` 走 `model.text`（该类型拿不到语言状态，可把错误改为带 code 的 enum，由 UI 层映射）；或把这两条加入中心消息词表 |
| E2 | `Sources/GameWindowState.swift:77` | `设备标识无效。` / `窗口设置无效，原文件未覆盖。` / `窗口设置已被其他程序修改，未覆盖原文件。` / `数据目录不可用，未保存窗口设置。` | 同 E1；中心路径经 `player.onWarning → notice` 露中文（`DeviceModel.swift:357`）。独立 player 没有 `onWarning`，这些错误被静默丢弃 | 同 E1；顺带修独立 player 不展示窗口设置错误的问题 |
| E3 | `Sources/KeyMapping.swift:49` | `键位方案无法读取，请检查原文件；未进行覆盖。` | `mapping.error` → `GameWindow.swift:504` `onStatus?(mapping.error ?? …)` → `localized()` 无键 → 中文 | 加 en.lproj 条目并让 `localized()` 查得到（或 `KeyMappingStore` 存 code，UI 层 `model.text`） |
| E4 | `Sources/KeyMapping.swift:72` | `请先为选中的位置绑定按键` | `save()` throw 的 `NSLocalizedDescriptionKey` → `GameWindow.swift:529` catch → `onStatus` → 中文 | 同 E3 |
| E5 | `Sources/KeyMapping.swift:76` | `键位方案已在其他位置修改，请取消编辑后重新打开。` | 同 E4（保存冲突场景） | 同 E3 |
| E6 | `Center/DeviceModel.swift:117` / `:138` / `:176` | `后台连接已结束` / `后台未连接` / `操作失败` | 自建 `NSError` 的 `NSLocalizedDescriptionKey` 中文；daemon 退出/未连接时，所有在途/新发调用失败 → 各视图 `error = failure.localizedDescription` / `notice = error.localizedDescription`（如 `Center/DeviceViews.swift` 的 `SettingsView` 621/625/635/641/645 行、`EditDeviceView` 279 行、`NewDeviceView` 510/557/565 行）→ `Text(error)` 或 `displayNotice` 原样展示 | 中心调用层统一把失败转成 `OperationMessages.error(code, language)`；至少这三条加入 notice/error 词表 |
| E7 | `Sources/LogStream.swift:48/76/79` | `日志连接已结束。` / `日志量过大，部分内容未接收。` / `日志数据过大，连接已停止。` | **英文模式不会露**（`AdvancedTools.swift:283` 用固定英文句遮住），但错误细节丢失、且中文模式依赖这三条未进机制的文案；属于“不可复用、双模式都别扭”的中间态 | 改 code + `model.text` 两端渲染（英文模式显示具体英文原因，中文模式显示中文） |

### 2-F 明确排除项（不是 UI 缺口，避免误报）

- **内部哨兵/比较串**：`Sources/GameWindow.swift:462` `"准备中"`、`:541/558/560/562` `"准备中"`/`"已连接"`、`:559` `"连接已结束"`/`"无法启动桥接"` 前缀判断、`:477` `"）"` 字符处理；`Center/DeviceModel.swift:65` 的哨兵比较逻辑、`:255` 的 `"正在连接…"` 比较。这些字符串要么被显示条件排除，要么只用于分支判断（`status` 真正显示前会经 `localized()`）。
- **翻译数据表本身**：`Sources/OperationMessages.swift:10-18` notice pairs、`:24-33` exact、`:35-41` prefixes、`:47-59` known、`:61-65` prefixes；`Center/DeviceModel.swift:227-234` creationError 表。它们是机制的一部分，不是“漏”。
- **仅中文模式构造的串**：`OperationMessages.swift:43` `"操作失败："`（`error()` 在 `language != 0` 时才走到）。
- **已被其他机制覆盖、但扫描易误报的闭环**：`Sources/DeviceCreation.swift:16-22` 的 6 条校验文案（16/17/18/19/20/22 行）→ `Center/DeviceModel.swift:224-236` 的 `creationError` 精确映射，6 条全部覆盖（已验证）；`Sources/OperationMessages.swift` 全部输出串都有语言分支。
- **非 UI 用途**：Rust 的 `eprintln!`/`fputs` usage 文案、`println!`/日志、`#[cfg(test)]` 断言与测试夹具、`Tests/**` 里的中文断言（例如 `Tests/SDK/main.swift:22-32`）、`wasCancelled` 的 `cancelled/canceled` 关键字匹配、协议标识（`status.state`、`root.mode`、`INSTALL_FAILED_*`、JSON key）、注释。
- **用户/第三方文本**：设备名、app 名、快照名、Android 镜像 tag、Google licence 正文、`© OpenStreetMap contributors`（许可署名，不应翻译）、品牌/专有名词（Android SDK、JDK、GPS、Logcat、Magisk、Root、Shell）。

---

## 3. 动态错误信息：OperationMessages 与 bridge 诊断的中英切换现状

### 3.1 `OperationMessages`（`Sources/OperationMessages.swift`）的能力边界

| 函数 | 中文→英文（language 0） | 英文→中文（language 1） | 未命中时 |
|---|---|---|---|
| `notice` | 仅 7 组 pair 能翻成英文；其余转 `progress` | 同 7 组 pair 反查；否则 `progress` 翻译 | `progress` 直通原值 → EN 模式露中文 |
| `error` | **直接 `return value`**（无任何映射，靠上游本来就是英文） | 8 条 exact + 5 条 prefix；否则 `"操作失败：" + value` | ZH 模式露英文 |
| `progress` | 直通原值 | 11 条 known + 6 条 prefix | ZH 模式露英文 |

- 结论：**EN 模式没有任何“中文→英文”的错误翻译兜底**（`error` 直接早退、`notice` pair 只有 7 组、`progress` 直通）。而中文 source 恰恰来自：Swift 自建 `NSError`/`LocalizedError`（§2-E）、对位 bridge 的 17 条中文诊断（§2-C/§2-D）。
- pair 表在 `notice()` 里同时承担“已本地化 notice 的恒等回读”（`model.notice` 先由 `text()` 写入、再经 `displayNotice` 过一遍 `notice()`）；其中 `"录屏已保存"`/`"正在保存录屏…"`/`"正在启动录屏…"` 等组对当前显示结果没有影响（`progress()` 直通也不会改变），属于**冗余而非缺口**，但会随文案漂移成为维护负担。

### 3.2 数据源语言现状（已抽查全仓库 Rust）

- `crates/jidr-core`、`jidr-daemon`、`jidr-client`、`jidr-widgets`、`jidr-root`、`jidr-sdk` 的**用户可见错误/进度串均为英文**（唯一中文出现在 `jidr-widgets/src/game_list.rs:256-257` 的测试夹具）。→ EN 模式下 daemon 侧诊断不构成中文泄漏；反之 **ZH 模式下未列入 `OperationMessages.error` 的英文错误会直接露英文**（`error()` 未知分支加 `"操作失败："` 后缀，UI 里即中文前缀 + 英文正文）。
- 同仓库的 Slint GUI（`crates/jidr-ui`）已有成熟方案可参考：`crates/jidr-ui/src/i18n.rs` 的 `i18n::text(en, zh)` + Slint bundled translation（`translations/zh_CN/LC_MESSAGES/jidr-ui.po`），且动态状态用 `device_label()` 做替换式翻译——本原型的两套机制（t/text 与 .strings）本质上重复又割裂。

### 3.3 两条桥接链路的诊断契约现状

1. **中心链路**：`jidr-center-bridge` 把 `json!({"type":"error","message":…})` 发回 Swift；`DeviceModel.receive`（`:176`）转 `NSError`；各视图用 `failure.localizedDescription` 展示。bridge 里中文错误 7 条、英文错误若干（`missing device`、`Invalid map tile URL`、`Map tile URL must use HTTPS…`、`missing destination` 等）——语言不统一，无 code 字段。
   - 特例：`SettingsView` 对 `"Map tile URL must"` 做了字符串包含判断再翻中文（`DeviceViews.swift:763`），属于“按英文原文匹配”的脆弱耦合；若 Rust 改文案，中文提示静默失效。
   - 移民预检的 4 条英文 reason（`migration_preflight.rs:18/25/33/46`）与 `Center/DeviceViews.swift:696-701`（`SettingsView.checkMigration`）的 switch 精确匹配，同样脆弱（好处是 ZH 模式有中文）。
2. **播放器链路**：`jidr-swiftui-bridge` 用 `JIDR_CLIPBOARD:` / `JIDR_MAPPING_PATH:` / `JIDR_RECORD:` / `JIDR_OPERATION:` 四个前缀 + `eprintln!` 文本协议；payload 里的 `message` 既有中文（§2-C）也有英文（`Frame stream failed: …`），Swift 侧 `GameWindow.swift:184-235` 分前缀解析、其余行直接 `onStatus`。
   - 好消息：`JIDR_CLIPBOARD` 的 `"Mac 剪贴板已变化，请重新复制"` 在 en.lproj 有键（`:213`），是“中文串 + en 键”路径的正确示范；其余三条前缀没跟上。
   - `JIDR_MAPPING_PATH` 只传路径，无显示文案，安全。

### 3.4 缺口归纳（按严重度）

1. **EN 模式无中文→英文兜底**：`OperationMessages.error` 早退 + bridge/Swift 中文错误 → 直接露中文（§2-C/D/E）。
2. **播放器状态没有中央消息目录**：`localized()` 只 3 个前缀 + 精确键，新增中文状态（含 bridge 文案）默认漏。
3. **反向（ZH 模式露英文）同样存在**：未知英文 daemon 错误、`LogStream.start` 的 `error.localizedDescription`、`SDKInstallPlan.PlanError`（无 `LocalizedError` 文案，系统英文文案）、`appsError` 拼接的英文尾缀。本次任务只要求英文模式，但 M1 若做统一消息层应一并处理。
4. **无语言协商/无 code**：bridge 不知道 UI 语言，也不返回可翻译的 code；`SettingsView` 只能按英文原文 `contains` 匹配，属于已知脆弱点。

---

## 4. 建议的自动检查规则（M1 加入 CI）与不建议的过度检查

### 4.1 现状：唯一检查 `Tests/localization_coverage.py` 的盲区

`Tests/localization_coverage.py`（`test.sh:45` 调用）只做：`Center/*.swift` + `Text|Button|Section|Picker|TextField|Label|LabeledContent|Toggle|.help` + **首参为字符串字面量且含中文** → 必须存在于 en.lproj。因此它漏掉：

- `Sources/*.swift`、`Player/*.swift` 全部（播放器侧 73 个 CJK 字面量 0 覆盖：`Sources/GameWindow.swift` 72 + `Player/main.swift` 1）；
- `Text(variable)` / `Label(variable)` / `Text(ternary)` 等非字面量首参（§2-A1/A9、A5 全部绕过）；
- `@State`/`@Published` String 赋值、`NSSavePanel`/`NSWindow.title`/`toolTip`/`accessibility*` 等 AppKit 调用；
- Rust bridge 诊断与 Swift 动态错误文案；
- `.strings` 侧一致性（重复键、en/zh key 差、占位符差异、尾随空格）。

### 4.2 建议新增的 CI 规则（按投入产出排序）

1. **扩大机制 (a) 扫描到全部非测试 Swift**：`Center` + `Sources` + `Player`；初始化器名单补齐 `Text/Button/Label/Section/Picker/TextField/Toggle/LabeledContent/Stepper/GroupBox/Menu/help/alert/confirmationDialog/navigationTitle/label`；并支持“首参表达式里含中文字面量”（如 `Text(cond ? "中文" : …)`）的检测。
2. **String 显示汇检查（新增，最有价值）**：先按语法近似列出所有 UI 汇：`Text(...)`/`Label(...)`/`LabeledContent(...)`/`.help(...)`/`.alert(...)`/`NSSavePanel.nameFieldStringValue`/`panel.prompt`/`NSWindow.title`/`NSImage.accessibilityDescription`/`toolTip`/`setAccessibilityLabel`/`.accessibilityValue`。规则：**含中文的字符串不得以 String 变量/字面量直接进入 UI 汇**，除非：(i) 由 `t()/model.text()` 产生；(ii) 由 `localized()`/`OperationMessages` 产生；(iii) 显式 `// i18n: ok` 白名单（并说明原因）。这能覆盖 §2-A/B 整类。
3. **动态错误汇检查**：扫 `.swift` 中 `NSLocalizedDescriptionKey:`/`errorDescription` 返回的中文字面量，要求同文件存在 `model.text`/`OperationMessages` 映射或白名单；同时对 `error.localizedDescription` 的展示点做人工评审清单（脚本输出，人工确认）。
4. **Rust 诊断契约检查**（bridge 两个 crate）：禁止 `JIDR_*`/JSON-RPC `message` 直接携带中文字面量；要求以 `code`（+ 参数）表达，或在 Rust 里用英文常量；对 `eprintln!` 日志类中文加白名单。另外加一条 Rust 测试：bridge 发出的用户消息集合非空且全部为 ASCII/code。
5. **英文模式输出回归**（最直接的防漏网）：用现有 `Tests/SDK/main.swift` 的模式扩展——
   - `OperationMessages.error/notice/progress` 语料测试：一组 bridge/daemon 真实消息（含中文样例）在 `language: 0` 时断言 `无 CJK`；
   - `localized()` 不可直接测（私有函数），建议抽出 `PlayerMessages.localize(_:language:)` 纯函数后用同样语料测试；
   - 用 `Tests/Window` 这类离屏测试启动 `CenterModel`/`Transport` 的状态消息集合做快照断言（不启动真 GUI）。
6. **`.strings` 卫生检查**：重复 key（当前 `"系统镜像"` 两边都重复）、en/zh key 双向差（当前 en 独有 21 条 → 允许列表并注明“key=中文，回落到中文正确”）、`%@` 占位符数量一致、键尾随空格（当前 `"请先保存或取消键位编辑。 "`、`"没有找到已安装的系统镜像。 "` 依赖尾随空格，建议显式注明或规范化）、死键（当前 10 条）。
7. **AppKit 文案专项 grep**：`nameFieldStringValue`、`NSWindow(.title`、`accessibilityDescription`、`toolTip`、`setAccessibilityLabel` 中出现 CJK 必须命中机制或白名单（当前 §2-A6/A7/A8 全部会命中）。

### 4.3 不建议做的过度检查

- **不要禁止注释/测试/日志里的中文**：`Tests/**` 断言、`eprintln!` 日志、`fputs` usage、测试夹具（如 `jidr-widgets` 的 `'游戏'`）不是 UI，机械全仓库 grep 只会制造噪声。
- **不要禁止 `.strings` 的 zh 值、翻译表数据**：`OperationMessages` 表、`DeviceModel.creationError` 表、`zh-Hans.lproj` 的中文是机制本身。
- **不要要求所有 UI 串都走 `t()`**：机制 (a) `LocalizedStringKey` + en.lproj 已经是有效路径（当前 154 key 全覆盖），强制改 `t()` 是纯噪音；反之也不要因为某处用 `t()` 就要求 en.lproj 里有对应键。
- **不要对 Rust 全仓库“无中文”**：`crates/jidr-ui` 是 GPL Slint GUI，中文在 `zh_CN` 翻译目录与 `i18n::text` 里是合法设计；只约束 `bridge` 这两个 crate 的**用户可见诊断**。
- **不要逐字匹配英文原文做翻译**（类似 `SettingsView` 的 `contains("Map tile URL must")`）：应当做结构化 code；CI 不应鼓励这种耦合，也不应断言“中文文案字符串在 Rust 与 Swift 两端逐字一致”。
- **不要对第三方/系统文本做检查**：Google licence 正文、`© OpenStreetMap contributors`、`ByteCountFormatter`、NSSavePanel 系统按钮、Android 镜像 tag、设备/app/快照名。
- **不要强制“en 与 zh 键集合完全相等”为阻断错误**：当前 21 条 en-only 是中文 key 回落到中文（显示正确），应为“警告 + 待补”而非 fail；同理死键检查应是警告（含 `%` 占位的动态键）。
- **不要要求顺序一致或机器翻译质量检查**：.strings 的顺序没有语义；专有名词（Android SDK/JDK/Root/Magisk/Shell/GPS/Logcat）应保持原样而非翻译。

---

## 5. 结论：英文主流程最可能露中文的 Top 10

| # | 位置 | 露中文的原文 | 触发场景（英文模式） |
|---|---|---|---|
| 1 | `Center/DeviceModel.swift:426`、`Sources/GameWindow.swift:89` | `Jidr 截图.png` | 每次截图保存对话框（中心“常用操作→截图”与播放器侧栏“截图”）——默认文件名中文 |
| 2 | `Center/DeviceModel.swift:444`、`Sources/GameWindow.swift:100` | `Jidr 录屏.mp4` | 每次录屏保存对话框的默认文件名 |
| 3 | `bridge/src/main.rs:559` → `GameWindow.swift:219-232` | `截图已保存` / `应用已安装` / `文件已发送到设备下载目录` | 播放器窗口里每次截图、装 APK、发文件后的状态气泡（约 6 秒） |
| 4 | `bridge/src/main.rs:526-547` → `GameWindow.swift:205-217` | `正在录屏` / `录屏已保存` / `录屏失败：…` / `停止录屏失败：…` / `录屏路径无效或文件已存在` | 每次开始/结束录屏的状态气泡 |
| 5 | `Center/DeviceViews.swift:921` | `Root：<mode>` / `Root：未知` | 打开“管理快照”，任意非快速启动快照行（第一支“快速启动快照”有翻译，第二支没有） |
| 6 | `Sources/GameWindow.swift:226/228` | `安装失败：模拟器存储空间不足，请先释放空间。` / `安装失败：应用签名不匹配，原应用及数据未删除。` | 播放器窗口里重装 APK 失败（“APK 签名冲突重装”迁移流程正是此路径） |
| 7 | `Center/DeviceViews.swift:241`（显示 `:246`） | `画质已保存，下次打开窗口生效。` | 设备设置→声音与画面→保存画质（成功提示） |
| 8 | `Center/DeviceViews.swift:253/268`（显示 `:250`） | `请检查名称、内存、CPU、分辨率和 DPI。` / `自动休眠时间必须介于 0 到 1440 分钟。` | 设备设置里点“保存”时输入非法 |
| 9 | `Sources/KeyMapping.swift:49/72/76` → `GameWindow.swift:504/528-529` | `请先为选中的位置绑定按键` / `键位方案无法读取，请检查原文件；未进行覆盖。` / `键位方案已在其他位置修改，请取消编辑后重新打开。` | 播放器键位映射编辑（未绑键就保存、方案文件损坏/被并发修改） |
| 10 | `Center/DeviceModel.swift:65`（显示 `Center/DeviceViews.swift:1118`） | `正在连接…` | **每次启动设备中心**，首个 `device.list` 返回前页脚短暂显示 |

接近 Top 10（按可达性次之）：

- `Center/main.swift:18` `Jidr SwiftUI 设备中心预览`（Mission Control/Window 菜单可见；标题栏已隐藏）
- `Sources/WindowQuality.swift:52`、`Sources/GameWindowState.swift:77`（画质/窗口设置文件损坏时，经中心 notice 或 `qualityMessage` 露中文）
- `bridge/src/bin/jidr-center-bridge.rs:121/150/269`（`gui-prefs.json` 损坏、数据目录被删、退出时后台未结束 → `偏好设置格式错误` / `数据目录不可用` / `后台进程没有正常退出`）
- `Center/DeviceViews.swift:286` `无法读取数据目录`、`:242/289` 的 `error.localizedDescription`（画质存储失败时）
- `Sources/GameWindow.swift:630` `隐藏侧边栏`（VoiceOver 可能读到；toolTip/标签随后被覆盖）

---

## 附录 A：统计与核对方式

- 辅助脚本：`target/m0/scan_localization.py`（Swift 词法器 + 三种机制分类 + Rust 诊断提取），原始输出 `target/m0/scan_raw2.txt`。
- 关键计数：非测试 Swift CJK 字面量 629 处/514 唯一；机制 (a) 192 处/154 key；机制 (b) 249 调用点/238 唯一中文源串；机制 (c) 26 处（12 用于 locale 注入、12 用于选择文案、2 处内部/helper）；`en.lproj` 215 行/214 唯一 key（重复：`系统镜像`）；`zh-Hans.lproj` 194 行/193 唯一 key（重复：`系统镜像`）；en-only key 21；en 死键 10（`Android SDK`、`JDK`、`下载位置：%@`、`打开窗口`、`数据`、`数据迁移暂不可用；…`、`显示 SDK 目录`、`没有找到已安装的系统镜像。请先在原版设置中安装。 `、`自动休眠分钟数（留空跟随全局，0 为关闭）`、`设备运行中，停止后才能修改硬件设置。`——其中 `Android SDK`/`JDK` 值等于 key，属专有名词，正常）。
- 机制 (a) 逐条核对：对全部 21 个“字面量三元/分支”里的 CJK 字面量逐一比对 en 键，唯一缺失是 A5 的 `"Root：%@"`（及 `"未知"`），其余全部有翻译。
- 人工核对：本报告 §2/§3/§5 每条 `文件:行` 均用 `read`/`grep` 回到基线源码逐条确认（含显示位置与调用链）；未启动 GUI、未执行构建或测试套件（只跑过一次只读的 `Tests/localization_coverage.py`，通过；另用 `swiftc` 编译了两个等价 mock 做重载推断实验，文件在 `target/m0/overload_probe*.swift`）。
- 不确定/需后续确认：机制 (a) 的运行时生效依赖 SwiftUI 用 `.environment(\.locale)` 解析 `LocalizedStringKey`（本报告按任务前提 + 代码中 12 处 locale 注入确认，未做运行时截图验证）；重载推断已用 SDK 接口 + mock 实验验证（字面量/字面量三元均命中 `LocalizedStringKey`，String 变量走 `StringProtocol` 重载），不构成残余风险。

## 附录 B：可参考的既有设计

- Slint GUI 的双语路径：`crates/jidr-ui/src/i18n.rs`（`text(en,zh)`、`select(chinese)`、动态状态 `device_label()` 替换表）与 `translations/zh_CN/LC_MESSAGES/jidr-ui.po`；M1 迁移时可直接复用“英文 source + zh 目录”的方向，避免本原型的“中文 key 反向表”割裂与 en-only/zh-only 漂移。
