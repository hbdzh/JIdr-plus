# 原生 macOS 界面

SwiftUI/AppKit 是唯一桌面界面。`Center/main.swift` 管理设备中心、设置/工具窗口及集成播放器窗口；`bridge/` 中的 Rust 桥连接真实 daemon 和模拟器，设备状态保存在 daemon。

源码结构：`Center/DeviceViews.swift` 包含设备中心，创建设备、编辑设备和设置分别位于 `NewDeviceView.swift`、`EditDeviceView.swift`、`SettingsView.swift`。`DeviceModel.swift` 将界面连接到各状态所有者：`CenterRequestTracker.swift` 管理请求和进度，`CenterDeviceLifecycle.swift` 管理设备启停状态，`CenterWindowRegistry.swift` 管理播放器和工具窗口。`CenterBridgeProcess.swift` 负责桥进程及管道，`DeviceAppSearch.swift` 管理搜索调度；键盘、媒体和同步操作位于对应扩展。`Sources/PlayerTransport.swift` 负责播放器桥，`PlayerScreenView.swift` 负责渲染和输入，`GameWindow.swift` 管理播放器窗口。

设备库为空时显示创建设备指南，SDK 设置为次要操作；存在设备时显示搜索、概览、应用列表和设备操作。后台任务及设置始终可访问。停止的设备显示简短提示而非空应用列表，截图、安装和发送控件仅在运行时出现。

设备设置暂存画质、硬件和音频，保存时一并提交，取消不写入。daemon 失败时画质不变；本地画质写入失败时说明设备设置是否已经保存。高级工具使用原生侧栏和设备设置风格的详情表单，提供通话/短信、剪贴板、指纹、相机和开发者选项。SDK 镜像按 API 分组，常见变体排在专用镜像之前，并明确标注 16 KB 页大小。

概览将 APK 选择和拖放安装放在应用卡片中，即使应用少于七个也能管理全部应用；快照创建和管理放在快照卡片中。标题区提供设备设置、工具及紧凑的截图/录制/发送操作；「更多」仅包含重启、删除及进行中的 Root 设置入口。Root 验证位于 Root 工具中。相机来源只能在设备工具中编辑，设备设置页面链接到该位置并保留其他未保存的修改。

Root 工具调用 `root.writable_system`：在 API 31+ 且镜像支持 adb Root 的 Shell Root 设备上启用可写系统，或恢复原版只读系统；确认提示解释冷启动和 overlay 移除，停止中的设备下次启动时应用。显示的是 daemon 保存的写入配置，并非实时文件系统探测。

麦克风页面通过 `audio.inject` 和 daemon 任务向 Android 麦克风播放本地 WAV，可选循环，不使用 Mac 实时麦克风。关闭工具后播放继续，设备中心保留会话，重新打开后可停止。停止会取消所属任务，包括文件加载期间；页面也可停止 CLI/MCP 发起的注入。Android 应用必须打开麦克风才能消费音频。

Swift 源码使用 GPL-3.0-only（`LICENSE-GPL`），Rust 桥使用 Apache-2.0。`Resources/fonts` 字体保留 OFL 声明；Lucide 的 ISC 许可证在 `assets/lucide/LICENSE-lucide.txt`，原生界面图标使用 SF Symbols。

<a id="operation-recordings"></a>

## 操作录制

播放器侧栏提供「操作录制」窗口，记录归一化的触摸、按键和文本时间线，支持按次数、时长或无限循环播放，设置间隔和 0.25x–4x 速度，以及重命名、删除和导入/导出 JSON。脚本保存在 `<data>/scripts/`，是带版本的普通 JSON；由播放器桥本地录制和回放。v1 不包含旋转、录屏和文件操作；CLI/MCP 播放属于后续阶段。桥命令、通知和格式见[操作录制文档](../../docs/player-scripts.md)。

<a id="build-and-run"></a>

## 构建和运行

需要 macOS、Xcode、项目固定的 Rust 工具链和 protoc：

```bash
bash apps/miko-swiftui/build-center.sh
open target/swiftui-center/miko simulator.app
```

开发包包含真实 CLI、daemon 和桥。普通启动使用标准 Miko 数据目录，不自动安装 SDK 组件、接受许可证或启动设备。需要独立数据时，明确指定绝对路径 `MIKO_HOME` 并使用 `run-center.sh`。无需独立原型程序，设备由中心管理的播放器窗口打开。

```bash
MIKO_HOME=/absolute/path/to/disposable-test-home bash apps/miko-swiftui/run-center.sh
cargo xtask release --dry-run --scan
cargo xtask release --rehearsal
```

