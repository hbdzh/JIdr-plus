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
    static let hairline = JidrColor.borderSubtle.dark
    /// The titlebar seam is one step stronger than the in-sidebar rules so the
    /// native titlebar visibly separates from the dark content.
    static let seam = JidrColor.borderDefault.dark
    static let icon = JidrColor.textSecondary.dark
    static let text = JidrColor.textSecondary.dark
    static let textDim = JidrColor.textTertiary.dark
    static let negative = JidrColor.negative.dark
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
        .opacity(enabled ? 1 : 0.35)
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

    var pixelPerfectAction: (() -> Void)?
    var fitAction: (() -> Void)?
    var toggleFullscreenAction: (() -> Void)?
    var toggleSidebarAction: (() -> Void)?
    var chooseScreenshotAction: (() -> Void)?
    var toggleRecordingAction: (() -> Void)?
    var chooseAPKAction: (() -> Void)?
    var chooseFileAction: (() -> Void)?
    var advancedAction: (() -> Void)?

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
    @StateObject private var scripts = PlayerScriptsCoordinator()
    @State private var notice: String?
    @State private var noticeGeneration = 0

    init(transport: PlayerTransport, mapping: KeyMappingStore, sidebar: SidebarState,
         chrome: PlayerChromeState = PlayerChromeState()) {
        _transport = ObservedObject(wrappedValue: transport)
        _mapping = ObservedObject(wrappedValue: mapping)
        _sidebar = ObservedObject(wrappedValue: sidebar)
        _chrome = ObservedObject(wrappedValue: chrome)
    }

    private var language: Int { transport.language }
    private var linkState: PlayerLinkState { transport.linkState }
    private var canReconnect: Bool {
        GameReconnectPolicy.permits(disconnected: linkState.canReconnect || transport.connectionEnded,
                                    editing: mapping.editing,
                                    recording: transport.recording != .idle,
                                    recordingUnknown: transport.recordingStateUnknown)
    }
    /// Ordinary player input is ignored by the bridge during playback, so the
    /// sidebar disables those entries until the script stops.
    private var inputEnabled: Bool { linkState.isRunning && transport.scriptPlayback == .idle }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: WbSpace.zero) {
                screenArea
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
        .onChange(of: transport.linkState) { state in
            if !state.isRunning { scripts.close() }
        }
        .onDisappear {
            scripts.close()
        }
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
            if chrome.overlay {
                debugOverlay
            }
            recordingPill
            scriptHUD
        }
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["JIDR_UI_PREVIEW"] == "1" {
                Text(t("界面预览 · 未连接真实模拟器", "UI preview · No real emulator connected", language))
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8).allowsHitTesting(false)
            }
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
        .padding(.bottom, scriptHUDActive ? 34 : 0)
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

    // MARK: Operation-recording HUD

    private var scriptHUDActive: Bool {
        transport.scriptRecording != .idle || transport.scriptPlayback != .idle
    }

    @ViewBuilder private var scriptHUD: some View {
        if scriptHUDActive {
            VStack {
                Spacer()
                HStack(spacing: WbSpace.sm) {
                    Image(systemName: transport.scriptRecording != .idle ? "record.circle" : WbIcon.play)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(transport.scriptRecording != .idle
                                         ? PlayerChromePalette.negative
                                         : PlayerChromePalette.accentIcon)
                    scriptHUDText
                    scriptHUDActions
                }
                .padding(.horizontal, WbSpace.md)
                .padding(.vertical, WbSpace.xs)
                .background(WbColor.overlay, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(PlayerChromePalette.hairline,
                                           lineWidth: PlayerChromeMetrics.hairline)
                )
            }
            .padding(.bottom, WbSpace.sm)
            .padding(.horizontal, WbSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder private var scriptHUDText: some View {
        if transport.scriptRecording != .idle {
            if transport.scriptRecording == .recording {
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text(PlayerScriptText.recordingState(transport.scriptRecording, language: language)
                         + " · " + PlayerScriptFormat.elapsed(elapsedScriptRecording))
                        .wbFont(WbType.label.weighted(.medium))
                        .monospacedDigit()
                }
            } else {
                Text(PlayerScriptText.recordingState(transport.scriptRecording, language: language))
                    .wbFont(WbType.label.weighted(.medium))
            }
        } else {
            Text(PlayerScriptText.playbackState(transport.scriptPlayback, language: language)
                 + " · " + PlayerScriptText.loop(loop: transport.scriptPlaybackLoop,
                                                 total: transport.scriptPlaybackTotal,
                                                 mode: transport.scriptPlaybackMode,
                                                 language: language))
                .wbFont(WbType.label.weighted(.medium))
                .monospacedDigit()
        }
    }

    @ViewBuilder private var scriptHUDActions: some View {
        if transport.scriptRecording != .idle {
            if transport.scriptRecording == .paused {
                Button(t("继续", "Resume", language)) { transport.scriptRecordResume() }
                    .buttonStyle(.borderless)
                    .help(t("继续录制", "Resume recording", language))
            } else {
                Button(t("暂停", "Pause", language)) { transport.scriptRecordPause() }
                    .buttonStyle(.borderless)
                    .help(t("暂停录制", "Pause recording", language))
            }
            Button(t("停止", "Stop", language)) { stopRecordingFromHUD() }
                .buttonStyle(.borderless)
                .help(t("停止并保存录制", "Stop and save the recording", language))
        } else {
            if transport.scriptPlayback == .paused {
                Button(t("继续", "Resume", language)) { transport.scriptPlayResume() }
                    .buttonStyle(.borderless)
                    .help(t("继续回放", "Resume playback", language))
            } else {
                Button(t("暂停", "Pause", language)) { transport.scriptPlayPause() }
                    .buttonStyle(.borderless)
                    .help(t("暂停回放", "Pause playback", language))
            }
            Button(t("停止", "Stop", language)) { transport.scriptPlayStop() }
                .buttonStyle(.borderless)
                .help(t("停止回放", "Stop playback", language))
        }
    }

    private var elapsedScriptRecording: TimeInterval {
        guard let started = transport.scriptRecordingStartedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    private func stopRecordingFromHUD() {
        guard let name = PlayerScriptPrompts.askName(
            defaultValue: PlayerScriptFormat.suggestedRecordingName(language: language),
            language: language) else {
            transport.scriptRecordCancel()
            return
        }
        transport.scriptRecordStop(name: name)
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
        .padding(.bottom, scriptHUDActive ? 34 : 0)
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
                         label: PlayerStatusText.translate(title, language: language)
                            + (enabled ? "" : t("（设备连接后可用）", " (available after connecting)", language)),
                         enabled: enabled, active: active, activeTint: activeTint,
                         action: action)
    }

    private var sidebarColumn: some View {
        ScrollView(.vertical) {
            VStack(spacing: PlayerChromeMetrics.toolSpacing) {
                sidebarGroup {
                    tool("返回", WbIcon.back, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "back"]) }
                    tool("主页", WbIcon.circle, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "home"]) }
                    tool("最近使用", WbIcon.square, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "recents"]) }
                }
                sidebarSeparator
                sidebarGroup {
                    tool("电源", WbIcon.power, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "power"]) }
                    if transport.onAdvanced != nil {
                        tool(t("高级工具", "Advanced tools", language), WbIcon.advancedTools) { chrome.advancedAction?() }
                    }
                    tool("音量增大", WbIcon.volumeUp, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "volume_up"]) }
                    tool("音量减小", WbIcon.volumeDown, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "volume_down"]) }
                    tool("向左旋转", WbIcon.rotateLeft, enabled: inputEnabled) { transport.send(["type": "rotate", "direction": 1]) }
                    tool("向右旋转", WbIcon.rotateRight, enabled: inputEnabled) { transport.send(["type": "rotate", "direction": -1]) }
                }
                sidebarSeparator
                sidebarGroup {
                    tool("键位映射", WbIcon.keyboard, enabled: inputEnabled, active: mapping.editing) {
                        if !mapping.editing {
                            if !mapping.begin() { transport.onStatus?(mapping.error ?? t("键位方案尚未加载", "The key mapping has not loaded", language)) }
                        }
                    }
                    tool(transport.recording == .idle || transport.recording == .starting ? "开始录屏" : "停止录屏",
                         transport.recording == .idle || transport.recording == .starting ? WbIcon.record : WbIcon.recordStop,
                         enabled: linkState.isRunning,
                         active: transport.recording != .idle,
                         activeTint: PlayerChromePalette.negative) { chrome.toggleRecordingAction?() }
                    tool("截图", WbIcon.camera, enabled: linkState.isRunning) { chrome.chooseScreenshotAction?() }
                    tool("安装 APK", WbIcon.installAPK, enabled: linkState.isRunning) { chrome.chooseAPKAction?() }
                    tool("发送文件", WbIcon.folder, enabled: linkState.isRunning) { chrome.chooseFileAction?() }
                    tool(t("操作录制", "Operation recordings", language), "list.bullet.rectangle",
                         enabled: linkState.isRunning,
                         active: transport.scriptRecording != .idle || transport.scriptPlayback != .idle,
                         activeTint: transport.scriptRecording != .idle ? PlayerChromePalette.negative : nil) {
                        scripts.present(transport: transport)
                    }
                }
                sidebarSeparator
                sidebarGroup {
                    tool(t("调试浮层", "Debug overlay", language), WbIcon.performance,
                         enabled: linkState.isRunning, active: chrome.overlay) { chrome.overlay.toggle() }
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
        .scrollIndicators(.automatic)
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

}

private let sidebarWidth = WbLayout.windowDeviceToolbarWidth
