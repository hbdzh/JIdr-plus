// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

// MARK: - Player chrome
//
// The player window is always native dark chrome (GameWindow sets `darkAqua`),
// and the approved design specifies the dark token values for it, so resolve
// them explicitly. Colours still come from the generated token layer (D41);
// no raw hex or system colour is used here.

private enum PlayerChromePalette {
    /// Window ground and the titlebar seam.
    static let ground = JidrColor.surfaceChrome.dark
    /// The device toolbar: one step darker than the chrome ground.
    static let sidebar = JidrColor.surfaceBase.dark
    /// The folded Logcat strip and the log well: the darkest surface.
    static let logbar = JidrColor.logcatBackground.dark
    static let hairline = JidrColor.borderSubtle.dark
    /// The titlebar seam is one step stronger than the in-sidebar rules so the
    /// native titlebar visibly separates from the dark content.
    static let seam = JidrColor.borderDefault.dark
    static let icon = JidrColor.textSecondary.dark
    static let text = JidrColor.textSecondary.dark
    static let textDim = JidrColor.textTertiary.dark
    static let negative = JidrColor.negative.dark
    static let negativeBadge = JidrColor.statusNegativeContainer.dark
    static let negativeBadgeText = JidrColor.statusNegativeOnContainer.dark
    static let accent = JidrColor.accentFill.dark
    /// Active toolbar glyphs: the accent-text token is the accent colour meant
    /// for icons/text on dark surfaces (the fill token is for filled controls).
    static let accentIcon = JidrColor.accentText.dark
}

private enum PlayerChromeMetrics {
    /// 48 pt toolbar (WbLayout.windowDeviceToolbarWidth), 28 x 28 icon targets.
    static let toolButton: CGFloat = 28
    static let toolGlyph: CGFloat = 13
    static let toolSpacing: CGFloat = 3
    static let groupSeparatorWidth: CGFloat = 26
    static let logcatBarHeight: CGFloat = 30
    static let hairline: CGFloat = 1
}