发行构建以 macOS 13 为最低目标，并检查 Mach-O 最低版本与生产 plist 是否一致；发行和演练产物位于 `target/`。Developer ID 签名、公证及完整游戏兼容性需要另行验证；ad-hoc 构建不能证明它们通过。

<a id="verification"></a>

## 验证

```bash
bash apps/miko-swiftui/test.sh
bash apps/miko-swiftui/test-center-ui.sh --interactive # 显示窗口；使用专用测试会话
bash apps/miko-swiftui/test-player-lifecycle.sh
bash apps/miko-swiftui/test-window.sh
bash apps/miko-swiftui/generate-tokens.sh --check
bash apps/miko-swiftui/snapshot.sh --check --only tools-battery-light
bash apps/miko-swiftui/bench-player.sh --self-test
```

截图测试使用隐藏、无序的 hosting 窗口，不激活测试应用，但仍需要已登录的 WindowServer。局部修改使用可重复指定的 `--only CASE`，`--list` 无需开窗即可列出场景；完整截图矩阵需显式指定 `--all`，适合 CI 或较大范围回归。确认过的视觉变更可用相同场景范围的 `--update` 更新基线。

`test-center-ui.sh --interactive` 检查真实焦点与响应者交接：它会显示窗口，应在专用会话运行或事先与用户安排前台访问；不加该参数会拒绝运行。测试使用临时主目录和 fixture 桥，不修改真实设备或 SDK。fixture 参数只用于测试，不能作为正常启动设置。交互式模拟会话须设置 `MIKO_UI_PREVIEW=1` 标明局限，并对不支持的设备命令返回拒绝，不能声称成功。

离屏位图缓存不能合成所有原生侧栏 vibrancy 和透明窗口材质；基线检查结构及内容，选中颜色、阴影和材质混合还需在真实应用中检查。

原生性能工具（`Tests/Bench`）可用于真实设备测量，参见 `bench-player.sh --help`、`render-live.sh`、ADR-0001 和 `docs/display-performance.md`。历史测量不能作为新的验收证据。

`bench-player.sh` 默认使用优化后的 Release 构建及实际 `GameWindowController`/`PlayerTransport`/`ScreenView` 路径，正常启动时可选观察回调为 nil。报告区分解码、UI 交接、不同图像绘制、输入到绘制延迟（不含系统投递和 GPU 扫描输出）、主队列延迟，以及各进程物理/峰值内存。7×7 探针使用已有解码字节并随对应图像传递，不增加整帧复制。原生最小化/恢复探针要求新解码帧；重新绘制最小化前的画面不能计为恢复。

在一次性真实设备及已安装的只读 SDK 上，以固定 1080×2400、4 核、4 GiB 配置采集三次可复现运行：

```bash
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk
```

工具在启动前构建，保存版本、二进制和输入哈希，拒绝源码有未提交改动的测量及遗漏触摸探针，记录尚未完成的手动、空间和全屏验收，只停止和删除自己创建的设备及目录。不下载 SDK、不接受许可证、不使用正常 Miko 数据。后续 A/B 对比应保持测量版本、屏幕刷新率、窗口大小和场景一致；`MIKO_BENCH_PROFILE=debug` 仅用于明确的构建模式比较。

播放器桥与输出写入器共享不可变 RGBA 缓冲区，在旋转或准备数据包之前预留唯一的等待帧槽位。JFR1 字节、画质、方向规则和队列满时丢弃新帧的策略不变；一个写入器确保头部与载荷完整写出，所有者存活到写入完成。启动应用或桥时，`MIKO_PLAYER_FRAME_TRANSPORT=legacy` 可选择复制数据包的回退路径用于回滚或对比，默认是 `shared`；该设置独立于输入调度。

同一二进制的比较先运行离线清理与顺序检查，再在一个一次性真实设备上运行三组交替顺序（legacy/shared、shared/legacy、legacy/shared）：

```bash
python3 scripts/test-player-baseline.py
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk --compare-frames
```

报告包含传输选择器和可执行文件哈希。应比较总显示 FPS、未过滤的帧间隔尾部、触摸/恢复探针和物理内存，包括失败运行；减少复制本身不能证明用户体验提升。旋转、通道、短写和生命周期测试位于 Rust 桥的 `frame_transport` 模块。

