// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Player chrome
//
// One continuous native backdrop covers the titlebar and the rail. Keeping the
// hosting view transparent avoids stacking two independently tinted materials.
final class PlayerWindowBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        setAccessibilityIdentifier("player-chrome-material")
    }
}

/// Fullscreen's revealed rail blends the device content beneath it. Normal
/// windows expose the single AppKit backdrop owned by GameWindowController.
struct PlayerChromeMaterial: NSViewRepresentable {
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> PlayerWindowBackgroundView {
        let view = PlayerWindowBackgroundView()
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ view: PlayerWindowBackgroundView, context: Context) {
        view.blendingMode = blendingMode
    }
}

// Token colours remain dynamic so symbols and separators follow the appearance.
private enum PlayerChromePalette {
    static let hairline = Color(nsColor: .separatorColor)
    static let icon = MikoColor.textSecondary.color
    static let negative = MikoColor.negative.color
    static let accent = MikoColor.accentFill.color
    static let accentIcon = MikoColor.accentText.color
}

private enum PlayerChromeMetrics {
    /// 40 pt toolbar (WbLayout.windowDeviceToolbarWidth), compact icon targets.
    static let toolButton: CGFloat = 28 * 1.05
    static let toolGlyph: CGFloat = 13 * 1.05
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
    @Published var pinned = false
    @Published var corruptedMappingPrompt = false
    @Published var confirmCancelMapping = false
    @Published var mappingPanelMounted = false
    @Published var mappingPanelWidth: CGFloat = 0

    let scripts = PlayerScriptsCoordinator()
    var togglePinAction: (() -> Void)?

    func beginMapping(transport: PlayerTransport) {
        let mapping = transport.mapping
        guard !mapping.editing else { return }
        if !mapping.begin() {
            if let failure = mapping.failure {
                if failure == .unreadable { corruptedMappingPrompt = true }
                transport.onStatus?(failure.localized(language: transport.language))
            } else {
                transport.onStatus?(t("键位方案尚未加载", "The key mapping has not loaded", transport.language))
            }
        }
    }

    func toggleMapping(transport: PlayerTransport) {
        let mapping = transport.mapping
        if mapping.editing {
            if mapping.hasUnsavedChanges {
                confirmCancelMapping = true
            } else {
                mapping.cancel()
            }
        } else {
            beginMapping(transport: transport)
        }
    }