/// One toolbar icon: a native borderless button with a 28 x 28 hit target.
/// macOS owns the hover/press/focus feedback (the previous custom fill was
/// dropped on purpose); the active state is only the accent (or recording red)
/// glyph colour, not a hand-drawn background.
private struct PlayerToolButton: View {
    let symbol: String
    let label: String
    var enabled = true
    var active = false
    var activeTint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PlayerChromeMetrics.toolGlyph, weight: .medium))
                .foregroundStyle(active ? (activeTint ?? PlayerChromePalette.accentIcon) : PlayerChromePalette.icon)
                .frame(width: PlayerChromeMetrics.toolButton, height: PlayerChromeMetrics.toolButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// Player-window chrome that is view state only (never a protocol command):
/// fullscreen + reveal, debug overlay, pixel-perfect chip, panels.
final class PlayerChromeState: ObservableObject {
    @Published var fullscreen = false
    @Published var reveal = false
    @Published var overlay = false
    @Published var pixelPerfect = false
    @Published var shortcutsPanel = false
    @Published var logcatOpen = false

    var pixelPerfectAction: (() -> Void)?
    var fitAction: (() -> Void)?
    var toggleFullscreenAction: (() -> Void)?
    var toggleSidebarAction: (() -> Void)?
    var chooseScreenshotAction: (() -> Void)?
    var toggleRecordingAction: (() -> Void)?
    var chooseAPKAction: (() -> Void)?
    var chooseFileAction: (() -> Void)?
    var advancedAction: (() -> Void)?
    var uninstallAction: ((String) -> Void)?

    private var revealHideWork: DispatchWorkItem?

    func showReveal() {
        revealHideWork?.cancel()
        revealHideWork = nil
        if !reveal { reveal = true }
    }

    /// Fullscreen chrome hides again when the pointer leaves the toolbar, with a
    /// short grace period so moving between the edge strip and the toolbar does
    /// not flicker.
    func hideRevealSoon() {
        guard reveal else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.reveal = false
            self?.revealHideWork = nil
        }
        revealHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func cancelHide() {
        revealHideWork?.cancel()
        revealHideWork = nil
    }
}

struct ContentView: View {
    @ObservedObject var transport: PlayerTransport
    @ObservedObject var mapping: KeyMappingStore
    @ObservedObject var sidebar: SidebarState
    @ObservedObject var chrome: PlayerChromeState
    @ObservedObject private var shortcuts: GameShortcutsStore
    @StateObject private var logStream = LogStream()
    @State private var notice: String?
    @State private var noticeGeneration = 0
    @State private var logLevel = "D"
    @State private var logFilter = ""
    @State private var showUninstall = false
    @State private var uninstallPackage = ""
    @State private var shortcutError: String?

    init(transport: PlayerTransport, mapping: KeyMappingStore, sidebar: SidebarState,
         chrome: PlayerChromeState = PlayerChromeState()) {
        _transport = ObservedObject(wrappedValue: transport)
        _mapping = ObservedObject(wrappedValue: mapping)
        _sidebar = ObservedObject(wrappedValue: sidebar)
        _chrome = ObservedObject(wrappedValue: chrome)
        _shortcuts = ObservedObject(wrappedValue: transport.shortcuts)
    }

    private var language: Int { transport.language }
    private var linkState: PlayerLinkState { transport.linkState }
    private var canReconnect: Bool {
        GameReconnectPolicy.permits(disconnected: linkState.canReconnect || transport.connectionEnded,
                                    editing: mapping.editing,
                                    recording: transport.recording != .idle,
                                    recordingUnknown: transport.recordingStateUnknown)
    }
    private var canLogcat: Bool { transport.logcatExecutable != nil && linkState.isRunning }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: WbSpace.zero) {
                VStack(spacing: WbSpace.zero) {
                    screenArea
                    if !chrome.fullscreen && chrome.logcatOpen && canLogcat {
                        logcatPanel
                    } else if !chrome.fullscreen && canLogcat {
                        logcatBar
                    }
                }
                if !chrome.fullscreen && sidebar.visible {
                    sidebarColumn
                }
            }
            if chrome.fullscreen {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { chrome.showReveal() } else { chrome.hideRevealSoon() }
                    }
                if chrome.reveal {
                    sidebarColumn
                        .wbShadow(WbShadow.popover)
                        .onHover { inside in
                            if inside { chrome.cancelHide() } else { chrome.hideRevealSoon() }
                        }
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .tint(PlayerChromePalette.accent)
        .background(PlayerChromePalette.ground)
        .overlay(alignment: .top) {
            if !chrome.fullscreen {
                Rectangle()
                    .fill(PlayerChromePalette.seam)
                    .frame(height: PlayerChromeMetrics.hairline)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.locale, Locale(identifier: language == 0 ? "en" : "zh-Hans"))
        .onAppear(perform: installHandlers)
        .onChange(of: chrome.logcatOpen) { _, open in updateLogStream(open: open) }
        .onChange(of: transport.linkState) { _, _ in updateLogStream(open: chrome.logcatOpen) }
        .onChange(of: logLevel) { _, _ in restartLogStream() }
        .onChange(of: logFilter) { _, _ in restartLogStream() }
        .onDisappear { logStream.stop() }
        .sheet(isPresented: $showUninstall) { uninstallSheet }
        .alert(t("重新安装应用？", "Reinstall the app?", language),
               isPresented: Binding(get: { transport.reinstallPrompt != nil },
                                    set: { if !$0 { transport.cancelReinstall() } })) {
            Button(t("取消", "Cancel", language), role: .cancel) { transport.cancelReinstall() }
            Button(t("卸载后重装", "Uninstall and reinstall", language), role: .destructive) { transport.confirmReinstall() }
        } message: {
            Text(t("已安装应用使用了不同的签名。重装会先卸载它，并删除该应用的应用数据。",
                   "The installed app was signed with a different key. Reinstalling uninstalls it first, which deletes its app data.",
                   language))
        }
    }

    // MARK: Screen + window state

    private var screenArea: some View {
        ZStack {
            PlayerView(transport: transport)
                .accessibilityLabel(t("设备画面", "Device screen", language))
                .accessibilityHint(t("用侧边栏按钮发送按键、截图或录屏。", "Use the sidebar buttons to send keys, take screenshots or record.", language))
            if !linkState.isRunning {
                stateCard
            }
            if chrome.pixelPerfect {
                pixelChip
            }
            mappingToggles
            if let drop = transport.dropHover {
                dropOverlay(drop)
            }
            if let notice, !notice.isEmpty {
                noticeBubble(notice)
            }
            if mapping.editing {
                mappingBar
            }
            if chrome.shortcutsPanel {
                shortcutsPanel
            }
            if chrome.overlay {
                debugOverlay
            }
            recordingPill
        }
    }

    private var stateCard: some View {
        VStack(spacing: WbSpace.md) {
            switch linkState {
            case .running:
                EmptyView()
            case .connecting:
                ProgressView().controlSize(.small)
                Text(t("正在连接设备…", "Connecting to the device…", language)).wbFont(WbType.body)
            case .booting(let progress, let message):
                if let progress {
                    ProgressView(value: progress).frame(width: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(t("正在启动设备…", "Starting the device…", language)).wbFont(WbType.body)
                if !message.isEmpty {
                    Text(message).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).multilineTextAlignment(.center)
                }
                Text(t("设备启动后画面会自动出现。", "The screen appears once the device has started.", language))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            case .stopped(let reason):
                Image(systemName: WbIcon.power).font(.system(size: WbIconSize.iconLg)).foregroundStyle(WbColor.textSecondary)
                Text(t("设备已停止", "The device is stopped", language)).wbFont(WbType.title)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).multilineTextAlignment(.center)
                HStack(spacing: WbSpace.sm) {
                    if transport.onStartDevice != nil {
                        Button(t("启动设备", "Start device", language)) { transport.startDevice() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                        .disabled(!canReconnect)
                }
            case .disconnected(let reason):
                Image(systemName: WbIcon.disconnected).font(.system(size: WbIconSize.iconLg)).foregroundStyle(WbColor.textSecondary)
                Text(t("连接已断开", "The connection was lost", language)).wbFont(WbType.title)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).multilineTextAlignment(.center)
                Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReconnect)
                if !canReconnect {
                    Text(reconnectBlocker).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                }
            }
        }
        .padding(WbSpace.lg)
        .frame(maxWidth: WbLayout.windowDeviceWidgetPanelWidth)
        .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.lg))
        .padding(WbSpace.xl)
    }

    private var reconnectBlocker: String {
        if mapping.editing { return t("请先保存或取消键位编辑。", "Save or cancel the key-mapping edit first", language) }
        if transport.recordingStateUnknown { return t("录屏状态未知，请先在设备中心确认。", "The recording state is unknown. Confirm it in the device center first.", language) }
        return t("请先停止录屏并等待保存完成。", "Stop recording and wait for it to finish saving first.", language)
    }

    @ViewBuilder private var mappingToggles: some View {
        if !mapping.editing && !mapping.scheme.bindings.isEmpty {
            VStack {
                HStack(spacing: WbSpace.sm) {
                    Button(mapping.enabled ? "停用键位" : "启用键位") { mapping.enabled.toggle() }
                    Button(mapping.hints ? "隐藏提示" : "显示提示") { mapping.hints.toggle() }
                    Spacer()
                }
                .wbFont(WbType.caption)
                .padding(WbSpace.sm)
                .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.md))
                .padding(.horizontal, WbSpace.sm)
                .padding(.top, 44)
                Spacer()
            }
            .allowsHitTesting(true)
        }
    }

    private var pixelChip: some View {
        VStack {
            HStack(spacing: WbSpace.sm) {
                Text(t("原始像素 · 1 设备像素 = 1 屏幕像素", "Pixel-perfect · 1 device pixel = 1 screen pixel", language))
                    .wbFont(WbType.label)
                Text("\(transport.frameWidth)×\(transport.frameHeight)")
                    .wbFont(WbType.code).foregroundStyle(WbColor.textSecondary)
                Button(t("适应", "Fit", language)) { transport.onFitScreen?() }.controlSize(.small)
            }
            .padding(.horizontal, WbSpace.md).padding(.vertical, WbSpace.sm)
            .background(WbColor.overlay, in: Capsule())
            Spacer()
        }
        .padding(WbSpace.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dropOverlay(_ drop: PlayerDrop.Label) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: WbRadius.xl)
                .strokeBorder(WbColor.accent, lineWidth: WbBorder.focus)
                .background(WbColor.accentContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: WbRadius.xl))
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(drop.title).wbFont(WbType.body.weighted(.semibold))
                Text(drop.body).wbFont(WbType.label).foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(WbSpace.lg)
            .frame(width: 290, alignment: .leading)
            .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.lg))
        }
        .padding(WbSpace.md)
        .allowsHitTesting(false)
    }

    private func noticeBubble(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(PlayerStatusText.translate(text, language: language))
                .wbFont(WbType.body)
                .padding(WbSpace.md)
                .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.md))
                .padding(WbSpace.sm)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var recordingPill: some View {
        if transport.recording != .idle {
            VStack {
                HStack(spacing: WbSpace.sm) {
                    Circle().fill(WbColor.negative).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        Text(recordingText)
                            .wbFont(WbType.label.weighted(.medium))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, WbSpace.md).padding(.vertical, WbSpace.xs)
                .background(WbColor.overlay, in: Capsule())
                Spacer()
            }
            .padding(WbSpace.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var recordingText: String {
        switch transport.recording {
        case .idle:
            return ""
        case .starting:
            return t("准备录屏…", "Preparing recording…", language)
        case .stopping:
            return t("保存中…", "Saving…", language)
        case .recording:
            let started = transport.recordingStartedAt ?? Date()
            return t("录制", "REC", language) + " " + PlayerRecordingClock.text(elapsed: Date().timeIntervalSince(started))
        }
    }

    private var debugOverlay: some View {
        VStack {
            Spacer()
            TimelineView(.periodic(from: Date(), by: 0.5)) { _ in
                let snapshot = transport.frameSnapshot()
                Text(debugText(snapshot))
                    .wbFont(WbType.code)
                    // No design token for it: the debug overlay keeps the terminal green of the Slint build.
                    .foregroundStyle(Color(red: 0.49, green: 0.99, blue: 0))
                    .padding(WbSpace.sm)
                    .background(WbColor.scrim, in: RoundedRectangle(cornerRadius: WbRadius.sm))
            }
            .padding(WbSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    private func debugText(_ snapshot: PlayerFrameStats.Snapshot) -> String {
        let latency = snapshot.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        return t("接收", "recv", language) + String(format: " %.0f fps", snapshot.receivedFPS)
            + " · " + t("画面", "frame", language) + " \(snapshot.width)×\(snapshot.height)"
            + " · " + t("旋转", "rotation", language) + " \(snapshot.rotation)"
            + "\n" + t("触摸→下一帧", "touch→frame", language) + " " + latency
            + " · " + t("设备内存由桥接采样，当前版本未接入", "device memory is sampled by the bridge; not wired in this build", language)
    }

    // MARK: Sidebar

    private func tool(_ title: String, _ symbol: String, enabled: Bool = true,
                      active: Bool = false, activeTint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        PlayerToolButton(symbol: symbol,
                         label: PlayerStatusText.translate(title, language: language),
                         enabled: enabled, active: active, activeTint: activeTint,
                         action: action)
    }

    private var sidebarColumn: some View {
        ScrollView(.vertical) {
            VStack(spacing: PlayerChromeMetrics.toolSpacing) {
                sidebarGroup {
                    tool("返回", WbIcon.back, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "back"]) }
                    tool("主页", WbIcon.circle, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "home"]) }
                    tool("最近使用", WbIcon.square, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "recents"]) }
                }
                sidebarSeparator
                sidebarGroup {
                    tool("电源", WbIcon.power, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "power"]) }
                    if transport.onAdvanced != nil {
                        tool(t("高级工具", "Advanced tools", language), WbIcon.advancedTools) { chrome.advancedAction?() }
                    }
                    tool("音量增大", WbIcon.volumeUp, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "volume_up"]) }
                    tool("音量减小", WbIcon.volumeDown, enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "volume_down"]) }
                    tool("向左旋转", WbIcon.rotateLeft, enabled: linkState.isRunning) { transport.send(["type": "rotate", "direction": 1]) }
                    tool("向右旋转", WbIcon.rotateRight, enabled: linkState.isRunning) { transport.send(["type": "rotate", "direction": -1]) }
                }
                sidebarSeparator
                sidebarGroup {
                    tool("键位映射", WbIcon.keyboard, enabled: linkState.isRunning, active: mapping.editing) {
                        if !mapping.editing {
                            if !mapping.begin() { transport.onStatus?(mapping.error ?? t("键位方案尚未加载", "The key mapping has not loaded", language)) }
                        }
                    }
                    tool(t("快捷键", "Shortcuts", language), WbIcon.command, active: chrome.shortcutsPanel) { chrome.shortcutsPanel.toggle() }
                    tool(transport.recording == .idle || transport.recording == .starting ? "开始录屏" : "停止录屏",
                         transport.recording == .idle || transport.recording == .starting ? WbIcon.record : WbIcon.recordStop,
                         enabled: linkState.isRunning,
                         active: transport.recording != .idle,
                         activeTint: PlayerChromePalette.negative) { chrome.toggleRecordingAction?() }
                    tool("截图", WbIcon.camera, enabled: linkState.isRunning) { chrome.chooseScreenshotAction?() }
                    tool("安装 APK", WbIcon.installAPK, enabled: linkState.isRunning) { chrome.chooseAPKAction?() }
                    tool("发送文件", WbIcon.folder, enabled: linkState.isRunning) { chrome.chooseFileAction?() }
                    tool(t("卸载应用", "Uninstall app", language), WbIcon.trash,
                         enabled: linkState.isRunning, active: showUninstall) { showUninstall = true }
                }
                sidebarSeparator
                sidebarGroup {
                    tool(t("调试浮层", "Debug overlay", language), WbIcon.performance,
                         enabled: linkState.isRunning, active: chrome.overlay) { chrome.overlay.toggle() }
                    if canLogcat {
                        tool(t("日志", "Logcat", language), WbIcon.logcat,
                             enabled: linkState.isRunning, active: chrome.logcatOpen) { chrome.logcatOpen.toggle() }
                    }
                    tool("画面原始像素大小", WbIcon.pixelPerfect,
                         enabled: linkState.isRunning, active: chrome.pixelPerfect) { chrome.pixelPerfectAction?() }
                    tool(chrome.fullscreen ? t("退出全屏", "Exit fullscreen", language) : "全屏",
                         iconForFullscreen, enabled: true, active: chrome.fullscreen) { chrome.toggleFullscreenAction?() }
                }
            }
            .padding(.top, WbSpace.sm + 2)
            .padding(.bottom, WbSpace.sm)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(width: sidebarWidth)
        .background(PlayerChromePalette.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PlayerChromePalette.hairline)
                .frame(width: PlayerChromeMetrics.hairline)
                .allowsHitTesting(false)
        }
    }

    private func sidebarGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: PlayerChromeMetrics.toolSpacing) { content() }
    }

    private var iconForFullscreen: String {
        chrome.fullscreen ? WbIcon.exitFullscreen : WbIcon.enterFullscreen
    }

    private var sidebarSeparator: some View {
        Rectangle()
            .fill(PlayerChromePalette.hairline)
            .frame(width: PlayerChromeMetrics.groupSeparatorWidth,
                   height: PlayerChromeMetrics.hairline)
            .padding(.vertical, PlayerChromeMetrics.toolSpacing)
    }

    // MARK: Panels

    private var mappingBar: some View {
        VStack {
            HStack(spacing: WbSpace.sm) {
                Text(mapping.pending ? "按键绑定中…" : "点击画面添加键位").wbFont(WbType.caption)
                Button("清空") { mapping.clear() }
                Button("取消") { mapping.cancel() }
                Button("保存") {
                    do {
                        try mapping.save()
                        transport.onStatus?("键位方案已保存")
                    } catch {
                        transport.onStatus?(error.localizedDescription)
                    }
                }
            }
            .padding(WbSpace.sm)
            .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.md))
            Spacer()
        }
        .padding(WbSpace.sm)
        .padding(.trailing, sidebar.visible && !chrome.fullscreen ? sidebarWidth : 0)
    }

    private var shortcutsPanel: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: WbSpace.sm) {
                    Text(shortcuts.capture == nil
                         ? t("快捷键（点击编辑，Esc 取消）", "Shortcuts (click to edit, Esc cancels)", language)
                         : t("按下新的快捷键", "Press a new shortcut", language))
                        .wbFont(WbType.caption.weighted(.semibold))
                    ForEach(GameShortcutAction.allCases, id: \.rawValue) { action in
                        Button {
                            shortcutError = nil
                            if !shortcuts.beginCapture(action.rawValue) {
                                shortcutError = ShortcutFailure.describe(shortcuts.failure ?? .unreadable, language: language)
                            }
                        } label: {
                            HStack {
                                Text(GameShortcutsStore.actionLabel(action, language: language)).wbFont(WbType.caption)
                                Spacer()
                                Text(shortcuts.binding(for: action)?.display ?? "—")
                                    .wbFont(WbType.code)
                                    .foregroundStyle(WbColor.textSecondary)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let shortcutError {
                        Text(shortcutError).wbFont(WbType.caption).foregroundStyle(WbColor.negative)
                    }
                    if let failure = shortcuts.failure {
                        Text(ShortcutFailure.describe(failure, language: language)).wbFont(WbType.caption).foregroundStyle(WbColor.warning)
                    }
                }
                .padding(WbSpace.md)
                .frame(width: WbLayout.windowInspectorWidth)
                .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.md))
                Spacer()
            }
            .padding(WbSpace.sm)
            Spacer()
        }
    }

    @ViewBuilder private var logcatBar: some View {
        Button { chrome.logcatOpen = true } label: {
            HStack(spacing: 7) {
                Image(systemName: WbIcon.logcat)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PlayerChromePalette.text)
                Text("Logcat")
                    .wbFont(WbType.label.weighted(.semibold))
                    .foregroundStyle(PlayerChromePalette.text)
                if logStream.errorCount > 0 {
                    Text(logStream.errorCount == 1 ? t("1 个错误", "1 error", language)
                                                   : t("\(logStream.errorCount) 个错误", "\(logStream.errorCount) errors", language))
                        .wbFont(WbType.caption.weighted(.medium))
                        .foregroundStyle(PlayerChromePalette.negativeBadgeText)
                        .padding(.horizontal, WbSpace.sm)
                        .padding(.vertical, 1)
                        .background(PlayerChromePalette.negativeBadge, in: Capsule())
                }
                Text(logStream.lastError)
                    .wbFont(WbType.code)
                    .lineLimit(1)
                    .foregroundStyle(PlayerChromePalette.negative)
                Spacer(minLength: WbSpace.sm)
                Text("⌘L")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(PlayerChromePalette.textDim)
            }
            .padding(.horizontal, 12)
            .frame(height: PlayerChromeMetrics.logcatBarHeight)
            .background(PlayerChromePalette.logbar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(t("打开日志面板（⌘L）", "Open Logcat (⌘L)", language))
        .accessibilityLabel(t("打开日志面板", "Open Logcat", language))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PlayerChromePalette.hairline)
                .frame(height: PlayerChromeMetrics.hairline)
                .allowsHitTesting(false)
        }
    }

    private var logcatPanel: some View {
        VStack(spacing: WbSpace.zero) {
            HStack(spacing: WbSpace.sm) {
                Text("Logcat").wbFont(WbType.label.weighted(.semibold))
                Picker("", selection: $logLevel) {
                    ForEach(["V", "D", "I", "W", "E", "F"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 66)
                .tint(PlayerChromePalette.accent)
                TextField(t("过滤标签、PID 或文本", "Filter tag, PID or text", language), text: $logFilter)
                    .textFieldStyle(.plain)
                    .wbFont(WbType.caption)
                    .foregroundStyle(JidrColor.textPrimary.dark)
                    .padding(.horizontal, WbSpace.sm)
                    .frame(height: 22)
                    .background(JidrColor.surfaceControl.dark,
                                in: RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous)
                            .strokeBorder(PlayerChromePalette.hairline, lineWidth: 1)
                    )
                Spacer()
                if let error = logStream.error, !error.isEmpty {
                    Text(PlayerStatusText.translate(error, language: language))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.warning).lineLimit(1)
                }
                Button { logStream.clear() } label: {
                    Image(systemName: WbIcon.trash).foregroundStyle(PlayerChromePalette.text)
                }
                .buttonStyle(.borderless)
                .help(t("清空日志", "Clear log", language))
                .accessibilityLabel(t("清空日志", "Clear log", language))
                Button { chrome.logcatOpen = false } label: {
                    Image(systemName: WbIcon.close).foregroundStyle(PlayerChromePalette.text)
                }
                .buttonStyle(.borderless)
                .help(t("关闭日志面板", "Close Logcat", language))
                .accessibilityLabel(t("关闭日志面板", "Close Logcat", language))
            }
            .padding(.horizontal, WbSpace.sm).frame(height: PlayerChromeMetrics.logcatBarHeight)
            .background(PlayerChromePalette.ground)
            Rectangle().fill(PlayerChromePalette.hairline).frame(height: PlayerChromeMetrics.hairline)
            ScrollViewReader { reader in
                ScrollView {
                    Text(logStream.text)
                        .wbFont(WbType.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(WbSpace.sm)
                    Color.clear.frame(height: 1).id("log-end")
                }
                .background(PlayerChromePalette.logbar)
                .onChange(of: logStream.revision) { _, _ in
                    reader.scrollTo("log-end", anchor: .bottom)
                }
            }
            Rectangle().fill(PlayerChromePalette.hairline).frame(height: PlayerChromeMetrics.hairline)
            Text(logStream.active
                 ? t("跟随中", "Following", language) + " · \(transport.device ?? "")"
                 : t("未连接", "Not connected", language))
                .wbFont(WbType.caption).foregroundStyle(PlayerChromePalette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WbSpace.sm).frame(height: 22)
                .background(PlayerChromePalette.ground)
        }
        .frame(height: 232)
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: WbSpace.md) {
            Text(t("卸载应用", "Uninstall app", language)).wbFont(WbType.title)
            Text(t("可通过应用包名卸载设备中的应用。卸载会删除该应用的应用数据，无法撤销。",
                   "Uninstall an app from the device by package name. Uninstalling deletes the app's data and cannot be undone.",
                   language))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(t("应用包名，例如 com.example.game", "Package name, e.g. com.example.game", language),
                      text: $uninstallPackage)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(t("取消", "Cancel", language)) { showUninstall = false }
                    .keyboardShortcut(.cancelAction)
                Button(t("卸载", "Uninstall", language), role: .destructive) {
                    chrome.uninstallAction?(uninstallPackage)
                    showUninstall = false
                    uninstallPackage = ""
                }
                .disabled(uninstallPackage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WbSpace.xl)
        .frame(width: 420)
    }

    // MARK: Handlers

    private func installHandlers() {
        transport.onStatus = { message in
            noticeGeneration += 1
            let generation = noticeGeneration
            guard !message.isEmpty else { notice = nil; return }
            notice = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if generation == noticeGeneration { notice = nil }
            }
        }
    }

    private func updateLogStream(open: Bool) {
        guard open, linkState.isRunning, let executable = transport.logcatExecutable, let device = transport.device else {
            logStream.stop()
            return
        }
        if !logStream.active {
            logStream.start(executable: executable, device: device,
                            filters: LogFilter.arguments(logFilter, level: logLevel))
        }
    }

    private func restartLogStream() {
        guard chrome.logcatOpen, canLogcat else { return }
        logStream.stop()
        updateLogStream(open: true)
    }
}

private let sidebarWidth = WbLayout.windowDeviceToolbarWidth
