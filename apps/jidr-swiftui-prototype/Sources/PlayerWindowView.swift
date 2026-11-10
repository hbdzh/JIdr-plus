// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

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
            HStack(spacing: 0) {
                VStack(spacing: 0) {
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
                        .background(Color(red: 0.07, green: 0.08, blue: 0.1))
                        .shadow(color: .black.opacity(0.6), radius: 12, x: -4)
                        .onHover { inside in
                            if inside { chrome.cancelHide() } else { chrome.hideRevealSoon() }
                        }
                        .transition(.move(edge: .trailing))
                }
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
        VStack(spacing: 10) {
            switch linkState {
            case .running:
                EmptyView()
            case .connecting:
                ProgressView().controlSize(.small)
                Text(t("正在连接设备…", "Connecting to the device…", language)).font(.callout)
            case .booting(let progress, let message):
                if let progress {
                    ProgressView(value: progress).frame(width: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(t("正在启动设备…", "Starting the device…", language)).font(.callout)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Text(t("设备启动后画面会自动出现。", "The screen appears once the device has started.", language))
                    .font(.caption2).foregroundStyle(.secondary)
            case .stopped(let reason):
                Image(systemName: "power").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(t("设备已停止", "The device is stopped", language)).font(.headline)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if transport.onStartDevice != nil {
                        Button(t("启动设备", "Start device", language)) { transport.startDevice() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                        .disabled(!canReconnect)
                }
            case .disconnected(let reason):
                Image(systemName: "wifi.slash").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(t("连接已断开", "The connection was lost", language)).font(.headline)
                Text(PlayerDiagnosis.describe(reason, language: language))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(t("重新连接", "Reconnect", language)) { transport.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReconnect)
                if !canReconnect {
                    Text(reconnectBlocker).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(24)
    }

    private var reconnectBlocker: String {
        if mapping.editing { return t("请先保存或取消键位编辑。", "Save or cancel the key-mapping edit first", language) }
        if transport.recordingStateUnknown { return t("录屏状态未知，请先在设备中心确认。", "The recording state is unknown. Confirm it in the device center first.", language) }
        return t("请先停止录屏并等待保存完成。", "Stop recording and wait for it to finish saving first.", language)
    }

    @ViewBuilder private var mappingToggles: some View {
        if !mapping.editing && !mapping.scheme.bindings.isEmpty {
            VStack {
                HStack(spacing: 8) {
                    Button(mapping.enabled ? "停用键位" : "启用键位") { mapping.enabled.toggle() }
                    Button(mapping.hints ? "隐藏提示" : "显示提示") { mapping.hints.toggle() }
                    Spacer()
                }
                .font(.caption)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.top, 44)
                Spacer()
            }
            .allowsHitTesting(true)
        }
    }

    private var pixelChip: some View {
        VStack {
            HStack(spacing: 8) {
                Text(t("原始像素 · 1 设备像素 = 1 屏幕像素", "Pixel-perfect · 1 device pixel = 1 screen pixel", language))
                    .font(.system(size: 12))
                Text("\(transport.frameWidth)×\(transport.frameHeight)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button(t("适应", "Fit", language)) { transport.onFitScreen?() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dropOverlay(_ drop: PlayerDrop.Label) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(drop.title).font(.system(size: 13, weight: .semibold))
                Text(drop.body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 290, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func noticeBubble(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(PlayerStatusText.translate(text, language: language))
                .font(.callout)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var recordingPill: some View {
        if transport.recording != .idle {
            VStack {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        Text(recordingText)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                Spacer()
            }
            .padding(12)
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.49, green: 0.99, blue: 0))
                    .padding(6)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(8)
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
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: sidebarWidth, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(PlayerStatusText.translate(title, language: language))
        .accessibilityLabel(PlayerStatusText.translate(title, language: language))
    }

    private var sidebarColumn: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                tool("返回", "arrow.left", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "back"]) }
                tool("主页", "circle", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "home"]) }
                tool("最近使用", "square", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "recents"]) }
                separator
                tool("电源", "power", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "power"]) }
                if transport.onAdvanced != nil {
                    tool(t("高级工具", "Advanced tools", language), "slider.horizontal.3") { chrome.advancedAction?() }
                }
                tool("音量增大", "speaker.wave.2", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "volume_up"]) }
                tool("音量减小", "speaker.wave.1", enabled: linkState.isRunning) { transport.send(["type": "tool_key", "key": "volume_down"]) }
                tool("向左旋转", "rotate.left", enabled: linkState.isRunning) { transport.send(["type": "rotate", "direction": 1]) }
                tool("向右旋转", "rotate.right", enabled: linkState.isRunning) { transport.send(["type": "rotate", "direction": -1]) }
                separator
                tool("键位映射", "keyboard", enabled: linkState.isRunning) {
                    if !mapping.editing {
                        if !mapping.begin() { transport.onStatus?(mapping.error ?? t("键位方案尚未加载", "The key mapping has not loaded", language)) }
                    }
                }
                tool(t("快捷键", "Shortcuts", language), "command") { chrome.shortcutsPanel.toggle() }
                tool(transport.recording == .idle || transport.recording == .starting ? "开始录屏" : "停止录屏",
                     transport.recording == .idle || transport.recording == .starting ? "record.circle" : "stop.circle",
                     enabled: linkState.isRunning) { chrome.toggleRecordingAction?() }
                tool("截图", "camera", enabled: linkState.isRunning) { chrome.chooseScreenshotAction?() }
                tool("安装 APK", "square.and.arrow.down", enabled: linkState.isRunning) { chrome.chooseAPKAction?() }
                tool("发送文件", "folder", enabled: linkState.isRunning) { chrome.chooseFileAction?() }
                separator
                tool(t("调试浮层", "Debug overlay", language), "gauge", enabled: linkState.isRunning) { chrome.overlay.toggle() }
                if canLogcat {
                    tool(t("日志", "Logcat", language), "text.alignleft", enabled: linkState.isRunning) { chrome.logcatOpen.toggle() }
                }
                tool(t("卸载应用", "Uninstall app", language), "trash", enabled: linkState.isRunning) { showUninstall = true }
                tool("画面原始像素大小", "1.magnifyingglass", enabled: linkState.isRunning) { chrome.pixelPerfectAction?() }
                tool(chrome.fullscreen ? t("退出全屏", "Exit fullscreen", language) : "全屏",
                     iconForFullscreen, enabled: true) { chrome.toggleFullscreenAction?() }
            }
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(Color(red: 0.65, green: 0.69, blue: 0.75))
        .frame(width: sidebarWidth)
        .background(Color(red: 0.07, green: 0.08, blue: 0.1))
    }

    private var iconForFullscreen: String {
        chrome.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    private var separator: some View {
        Divider().opacity(0.3).padding(.horizontal, 10).padding(.vertical, 3)
    }

    // MARK: Panels

    private var mappingBar: some View {
        VStack {
            HStack(spacing: 8) {
                Text(mapping.pending ? "按键绑定中…" : "点击画面添加键位").font(.caption)
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
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            Spacer()
        }
        .padding(8)
        .padding(.trailing, sidebar.visible && !chrome.fullscreen ? sidebarWidth : 0)
    }

    private var shortcutsPanel: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shortcuts.capture == nil
                         ? t("快捷键（点击编辑，Esc 取消）", "Shortcuts (click to edit, Esc cancels)", language)
                         : t("按下新的快捷键", "Press a new shortcut", language))
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(GameShortcutAction.allCases, id: \.rawValue) { action in
                        Button {
                            shortcutError = nil
                            if !shortcuts.beginCapture(action.rawValue) {
                                shortcutError = ShortcutFailure.describe(shortcuts.failure ?? .unreadable, language: language)
                            }
                        } label: {
                            HStack {
                                Text(GameShortcutsStore.actionLabel(action, language: language)).font(.caption)
                                Spacer()
                                Text(shortcuts.binding(for: action)?.display ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let shortcutError {
                        Text(shortcutError).font(.caption2).foregroundStyle(.red)
                    }
                    if let failure = shortcuts.failure {
                        Text(ShortcutFailure.describe(failure, language: language)).font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .frame(width: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(8)
            Spacer()
        }
    }

    @ViewBuilder private var logcatBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft").font(.system(size: 12))
            Text("Logcat").font(.system(size: 12, weight: .semibold))
            if logStream.errorCount > 0 {
                Text(logStream.errorCount == 1 ? t("1 个错误", "1 error", language)
                                               : t("\(logStream.errorCount) 个错误", "\(logStream.errorCount) errors", language))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.25), in: Capsule())
            }
            Text(logStream.lastError).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).foregroundStyle(Color(red: 0.9, green: 0.45, blue: 0.45))
            Spacer()
            Text("⌘L").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(red: 0.07, green: 0.08, blue: 0.1))
        .contentShape(Rectangle())
        .onTapGesture { chrome.logcatOpen = true }
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var logcatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Logcat").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $logLevel) {
                    ForEach(["V", "D", "I", "W", "E", "F"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 66)
                TextField(t("过滤标签、PID 或文本", "Filter tag, PID or text", language), text: $logFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Spacer()
                if let error = logStream.error, !error.isEmpty {
                    Text(PlayerStatusText.translate(error, language: language))
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
                Button { logStream.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                Button { chrome.logcatOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(Color(red: 0.09, green: 0.1, blue: 0.12))
            Divider().opacity(0.4)
            ScrollViewReader { reader in
                ScrollView {
                    Text(logStream.text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("log-end")
                }
                .background(Color(red: 0.045, green: 0.05, blue: 0.06))
                .onChange(of: logStream.revision) { _, _ in
                    reader.scrollTo("log-end", anchor: .bottom)
                }
            }
            Divider().opacity(0.4)
            Text(logStream.active
                 ? t("跟随中", "Following", language) + " · \(transport.device ?? "")"
                 : t("未连接", "Not connected", language))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 22)
        }
        .frame(height: 232)
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("卸载应用", "Uninstall app", language)).font(.headline)
            Text(t("可通过应用包名卸载设备中的应用。卸载会删除该应用的应用数据，无法撤销。",
                   "Uninstall an app from the device by package name. Uninstalling deletes the app's data and cannot be undone.",
                   language))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(t("应用包名，例如 com.example.game", "Package name, e.g. com.example.game", language),
                      text: $uninstallPackage)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(t("取消", "Cancel", language)) { showUninstall = false }
                Button(t("卸载", "Uninstall", language), role: .destructive) {
                    chrome.uninstallAction?(uninstallPackage)
                    showUninstall = false
                    uninstallPackage = ""
                }
                .disabled(uninstallPackage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
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

private let sidebarWidth: CGFloat = 48