    var pixelPerfectAction: (() -> Void)?
    var fitAction: (() -> Void)?
    var toggleSidebarAction: (() -> Void)?
    var chooseScreenshotAction: (() -> Void)?
    var toggleRecordingAction: (() -> Void)?
    var chooseAPKAction: (() -> Void)?
    var chooseFileAction: (() -> Void)?
    var scriptAction: ((PlayerScriptAction, @escaping (Bool) -> Void) -> Void)?

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
    private var inputEnabled: Bool {
        linkState.isRunning
            && !transport.stoppingDevice
            && transport.scriptPlayback == .idle
            && !(transport.syncRole == .follower && transport.syncFollowerLocked)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: WbSpace.zero) {
                screenArea
                if chrome.mappingPanelMounted && !chrome.fullscreen {
                    KeyMappingSidePanel(transport: transport, mapping: mapping, chrome: chrome)
                        .frame(width: chrome.mappingPanelWidth, alignment: .leading)
                        .opacity(min(1, max(0, chrome.mappingPanelWidth / mappingConfigPanelWidth)))
                        .clipped()
                }
                if !chrome.fullscreen && sidebar.visible {
                    sidebarColumn
                }
            }
            if chrome.fullscreen {
                if mapping.editing {
                    KeyMappingSidePanel(transport: transport, mapping: mapping, chrome: chrome, overlay: true)
                        .padding(.trailing, chrome.reveal ? sidebarWidth : 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
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
        .animation(.easeInOut(duration: 0.22), value: chrome.fullscreen ? mapping.editing : false)
        .tint(PlayerChromePalette.accent)
        .environment(\.locale, Locale(identifier: language == 0 ? "en" : "zh-Hans"))
        .onAppear(perform: installHandlers)
        .onChange(of: transport.linkState) { state in
            if !state.isRunning { chrome.scripts.close() }
        }
        .onDisappear {
            chrome.scripts.close()
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
        .alert(t("放弃未保存的键位修改？", "Discard unsaved key mapping changes?", language),
               isPresented: $chrome.confirmCancelMapping) {
            Button(t("继续编辑", "Keep Editing", language), role: .cancel) { }
            Button(t("放弃修改", "Discard", language), role: .destructive) { mapping.cancel() }
        } message: {
            Text(t("当前键位编辑尚未保存，取消将丢失这些修改。",
                   "Your key mapping edits have not been saved and will be lost.",
                   language))
        }
        .alert(t("键位方案无法读取", "Key Mapping File Unreadable", language),
               isPresented: $chrome.corruptedMappingPrompt) {
            Button(t("重置并继续编辑", "Reset & Edit", language)) {
                _ = mapping.resetCorruptedForEditing()
            }
            if let url = mapping.currentFileURL {
                Button(t("在访达中显示", "Reveal in Finder", language)) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(t("重新加载", "Reload", language)) {
                mapping.reloadCurrent()
                if mapping.failure == nil {
                    transport.onStatus?(t("键位方案已重新加载", "Key mapping reloaded", language))
                }
            }
            Button(t("取消", "Cancel", language), role: .cancel) { }
        } message: {
            Text(t("当前配置文件格式损坏或包含无效键位，已保留原文件未做覆盖。你可以重置为空方案继续编辑（保存时才写入文件），或在访达中检查原文件。",
                   "The key mapping file is corrupted or invalid. The original file was not overwritten. You can reset to an empty scheme to continue editing (written only on save), or inspect the file in Finder.",
                   language))
        }
    }

    // MARK: Screen + window state

    private var screenArea: some View {
        ZStack {
            PlayerView(transport: transport)
                .accessibilityLabel(t("设备画面", "Device screen", language))
                .accessibilityHint(t("用侧边栏按钮发送按键、截图或录屏。", "Use the sidebar buttons to send keys, take screenshots or record.", language))
            if transport.stoppingDevice || !linkState.isRunning {
                stateCard
            }
            if chrome.pixelPerfect {
                pixelChip
            }
            if mapping.editing {
                inCanvasSelectionOverlay
            }
            if let drop = transport.dropHover {
                dropOverlay(drop)
            }
            if let notice, !notice.isEmpty {
                noticeBubble(notice)
            }
            if chrome.overlay {
                debugOverlay
            }
            recordingPill
            if transport.syncRole != .off {
                syncStatusOverlay
            }
            if transport.syncLockedHintVisible {
                syncLockedHintOverlay
            }
        }
        .overlay(alignment: .top) {
            if scriptHUDActive {
                scriptHUD
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["MIKO_UI_PREVIEW"] == "1" {
                Text(t("界面预览 · 未连接真实模拟器", "UI preview · No real emulator connected", language))
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8).allowsHitTesting(false)
            }
        }
    }

    private var syncStatusOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(transport.syncRole == .leader ? WbColor.accent : WbColor.positive)
                        .frame(width: 6, height: 6)
                    Text(transport.syncRole == .leader
                         ? t("同步中 · 主控", "Syncing · Leader", language)
                         : t("同步中 · 跟随", "Syncing · Following", language))
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .modifier(PlayerCanvasGlassSurface(cornerRadius: 999))
            }
            .padding(.horizontal, 10)
            .padding(.top, scriptHUDActive ? PlayerScriptControlMetrics.height + 16 : 10)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var syncLockedHintOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text(t("由主控设备控制", "Controlled by the leader", language))
                    .font(.system(size: 12, weight: .medium))
                Button(t("接管为主控", "Take over", language)) {
                    transport.onSyncTakeOver?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .modifier(PlayerCanvasGlassSurface(cornerRadius: 999))
            .padding(.bottom, 16)
        }
    }

    private var stateCard: some View {
        VStack(spacing: WbSpace.md) {
            if transport.stoppingDevice {
                ProgressView().controlSize(.small)
                Text(t("正在停止设备…", "Stopping the device…", language)).wbFont(WbType.body)
                Text(t("正在等待模拟器退出，保存快速启动状态可能需要一些时间。",
                       "Waiting for the emulator to exit. Saving quick-boot state may take some time.", language))
                    .wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72)).multilineTextAlignment(.center)
            } else { switch linkState {
            case .running:
                EmptyView()
            case .connecting:
                ProgressView().controlSize(.small)
                Text(t("正在连接设备…", "Connecting to the device…", language)).wbFont(WbType.body)
            case .booting(let progress, let message):
                Text(t("正在启动设备…", "Starting the device…", language)).wbFont(WbType.title)
                if let progress {
                    ProgressView(value: progress).frame(maxWidth: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !message.isEmpty {
                    Text(message).wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72)).multilineTextAlignment(.center)
                }
                Text(t("设备启动后画面会自动出现。", "The screen appears once the device has started.", language))
                    .wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72))
            case .stopped(let reason):
                Image(systemName: WbIcon.power).font(.system(size: WbIconSize.iconLg)).foregroundStyle(Color.white.opacity(0.72))
                Text(t("设备已停止", "The device is stopped", language)).wbFont(WbType.title)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72)).multilineTextAlignment(.center)
                HStack(spacing: WbSpace.sm) {
                    if transport.onStartDevice != nil {
                        Button(t("启动设备", "Start device", language)) { transport.startDevice() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                        .disabled(!canReconnect)
                }
            case .disconnected(let reason):
                Image(systemName: WbIcon.disconnected).font(.system(size: WbIconSize.iconLg)).foregroundStyle(Color.white.opacity(0.72))
                Text(t("连接已断开", "The connection was lost", language)).wbFont(WbType.title)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72)).multilineTextAlignment(.center)
                Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReconnect)
                if !canReconnect {
                    Text(reconnectBlocker).wbFont(WbType.caption).foregroundStyle(Color.white.opacity(0.72))
                }
            } }
        }
        .padding(WbSpace.lg)
        .frame(maxWidth: WbLayout.windowDeviceWidgetPanelWidth)
        .modifier(PlayerCanvasGlassSurface(cornerRadius: WbRadius.lg))
        .padding(WbSpace.xl)
    }

    private var reconnectBlocker: String {
        if mapping.editing { return t("请先保存或取消键位编辑。", "Save or cancel the key-mapping edit first", language) }
        if transport.recordingStateUnknown { return t("录屏状态未知，请先在设备中心确认。", "The recording state is unknown. Confirm it in the device center first.", language) }
        return t("请先停止录屏并等待保存完成。", "Stop recording and wait for it to finish saving first.", language)
    }

    private func canvasImageRect(in size: CGSize) -> CGRect {
        let fw = CGFloat(transport.frameWidth), fh = CGFloat(transport.frameHeight)
        guard fw > 0, fh > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / fw, size.height / fh)
        let w = fw * scale, h = fh * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func anchoredCardPosition(anchor: CGPoint, anchorRadius: CGFloat, cardSize: CGSize, in bounds: CGSize) -> CGPoint {
        let margin: CGFloat = 10
        let gap: CGFloat = 10
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2
        let x = min(max(anchor.x, margin + halfW), max(margin + halfW, bounds.width - margin - halfW))
        let belowY = anchor.y + anchorRadius + gap + halfH
        let aboveY = anchor.y - anchorRadius - gap - halfH
        let y: CGFloat
        if belowY + halfH <= bounds.height - margin {
            y = belowY
        } else if aboveY - halfH >= margin {
            y = aboveY
        } else {
            y = min(max(belowY, margin + halfH), max(margin + halfH, bounds.height - margin - halfH))
        }
        return CGPoint(x: x, y: y)
    }

    private var inCanvasSelectionOverlay: some View {
        GeometryReader { geo in
            let rect = canvasImageRect(in: geo.size)
            let rotation = mapping.currentRotation
            if let pending = mapping.pendingPoint, pending.rotation == rotation {
                let anchor = CGPoint(x: rect.minX + rect.width * pending.x, y: rect.minY + rect.height * pending.y)
                let cardSize = CGSize(width: 176, height: 34)
                HStack(spacing: WbSpace.xs) {
                    Text(t("请按键盘绑定…", "Press a key…", language))
                        .wbFont(WbType.caption.weighted(.medium))
                    Button {
                        mapping.clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help(t("取消选点 (Esc)", "Cancel placement (Esc)", language))
                }
                .padding(.horizontal, WbSpace.sm)
                .frame(width: cardSize.width, height: cardSize.height)
                .modifier(PlayerCanvasGlassSurface(cornerRadius: 17))
                .position(anchoredCardPosition(anchor: anchor, anchorRadius: 17, cardSize: cardSize, in: geo.size))
            } else if let selected = mapping.selectedKey,
                      let binding = mapping.draft.bindings.first(where: { $0.key == selected && $0.rotation == rotation }) {
                let anchor = CGPoint(x: rect.minX + rect.width * binding.x, y: rect.minY + rect.height * binding.y)
                let cardSize = CGSize(width: 186, height: 36)
                HStack(spacing: WbSpace.sm) {
                    Text(MappingKey.displayLabel(selected))
                        .wbFont(WbType.label.weighted(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                    Text(t("按键重绑", "Press to rebind", language))
                        .wbFont(WbType.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 0)
                    Button {
                        let label = MappingKey.displayLabel(selected)
                        if mapping.remove(key: selected, rotation: rotation) {
                            transport.onStatus?(t("已删除键位 ", "Removed ", language) + label)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(WbColor.negative)
                    }
                    .buttonStyle(.plain)
                    .help(t("删除键位 (Delete)", "Delete binding (Delete)", language))
                }
                .padding(.horizontal, WbSpace.sm)
                .frame(width: cardSize.width, height: cardSize.height)
                .modifier(PlayerCanvasGlassSurface(cornerRadius: WbRadius.md))
                .position(anchoredCardPosition(anchor: anchor, anchorRadius: 17, cardSize: cardSize, in: geo.size))
            } else if let idx = mapping.selectedJoystickIndex,
                      mapping.draft.joysticks.indices.contains(idx),
                      mapping.draft.joysticks[idx].rotation == rotation {
                let joystick = mapping.draft.joysticks[idx]
                let anchor = CGPoint(x: rect.minX + rect.width * joystick.x, y: rect.minY + rect.height * joystick.y)
                let ringRadius = max(20, min(rect.width, rect.height) * joystick.radius)
                let cardSize = CGSize(width: 224, height: 68)
                VStack(spacing: 8) {
                    HStack(spacing: WbSpace.xs) {
                        Button {
                            let target: JoystickPreset = joystick.preset == .arrows ? .wasd : .arrows
                            if !mapping.setJoystickPreset(at: idx, preset: target) {
                                transport.onStatus?(t("目标按键已被其他键位占用", "Target keys are already bound", language))
                            }
                        } label: {
                            Text(joystick.preset == .arrows ? "↑↓←→" : "WASD")
                                .wbFont(WbType.caption.weighted(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(t("切换 WASD / 方向键", "Switch WASD / Arrow keys", language))
                        Spacer(minLength: 0)
                        Text("\(Int((joystick.radius * 100).rounded()))%")
                            .wbFont(WbType.code)
                            .foregroundStyle(.white.opacity(0.8))
                        Button {
                            if mapping.removeJoystick(at: idx) {
                                transport.onStatus?(t("已删除摇杆", "Removed joystick", language))
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(WbColor.negative)
                        }
                        .buttonStyle(.plain)
                        .help(t("删除摇杆 (Delete)", "Delete joystick (Delete)", language))
                    }
                    HStack(spacing: 8) {
                        Button {
                            _ = mapping.resizeJoystick(at: idx, radius: joystick.radius - 0.02)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(joystick.radius <= 0.055)
                        Slider(value: Binding(
                            get: { joystick.radius },
                            set: { _ = mapping.resizeJoystick(at: idx, radius: $0) }
                        ), in: 0.05...0.35)
                        .controlSize(.small)
                        Button {
                            _ = mapping.resizeJoystick(at: idx, radius: joystick.radius + 0.02)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(joystick.radius >= 0.345)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: cardSize.width, height: cardSize.height)
                .modifier(PlayerCanvasGlassSurface(cornerRadius: WbRadius.md))
                .position(anchoredCardPosition(anchor: anchor, anchorRadius: ringRadius, cardSize: cardSize, in: geo.size))
            }
        }
    }

    private var pixelChip: some View {
        VStack {
            HStack(spacing: WbSpace.sm) {
                Text(t("原始像素 · 1 设备像素 = 1 屏幕像素", "Pixel-perfect · 1 device pixel = 1 screen pixel", language))
                    .wbFont(WbType.label)
                Text("\(transport.frameWidth)×\(transport.frameHeight)")
                    .wbFont(WbType.code).foregroundStyle(Color.white.opacity(0.72))
                Button(t("适应", "Fit", language)) { transport.onFitScreen?() }.controlSize(.small)
            }
            .padding(.horizontal, WbSpace.md).padding(.vertical, WbSpace.sm)
            .modifier(PlayerCanvasGlassSurface(cornerRadius: 20))
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
                Text(drop.body).wbFont(WbType.label).foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(WbSpace.lg)
            .frame(width: 290, alignment: .leading)
            .modifier(PlayerCanvasGlassSurface(cornerRadius: WbRadius.lg))
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
                .modifier(PlayerCanvasGlassSurface(cornerRadius: WbRadius.md))
                .padding(WbSpace.sm)
        }
        .padding(.bottom, 0)
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
                .modifier(PlayerCanvasGlassSurface(cornerRadius: 20))
                Spacer()
            }
            .padding(WbSpace.md)
            .padding(.top, scriptHUDActive ? PlayerScriptControlMetrics.height + 8 : 0)
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

    private var scriptHUD: some View {
        HStack(spacing: WbSpace.sm) {
            Image(systemName: transport.scriptRecording != .idle ? "record.circle" : WbIcon.play)
                .foregroundStyle(transport.scriptRecording != .idle ? PlayerChromePalette.negative : PlayerChromePalette.accentIcon)
            scriptHUDText
            Spacer(minLength: 4)
            scriptHUDActions
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(PlayerGlassSurface(cornerRadius: 10))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(height: PlayerScriptControlMetrics.height)
        .accessibilityIdentifier("player-script-controls")
    }

    @ViewBuilder private var scriptHUDText: some View {
        if transport.scriptRecording != .idle {
            if transport.scriptRecording == .recording {
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text(PlayerScriptText.recordingState(transport.scriptRecording, language: language)
                         + " · " + PlayerScriptFormat.elapsed(elapsedScriptRecording)
                         + " · " + String(format: t("%d 个事件", "%d events", language), transport.scriptRecordedEvents))
                        .wbFont(WbType.label.weighted(.medium))
                        .monospacedDigit()
                }
            } else {
                Text(PlayerScriptText.recordingState(transport.scriptRecording, language: language)
                     + " · " + PlayerScriptFormat.elapsed(elapsedScriptRecording)
                     + " · " + String(format: t("%d 个事件", "%d events", language), transport.scriptRecordedEvents))
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
                    .buttonStyle(.borderless).disabled(transport.scriptRecordFinishing)
                    .help(t("继续录制", "Resume recording", language))
            } else {
                Button(t("暂停", "Pause", language)) { transport.scriptRecordPause() }
                    .buttonStyle(.borderless).disabled(transport.scriptRecordFinishing)
                    .help(t("暂停录制", "Pause recording", language))
            }
            Button(transport.scriptRecordFinishing ? t("保存中…", "Saving…", language) : t("停止", "Stop", language)) { stopRecordingFromHUD() }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(PlayerChromePalette.negative)
                .disabled(transport.scriptRecordFinishing)
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
                .buttonStyle(.bordered).controlSize(.small)
                .help(t("停止回放", "Stop playback", language))
        }
    }

    private var elapsedScriptRecording: TimeInterval {
        guard let started = transport.scriptRecordingStartedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    private func stopRecordingFromHUD() {
        transport.scriptRecordStop(name: PlayerScriptFormat.suggestedRecordingName(language: language))
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
        .padding(.bottom, 0)
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

    private var gamepadTitle: String {
        switch transport.gamepadState {
        case .connected: return t("断开游戏手柄", "Disconnect game controller", language)
        case .connecting: return t("正在连接游戏手柄…", "Connecting game controller…", language)
        case .disconnected: return t("连接游戏手柄", "Connect game controller", language)
        }
    }

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
                    tool("音量增大", WbIcon.volumeUp, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "volume_up"]) }
                    tool("音量减小", WbIcon.volumeDown, enabled: inputEnabled) { transport.send(["type": "tool_key", "key": "volume_down"]) }
                    tool("向左旋转", WbIcon.rotateLeft, enabled: inputEnabled) { transport.send(["type": "rotate", "direction": 1]) }
                    tool("向右旋转", WbIcon.rotateRight, enabled: inputEnabled) { transport.send(["type": "rotate", "direction": -1]) }
                }
                sidebarSeparator
                sidebarGroup {
                    tool(transport.recording == .idle || transport.recording == .starting ? "开始录屏" : "停止录屏",
                         transport.recording == .idle || transport.recording == .starting ? WbIcon.record : WbIcon.recordStop,
                         enabled: linkState.isRunning,
                         active: transport.recording != .idle,
                         activeTint: PlayerChromePalette.negative) { chrome.toggleRecordingAction?() }
                    tool("截图", WbIcon.camera, enabled: linkState.isRunning) { chrome.chooseScreenshotAction?() }
                    tool("安装 APK", WbIcon.installAPK, enabled: linkState.isRunning) { chrome.chooseAPKAction?() }
                    tool(t("发送文件", "Send file", language), WbIcon.folder, enabled: linkState.isRunning) { chrome.chooseFileAction?() }
                    tool(gamepadTitle,
                         transport.gamepadState == .connected ? "gamecontroller.fill" : "gamecontroller",
                         enabled: linkState.isRunning && transport.gamepadState != .connecting,
                         active: transport.gamepadState != .disconnected,
                         activeTint: transport.gamepadState == .connecting ? WbColor.warning : WbColor.accent) { transport.onToggleGamepad?() }
                }
                sidebarSeparator
                Menu {
                    Button {
                        chrome.togglePinAction?()
                    } label: {
                        Label(chrome.pinned ? t("取消窗口置顶", "Unpin window", language) : t("窗口置顶", "Pin window", language),
                              systemImage: chrome.pinned ? WbIcon.pinned : WbIcon.pin)
                    }
                    Divider()
                    Button {
                        chrome.overlay.toggle()
                    } label: {
                        Label(t("调试浮层", "Debug overlay", language), systemImage: chrome.overlay ? "checkmark" : WbIcon.performance)
                    }
                    .disabled(!linkState.isRunning)
                    Button {
                        chrome.pixelPerfectAction?()
                    } label: {
                        Label(t("画面原始像素大小", "Original pixel size", language), systemImage: chrome.pixelPerfect ? "checkmark" : WbIcon.pixelPerfect)
                    }
                    .disabled(!linkState.isRunning)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: PlayerChromeMetrics.toolGlyph, weight: .medium))
                        .foregroundStyle(PlayerChromePalette.icon)
                        .frame(width: PlayerChromeMetrics.toolButton, height: PlayerChromeMetrics.toolButton)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(PlayerChromePalette.icon)
                .fixedSize()
                .help(t("更多", "More", language))
                .accessibilityLabel(t("更多设备工具", "More device tools", language))
            }
            .padding(.top, WbSpace.sm + 2)
            .padding(.bottom, WbSpace.sm)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .frame(width: sidebarWidth)
        .background {
            if chrome.fullscreen {
                PlayerChromeMaterial(blendingMode: .withinWindow)
                    .allowsHitTesting(false)
            }
        }
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

    private var sidebarSeparator: some View {
        Rectangle()
            .fill(PlayerChromePalette.hairline)
            .frame(width: PlayerChromeMetrics.groupSeparatorWidth,
                   height: PlayerChromeMetrics.hairline)
            .padding(.vertical, PlayerChromeMetrics.toolSpacing)
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
private let mappingConfigPanelWidth: CGFloat = 288

private enum KeyMappingActions {
    static func profileTitle(_ mapping: KeyMappingStore, language: Int) -> String {
        mapping.activeProfileName ?? t("默认方案", "Default", language)
    }

    static func selectProfile(_ name: String?, mapping: KeyMappingStore, transport: PlayerTransport, language: Int) {
        if mapping.hasUnsavedChanges {
            transport.onStatus?(t("请先保存或取消当前键位修改", "Save or cancel your current changes first", language))
            return
        }
        _ = mapping.selectProfile(name)
    }

    static func createProfile(mapping: KeyMappingStore, transport: PlayerTransport, duplicate: Bool, language: Int) {
        if mapping.hasUnsavedChanges && !duplicate {
            transport.onStatus?(t("请先保存或取消当前键位修改", "Save or cancel your current changes first", language))
            return
        }
        let title = duplicate ? t("复制键位方案", "Duplicate Key Mapping", language) : t("新建键位方案", "New Key Mapping", language)
        let action = duplicate ? t("复制", "Duplicate", language) : t("创建", "Create", language)
        guard let name = KeyMappingPrompts.askProfileName(title: title, action: action, defaultValue: "", language: language) else { return }
        if mapping.createProfile(named: name, duplicateCurrent: duplicate) {
            if !duplicate { _ = mapping.begin() }
            transport.onStatus?(t("已切换到方案 ", "Switched to ", language) + name)
        } else {
            transport.onStatus?(t("方案名称无效或已存在", "Invalid or duplicate profile name", language))
        }
    }

    static func saveAsNewProfile(mapping: KeyMappingStore, transport: PlayerTransport, language: Int) {
        guard let name = KeyMappingPrompts.askProfileName(
            title: t("另存为新方案", "Save As New Profile", language),
            action: t("保存", "Save", language),
            defaultValue: "",
            language: language
        ) else { return }
        if mapping.saveAsProfile(named: name) {
            transport.onStatus?(t("已保存方案 ", "Saved profile ", language) + name)
        } else {
            transport.onStatus?(t("无法保存（名称无效、已存在或存在未绑定选点）", "Cannot save (invalid/duplicate name or pending point)", language))
        }
    }

    static func renameActiveProfile(mapping: KeyMappingStore, transport: PlayerTransport, current: String, language: Int) {
        guard let name = KeyMappingPrompts.askProfileName(
            title: t("重命名键位方案", "Rename Key Mapping", language),
            action: t("重命名", "Rename", language),
            defaultValue: current,
            language: language
        ) else { return }
        if mapping.renameProfile(from: current, to: name) {
            transport.onStatus?(t("已重命名为 ", "Renamed to ", language) + name)
        } else {
            transport.onStatus?(t("方案名称无效或已存在", "Invalid or duplicate profile name", language))
        }
    }

    static func deleteActiveProfile(mapping: KeyMappingStore, transport: PlayerTransport, current: String, language: Int) {
        guard KeyMappingPrompts.confirmDeleteProfile(name: current, language: language) else { return }
        if mapping.deleteProfile(named: current) {
            transport.onStatus?(t("已删除方案 ", "Deleted profile ", language) + current)
        }
    }

    static func importFromPanel(mapping: KeyMappingStore, transport: PlayerTransport, language: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try mapping.importScheme(from: url)
            transport.onStatus?(t("已导入方案，请检查并保存", "Profile imported; review and save", language))
        } catch {
            transport.onStatus?(KeyMappingFailure.describe(error, language: language))
        }
    }

    static func exportToPanel(mapping: KeyMappingStore, transport: PlayerTransport, language: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let baseName = mapping.activeProfileName ?? t("默认键位", "default-keymap", language)
        panel.nameFieldStringValue = "\(baseName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try mapping.exportData()
            try data.write(to: url, options: .atomic)
            transport.onStatus?(t("键位方案已导出", "Key mapping exported", language))
        } catch {
            transport.onStatus?(t("导出失败，请检查目标路径权限", "Export failed; check destination permissions", language))
        }
    }
}

private struct KeyMappingGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 8
    var selected = false
    var hovered = false
    var pressed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill: Color = if selected {
            PlayerChromePalette.accent.opacity(pressed ? 0.22 : (hovered ? 0.16 : 0.12))
        } else {
            Color.primary.opacity(pressed ? 0.10 : (hovered ? 0.065 : 0.035))
        }
        let border: Color = if selected {
            PlayerChromePalette.accent.opacity(0.55)
        } else {
            WbColor.borderDefault.opacity(hovered ? 1.0 : 0.8)
        }

        content
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(border, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

private struct KeyMappingGlassButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var selected = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(
                KeyMappingGlassSurface(
                    cornerRadius: cornerRadius,
                    selected: selected,
                    hovered: hovered,
                    pressed: configuration.isPressed
                )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

private enum KeyMappingMenuOption {
    case item(title: String, selected: Bool = false, destructive: Bool = false, action: () -> Void)
    case separator
}

private struct KeyMappingMenuTriggerOverlay: NSViewRepresentable {
    let options: () -> [KeyMappingMenuOption]

    func makeCoordinator() -> Coordinator {
        Coordinator(options: options)
    }

    func makeNSView(context: Context) -> FlippedButton {
        let button = FlippedButton()
        button.isBordered = false
        button.title = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        return button
    }

    func updateNSView(_ nsView: FlippedButton, context: Context) {
        context.coordinator.options = options
    }

    final class FlippedButton: NSButton {
        override var isFlipped: Bool { true }
    }

    final class Coordinator: NSObject {
        var options: () -> [KeyMappingMenuOption]
        private var handlers: [() -> Void] = []

        init(options: @escaping () -> [KeyMappingMenuOption]) {
            self.options = options
        }

        @objc func openMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            handlers.removeAll()
            for entry in options() {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case let .item(title, selected, destructive, action):
                    let idx = handlers.count
                    handlers.append(action)
                    let item = NSMenuItem(title: title, action: #selector(triggerItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = idx
                    item.state = selected ? .on : .off
                    if destructive {
                        item.attributedTitle = NSAttributedString(
                            string: title,
                            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemRed]
                        )
                    }
                    menu.addItem(item)
                }
            }
            menu.minimumWidth = sender.bounds.width
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc private func triggerItem(_ sender: NSMenuItem) {
            guard handlers.indices.contains(sender.tag) else { return }
            handlers[sender.tag]()
        }
    }
}

private struct KeyMappingGlassDropdown: View {
    let text: String
    var muted = false
    let options: () -> [KeyMappingMenuOption]
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12.5, weight: muted ? .regular : .medium))
                .foregroundStyle(muted ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(KeyMappingGlassSurface(cornerRadius: 7, hovered: hovered))
        .overlay {
            KeyMappingMenuTriggerOverlay(options: options)
        }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .onHover { hovered = $0 }
    }
}

private struct KeyMappingListRow<MenuContent: View>: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let selectAction: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: selectAction) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? PlayerChromePalette.accentIcon : .primary)
                    Spacer(minLength: 4)
                    Text(detail)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? PlayerChromePalette.accentIcon : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? PlayerChromePalette.accentIcon : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            selected
                ? PlayerChromePalette.accent.opacity(hovered ? 0.18 : 0.14)
                : (hovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}

private struct KeyMappingFooterButtonModifier: ViewModifier {
    var prominent = false

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            if #available(macOS 26.0, *) {
                content
                    .buttonStyle(.glassProminent)
                    .tint(Color(nsColor: .controlAccentColor))
                    .controlSize(.regular)
            } else {
                content.buttonStyle(.borderedProminent).controlSize(.regular)
            }
        } else {
            content.buttonStyle(KeyMappingGlassFooterButtonStyle())
        }
    }
}

private struct KeyMappingGlassFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WbColor.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .modifier(
                KeyMappingGlassSurface(
                    cornerRadius: 8,
                    hovered: hovered && isEnabled,
                    pressed: configuration.isPressed && isEnabled
                )
            )
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct KeyMappingSidePanel: View {
    @ObservedObject var transport: PlayerTransport
    @ObservedObject var mapping: KeyMappingStore
    @ObservedObject var chrome: PlayerChromeState
    var overlay = false
    @State private var appliedTemplate: MappingTemplate?

    private var language: Int { transport.language }
    private var rotation: Int { mapping.currentRotation }

    private func templateTitle(_ template: MappingTemplate) -> String {
        switch template {
        case .moba: return t("MOBA / 动作", "MOBA / Action", language)
        case .shooter: return t("射击 / 战术", "Shooter", language)
        case .arcade: return t("街机 / 横版", "Arcade", language)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    addSection
                    unifiedListSection
                    schemeSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            Rectangle()
                .fill(PlayerChromePalette.hairline)
                .frame(height: PlayerChromeMetrics.hairline)
            footer
        }
        .frame(width: mappingConfigPanelWidth)
        .background {
            if overlay {
                PlayerChromeMaterial(blendingMode: .withinWindow).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PlayerChromePalette.hairline)
                .frame(width: PlayerChromeMetrics.hairline)
                .allowsHitTesting(false)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.primary)
    }

    private func inspectorGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content()
            .background(Color.primary.opacity(0.04), in: shape)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(t("添加键位", "Add Control", language))
            HStack(spacing: 10) {
                toolButton(mode: .tap, icon: "hand.point.up.left", title: t("单点按键", "Tap Key", language))
                toolButton(mode: .joystick, icon: "dpad", title: t("方向摇杆", "Joystick", language))
            }
        }
    }

    private func toolButton(mode: MappingPlacementMode, icon: String, title: String) -> some View {
        let active = mapping.placementMode == mode
        return Button {
            mapping.placementMode = mode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? PlayerChromePalette.accentIcon : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(KeyMappingGlassButtonStyle(cornerRadius: 8, selected: active))
    }

    private var unifiedListSection: some View {
        let joysticks = mapping.draft.joysticks.enumerated().filter { $0.element.rotation == rotation }
        let bindings = mapping.draft.bindings.filter { $0.rotation == rotation }
        let total = joysticks.count + bindings.count
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel(t("已添加键位", "Added Controls", language) + " · \(total)")
            if total == 0 {
                inspectorGroup {
                    Text(t("点击左侧画面添加按键或摇杆。", "Click the screen to add a key or stick.", language))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                }
            } else {
                inspectorGroup {
                    VStack(spacing: 0) {
                        ForEach(Array(joysticks.enumerated()), id: \.element.offset) { pos, item in
                            let index = item.offset
                            let stick = item.element
                            KeyMappingListRow(
                                icon: "dpad",
                                title: t("方向摇杆", "Joystick", language),
                                detail: stick.preset == .arrows ? "↑↓←→" : "WASD",
                                selected: mapping.selectedJoystickIndex == index,
                                selectAction: { _ = mapping.selectJoystick(at: index) }
                            ) {
                                Button(stick.preset == .arrows ? t("切换为 WASD", "Switch to WASD", language) : t("切换为方向键", "Switch to Arrows", language)) {
                                    let target: JoystickPreset = stick.preset == .arrows ? .wasd : .arrows
                                    if !mapping.setJoystickPreset(at: index, preset: target) {
                                        transport.onStatus?(t("目标按键已被其他键位占用", "Target keys are already bound", language))
                                    }
                                }
                                Divider()
                                Button(t("删除此键位", "Delete", language), role: .destructive) {
                                    _ = mapping.removeJoystick(at: index)
                                }
                            }
                            if pos < joysticks.count - 1 || !bindings.isEmpty {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 0.5)
                                    .padding(.leading, 38)
                            }
                        }
                        ForEach(Array(bindings.enumerated()), id: \.element.key) { pos, binding in
                            KeyMappingListRow(
                                icon: "smallcircle.filled.circle",
                                title: t("单点按键", "Tap Key", language),
                                detail: MappingKey.displayLabel(binding.key),
                                selected: mapping.selectedKey == binding.key,
                                selectAction: { _ = mapping.select(key: binding.key, rotation: rotation) }
                            ) {
                                Button(t("删除此键位", "Delete", language), role: .destructive) {
                                    _ = mapping.remove(key: binding.key, rotation: rotation)
                                }
                            }
                            if pos < bindings.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 0.5)
                                    .padding(.leading, 38)
                            }
                        }
                    }
                }
            }
        }
    }

    private func profileMenuOptions() -> [KeyMappingMenuOption] {
        var items: [KeyMappingMenuOption] = [
            .item(title: t("默认方案", "Default", language), selected: mapping.activeProfileName == nil) {
                appliedTemplate = nil
                KeyMappingActions.selectProfile(nil, mapping: mapping, transport: transport, language: language)
            }
        ]
        for name in mapping.profiles {
            items.append(
                .item(title: name, selected: mapping.activeProfileName == name) {
                    appliedTemplate = nil
                    KeyMappingActions.selectProfile(name, mapping: mapping, transport: transport, language: language)
                }
            )
        }
        items.append(.separator)
        items.append(.item(title: t("新建方案…", "New Profile…", language)) {
            KeyMappingActions.createProfile(mapping: mapping, transport: transport, duplicate: false, language: language)
        })
        items.append(.item(title: t("复制当前方案…", "Duplicate Current…", language)) {
            KeyMappingActions.createProfile(mapping: mapping, transport: transport, duplicate: true, language: language)
        })
        if let active = mapping.activeProfileName {
            items.append(.item(title: t("重命名当前方案…", "Rename Current…", language)) {
                KeyMappingActions.renameActiveProfile(mapping: mapping, transport: transport, current: active, language: language)
            })
            items.append(.item(title: t("删除当前方案", "Delete Current", language), destructive: true) {
                KeyMappingActions.deleteActiveProfile(mapping: mapping, transport: transport, current: active, language: language)
            })
        }
        return items
    }

    private func templateMenuOptions() -> [KeyMappingMenuOption] {
        [
            .item(title: t("MOBA / 动作 (WASD + 技能)", "MOBA / Action (WASD + Skills)", language), selected: appliedTemplate == .moba) {
                mapping.applyTemplate(.moba, rotation: rotation)
                appliedTemplate = .moba
            },
            .item(title: t("射击 / 战术 (WASD + 空格/R/F)", "Shooter (WASD + Space/R/F)", language), selected: appliedTemplate == .shooter) {
                mapping.applyTemplate(.shooter, rotation: rotation)
                appliedTemplate = .shooter
            },
            .item(title: t("街机 / 横版 (方向键 + Z/X/空格)", "Arcade (Arrows + Z/X/Space)", language), selected: appliedTemplate == .arcade) {
                mapping.applyTemplate(.arcade, rotation: rotation)
                appliedTemplate = .arcade
            },
        ]
    }

    private var schemeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(t("方案管理", "Profiles", language))
            inspectorGroup {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Text(t("当前方案", "Active Profile", language))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            KeyMappingGlassDropdown(
                                text: KeyMappingActions.profileTitle(mapping, language: language),
                                options: profileMenuOptions
                            )
                            .frame(width: 158)
                        }

                        HStack(spacing: 10) {
                            Text(t("方案模板", "Template", language))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            KeyMappingGlassDropdown(
                                text: appliedTemplate.map { templateTitle($0) } ?? t("选择预设模板", "Choose Template", language),
                                muted: appliedTemplate == nil,
                                options: templateMenuOptions
                            )
                            .frame(width: 158)
                        }
                    }

                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)

                    HStack(spacing: 8) {
                        schemeActionTile(icon: "doc.on.doc", title: t("另存为", "Save As", language)) {
                            KeyMappingActions.saveAsNewProfile(mapping: mapping, transport: transport, language: language)
                        }
                        schemeActionTile(icon: "square.and.arrow.down", title: t("导入", "Import", language)) {
                            KeyMappingActions.importFromPanel(mapping: mapping, transport: transport, language: language)
                        }
                        schemeActionTile(icon: "square.and.arrow.up", title: t("导出", "Export", language)) {
                            KeyMappingActions.exportToPanel(mapping: mapping, transport: transport, language: language)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func schemeActionTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(KeyMappingGlassButtonStyle(cornerRadius: 8))
    }

    @ViewBuilder private var clearControl: some View {
        let hasCurrent = mapping.hasBindings(for: rotation)
        if mapping.hasOtherRotationBindings(for: rotation) {
            HStack(spacing: 4) {
                Text(t("清空", "Clear", language))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .modifier(KeyMappingGlassSurface(cornerRadius: 8))
            .overlay {
                KeyMappingMenuTriggerOverlay {
                    var items: [KeyMappingMenuOption] = []
                    if hasCurrent {
                        items.append(.item(title: t("清空当前方向", "Clear current orientation", language)) {
                            mapping.clear(rotation: rotation)
                            appliedTemplate = nil
                        })
                    }
                    items.append(.item(title: t("清空全部方向", "Clear all orientations", language), destructive: true) {
                        mapping.clear()
                        appliedTemplate = nil
                    })
                    return items
                }
            }
        } else {
            Button(t("清空", "Clear", language)) {
                mapping.clear(rotation: rotation)
                appliedTemplate = nil
            }
            .modifier(KeyMappingFooterButtonModifier())
            .disabled(!hasCurrent)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            clearControl
            Spacer(minLength: 0)
            Button(t("取消", "Cancel", language)) {
                if mapping.hasUnsavedChanges {
                    chrome.confirmCancelMapping = true
                } else {
                    mapping.cancel()
                }
            }
            .modifier(KeyMappingFooterButtonModifier())
            Button(t("保存", "Save", language)) {
                do {
                    try mapping.save()
                    transport.onStatus?(t("键位方案已保存", "Key mapping saved", language))
                } catch {
                    transport.onStatus?(KeyMappingFailure.describe(error, language: language))
                }
            }
            .modifier(KeyMappingFooterButtonModifier(prominent: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Player actions remain available independently of sidebar visibility.
struct PlayerTitlebarActions: View {
    @ObservedObject var transport: PlayerTransport
    @ObservedObject var mapping: KeyMappingStore
    @ObservedObject var chrome: PlayerChromeState

    private var language: Int { transport.language }

    private var mappingButtonTint: Color {
        if mapping.failure == .unreadable { return WbColor.warning }
        if mapping.editing || mapping.enabled { return PlayerChromePalette.accentIcon }
        return .secondary
    }

    private var mappingButtonHelp: String {
        if mapping.editing { return t("退出键位编辑", "Exit key mapping edit", language) }
        if mapping.enabled { return t("键位映射（已启用，⌥⌘K 切换）", "Key mapping (enabled, ⌥⌘K to toggle)", language) }
        return t("键位映射", "Key mapping", language)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { chrome.toggleMapping(transport: transport) } label: {
                Image(systemName: mapping.editing ? "keyboard.fill" : WbIcon.keyboard)
                    .frame(width: 36, height: 28)
                    .foregroundStyle(mappingButtonTint)
                    .background(
                        RoundedRectangle(cornerRadius: WbRadius.sm)
                            .fill(mapping.editing ? PlayerChromePalette.accent.opacity(0.16) : Color.clear)
                    )
            }
            .disabled(!transport.linkState.isRunning || transport.scriptPlayback != .idle)
            .help(mappingButtonHelp)
            .accessibilityLabel(t("键位映射", "Key mapping", language))
            .contextMenu {
                if mapping.failure == .unreadable {
                    Button(t("恢复损坏的键位文件…", "Recover Corrupted Key Map…", language)) {
                        chrome.corruptedMappingPrompt = true
                    }
                }
                if !mapping.scheme.isEmpty {
                    Button {
                        mapping.enabled.toggle()
                    } label: {
                        if mapping.enabled {
                            Label(t("停用键位 (⌥⌘K)", "Disable Key Mapping (⌥⌘K)", language), systemImage: "checkmark")
                        } else {
                            Text(t("启用键位 (⌥⌘K)", "Enable Key Mapping (⌥⌘K)", language))
                        }
                    }
                    Button {
                        mapping.hints.toggle()
                    } label: {
                        if mapping.hints {
                            Label(t("隐藏键位提示", "Hide Key Hints", language), systemImage: "checkmark")
                        } else {
                            Text(t("显示键位提示", "Show Key Hints", language))
                        }
                    }
                }
            }
            Button { chrome.scripts.present(transport: transport, perform: chrome.scriptAction) } label: {
                Image(systemName: "hand.tap").frame(width: 36, height: 28)
            }
            .disabled(!transport.linkState.isRunning)
            .help(t("操作录制", "Operation recordings", transport.language))
            .accessibilityLabel(t("操作录制", "Operation recordings", transport.language))
            Button { transport.onOpenSyncPanel?() } label: {
                Image(systemName: transport.syncRole != .off ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                    .frame(width: 36, height: 28)
                    .foregroundStyle(transport.syncRole != .off ? PlayerChromePalette.accentIcon : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: WbRadius.sm)
                            .fill(transport.syncRole != .off ? PlayerChromePalette.accent.opacity(0.16) : Color.clear)
                    )
            }
            .disabled(!transport.linkState.isRunning)
            .help(t("同步器", "Synchronizer", language))
            .accessibilityLabel(t("同步器", "Synchronizer", language))
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private enum KeyMappingPrompts {
    static func askProfileName(title: String, action: String, defaultValue: String, language: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = t("输入方案名称（1–40 个字符，不能包含 / \\ :）。",
                                  "Enter a profile name (1–40 characters, no / \\ :).", language)
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: t("取消", "Cancel", language))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return KeyMappingStore.sanitizedProfileName(field.stringValue)
    }

    static func confirmDeleteProfile(name: String, language: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("删除键位方案？", "Delete key mapping profile?", language)
        alert.informativeText = t("确定要删除方案“", "Delete profile \"", language) + name + t("”吗？此操作无法撤销。", "\"? This cannot be undone.", language)
        let delete = alert.addButton(withTitle: t("删除", "Delete", language))
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: t("取消", "Cancel", language))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension KeyMappingFailure {
    func localized(language: Int) -> String {
        switch self {
        case .unreadable:
            return t("键位方案无法读取，请检查原文件；未进行覆盖。",
                     "The key map could not be read. Check the original file; it was not overwritten.", language)
        case .bindingRequired:
            return t("请先为选中的位置绑定按键", "Bind a key to the selected position first", language)
        case .conflict:
            return t("键位方案已在其他位置修改，请取消编辑后重新打开。",
                     "The key map changed elsewhere. Cancel the edit and open it again.", language)
        case .invalidImportFile:
            return t("导入失败：所选键位方案文件格式无效", "Import failed: the selected key map file is invalid.", language)
        case .cannotEnterEdit:
            return t("当前无法进入键位编辑模式", "Cannot enter key-mapping edit mode right now.", language)
        }
    }

    static func describe(_ error: Error, language: Int) -> String {
        let nsError = error as NSError
        if nsError.domain == "MikoMapping", let failure = KeyMappingFailure(rawValue: nsError.code) {
            return failure.localized(language: language)
        }
        if error is DecodingError {
            return KeyMappingFailure.invalidImportFile.localized(language: language)
        }
        return error.localizedDescription
    }
}