预先设定的验收限制：全部触摸和新帧恢复探针均被检测，流尺寸和画质一致，显示 FPS 中位数下降不超过 5%，每次触摸 p95 中位数上升不超过 `max(5 ms, 20%)`，最大恢复时间增加不超过 50 ms。超过限制须调查或延长重复对比；短时运行不能证明游戏或长时间行为。按进程报告内存；声称改善需桥的峰值内存中位数至少减少一帧 RGBA，或桥 CPU 可重复降低，不能相加无关进程内存。

输入由单个有界 FIFO 消费者处理（默认 `MIKO_PLAYER_INPUT_SCHEDULER=fifo`）。等待按键、触摸、剪贴板或工具栏 RPC 时仍接收帧。FIFO 输入/剪贴板使用独立的真实 gRPC 连接；克隆 Controller 仍会共享截图流 HTTP/2 流控。inline 回退路径保持共享连接。重复、按下/抬起、手势和剪贴板组合键不会合并或拆成独立事件任务；已有媒体/应用任务保持原有行为。`MIKO_PLAYER_INPUT_SCHEDULER=inline` 保留耦合调度分支用于回滚和同二进制测量。

输入状态只有一个所有者：RPC 前记录可能按下的输入，确认抬起后移除。EOF 先处理完排队命令再释放按住的输入；帧/输出丢失、SIGTERM 和 Ctrl-C 会取消进行中的输入并按按下顺序逆序尝试释放，包括临时剪贴板组合键。每次释放最多等待一秒；失败恢复也保持所有权直到抬起尝试结束，以便关闭时重试被中断的恢复。

```bash
python3 scripts/player-baseline.py --sdk /absolute/path/to/clean-test-sdk \
  --compare-input --seconds 20 --taps 60
```

此比较固定 shared 帧并交替 inline/FIFO 顺序。报告除触摸延迟外，还包括输入阶段接收/绘制 FPS、间隔和主队列时间线。已完成输入运行中的触摸遗漏会保留并继续采集其余组合；进程或渲染失败可能中止。任何探针失败都会使 `manifest.complete=false` 并返回非零退出码；`collection_complete` 仅表示计划中的运行已采集。验收要求所有 FIFO 探针、顺序/取消回归和新帧恢复通过，并满足相同的 5% FPS、`max(5 ms, 20%)` 触摸 p95 和 50 ms 恢复限制。输入阶段接收间隔 p95 目标小于 50 ms，且比 inline 至少低 50%；桥进程峰值内存应处于 inline 的一帧 RGBA 加 1 MiB 之内，播放器在 10% 之内。硬件输入法、游戏和物理多点触控须与离线协议顺序测试分开报告。

界面状态与交互回归还覆盖过滤选择、捕获目标的具名删除、详情失败/超时与重试、完整命令目录、停止设备的 Root/相机读取及偏好窗口尺寸。设备策略区分新建设备 Root 默认值与全局运行策略，验证数字输入并提示未保存修改。设备工具可直接打开；Root 配置与状态相邻，设备详情中的 Root 区域只读。路线播放使用代次令牌，防止已停止路线的回复修改后续路线状态。这些检查使用隔离 fixture，运行游戏、真实路线播放及实时 Root 修改仍需设备验收。

设备工具使用经过审核的紧凑集成布局，轻量面板附着于发起操作的中心或播放器窗口。168 点侧栏贯穿全高，导航下方显示简洁工具/设备标题及设备状态。原生 NSTableView 保留键盘和输入选中行为，使用标准 32 点行和模板 SF Symbols；AppKit 使用系统强调色及活动/非活动颜色绘制选择，不强制自定义浅色选择、固定图标色板或单元格强调。分组标题不浮动。

详情侧只有一个全宽页面滚动区域，包含标题、描述、设备停止提示和有限宽度的原生字段组；仅限制内容宽度，滚动条始终位于页面最右侧，组内不再套独立表单滚动区。主要操作位于输入组下方，关闭按钮固定右下角。初始尺寸 716 × 500，最小 660 × 460；切换工具不改变窗口尺寸。Root 入口直接选择 Root，切换工具保留相机草稿。

Escape 经响应者链传递，让输入组合和子 sheet 可优先处理；Cmd+W 关闭面板。前后相机选择器使用不同的辅助功能标签，仅允许应用改过的值，成功保存后更新基线；自动读取不显示修改成功提示。后台回归检查侧栏宽度与密度、全高背景、系统选择绘制和强调传递、跨组方向键导航、字段对齐、全宽页面滚动、稳定面板尺寸及相机草稿保留。焦点/响应者检查仍属于显式交互式测试。
