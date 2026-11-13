// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Script models (bridge JSON, docs/player-scripts.md)

/// One script in the player's list (`ScriptSummary` on the bridge side).
struct PlayerScriptSummary: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var duration_ms: Int
    var event_count: Int
    var created_at: String
    var display: PlayerScriptDisplay?

    var duration: TimeInterval { Double(max(0, duration_ms)) / 1000 }

    /// Decodes a summary object from the bridge's JSON notification.
    static func decode(_ value: Any?) -> PlayerScriptSummary? {
        guard let object = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(PlayerScriptSummary.self, from: data)
    }
}

struct PlayerScriptDisplay: Codable, Equatable {
    var width: Int
    var height: Int
}

/// Playback defaults for one run (`PlaybackOptions` on the bridge side).
/// `mode` is `count`, `duration` or `infinite`; irrelevant fields are sent as 0,
/// which is what the v1 contract defines.
enum PlaybackMode: String, Codable, CaseIterable {
    case count
    case duration
    case infinite
}

struct PlaybackOptions: Codable, Equatable {
    var mode: PlaybackMode = .count
    var count: Int = 1
    var duration_ms: Int = 0
    var interval_ms: Int = 0
    var speed: Double = 1

    var jsonObject: [String: Any] {
        ["mode": mode.rawValue,
         "count": max(0, count),
         "duration_ms": max(0, duration_ms),
         "interval_ms": max(0, interval_ms),
         "speed": speed]
    }
}

// MARK: - Formatting and copy

enum PlayerScriptFormat {
    static func duration(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        duration(Int(max(0, interval) * 1000))
    }

    static func eventCount(_ count: Int) -> String {
        String(format: "%d", count)
    }

    static func createdAt(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        let display = DateFormatter()
        display.dateStyle = .short
        display.timeStyle = .short
        return display.string(from: date)
    }

    static func resolution(_ display: PlayerScriptDisplay?, language: Int) -> String {
        guard let display, display.width > 0, display.height > 0 else {
            return PlayerScriptText.unknown(language: language)
        }
        return "\(display.width)×\(display.height)"
    }

    static func suggestedRecordingName(language: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return t("操作录制", "Operation recording", language) + " " + formatter.string(from: Date())
    }
}

/// Player-script copy in both languages; the bridge sends stable codes plus an
/// English fallback, so common codes get a bilingual label here.
enum PlayerScriptText {
    static func recordingState(_ state: PlayerTransport.ScriptRecordingState, language: Int) -> String {
        switch state {
        case .idle: return t("未在录制", "Not recording", language)
        case .recording: return t("正在录制操作", "Recording actions", language)
        case .paused: return t("录制已暂停", "Recording paused", language)
        }
    }

    static func playbackState(_ state: PlayerTransport.ScriptPlaybackState, language: Int) -> String {
        switch state {
        case .idle: return t("未在回放", "Not playing", language)
        case .playing: return t("正在回放操作", "Playing actions", language)
        case .paused: return t("回放已暂停", "Playback paused", language)
        }
    }

    static func loop(loop: Int, total: Int, mode: PlaybackMode, language: Int) -> String {
        if total > 0 {
            return String(format: t("第 %d/%d 轮", "Round %d/%d", language), max(1, loop), total)
        }
        if mode == .infinite {
            return t("无限循环", "Looping", language) + " · " + String(format: t("第 %d 轮", "Round %d", language), max(1, loop))
        }
        return String(format: t("第 %d 轮", "Round %d", language), max(1, loop))
    }

    static func mode(_ mode: PlaybackMode, language: Int) -> String {
        switch mode {
        case .count: return t("按次数", "By count", language)
        case .duration: return t("按时长", "By duration", language)
        case .infinite: return t("无限循环", "Loop forever", language)
        }
    }

    static func unknown(language: Int) -> String {
        t("未知", "Unknown", language)
    }

    /// Maps the bridge's error codes to bilingual copy; unknown messages pass
    /// through (they are already the daemon/bridge English fallback).
    static func error(code: String?, message: String?, language: Int) -> String {
        switch code {
        case "script.busy":
            return t("操作录制正忙，请先停止当前录制或回放。",
                     "An operation recording is busy. Stop the current recording or playback first.",
                     language)
        case "script.not_found", "not_found":
            return t("找不到该操作录制。", "The operation recording was not found.", language)
        case "script.recording":
            return t("正在录制，无法开始回放。", "Recording is in progress; playback cannot start.", language)
        case "script.playing":
            return t("正在回放，无法开始录制。", "Playback is in progress; recording cannot start.", language)
        case "script.invalid", "invalid_params", "usage":
            if let message, !message.isEmpty {
                return t("操作录制的数据无效：", "The operation recording is invalid: ", language) + message
            }
            return t("操作录制的数据无效。", "The operation recording is invalid.", language)
        case "script.io":
            if let message, !message.isEmpty {
                return t("无法读写操作录制文件：", "Could not access the operation recording file: ", language) + message
            }
            return t("无法读写操作录制文件。", "Could not access the operation recording file.", language)
        case "script.not_recording":
            return t("当前没有正在进行的操作录制。", "No operation recording is running.", language)
        case "script.not_playing":
            return t("当前没有正在回放的操作录制。", "No operation recording playback is running.", language)
        case "script.failed":
            if let message, !message.isEmpty { return message }
            return t("操作录制失败，请重试。", "The operation recording failed. Try again.", language)
        case "script.full":
            return t("操作录制数量或时长超出限制。", "The operation recording exceeds the supported limit.", language)
        default:
            if let message, !message.isEmpty { return message }
            return t("操作录制失败，请重试。", "The operation recording failed. Try again.", language)
        }
    }
}

// MARK: - Native prompts (NSAlert / NSSavePanel)

enum PlayerScriptPrompts {
    static func askName(defaultValue: String, language: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = t("保存操作录制", "Save operation recording", language)
        alert.informativeText = t("输入录制名称（1–80 个字符）。",
                                  "Enter a recording name (1–80 characters).", language)
        alert.addButton(withTitle: t("保存", "Save", language))
        alert.addButton(withTitle: t("取消", "Cancel", language))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return nil }
        return name
    }

    static func askRename(current: String, language: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = t("重命名操作录制", "Rename operation recording", language)
        alert.informativeText = t("输入新名称（1–80 个字符）。",
                                  "Enter a new name (1–80 characters).", language)
        alert.addButton(withTitle: t("重命名", "Rename", language))
        alert.addButton(withTitle: t("取消", "Cancel", language))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return nil }
        return name
    }

    static func confirmDelete(name: String, language: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = t("删除操作录制？", "Delete operation recording?", language)
        alert.informativeText = String(format: t("「%@」将被删除，无法撤销。",
                                                 "“%@” will be deleted. This cannot be undone.", language),
                                       name)
        alert.addButton(withTitle: t("删除", "Delete", language))
        alert.addButton(withTitle: t("取消", "Cancel", language))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Coordinator and window

/// Owns the non-modal operation-recording window for one player window.
final class PlayerScriptsCoordinator: ObservableObject {
    private var controller: PlayerScriptsWindowController?

    func present(transport: PlayerTransport) {
        if let controller {
            controller.show()
            return
        }
        let controller = PlayerScriptsWindowController(transport: transport)
        self.controller = controller
        controller.show()
    }

    func close() {
        controller?.close()
        controller = nil
    }
}

final class PlayerScriptsWindowController: NSWindowController, NSWindowDelegate {
    private let transport: PlayerTransport
    private var languageCancellable: AnyCancellable?

    init(transport: PlayerTransport) {
        self.transport = transport
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = t("操作录制", "Operation recordings", transport.language)
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: PlayerScriptsView(transport: transport))
        super.init(window: window)
        window.delegate = self
        window.center()
        languageCancellable = transport.$language.sink { [weak self] language in
            self?.window?.title = t("操作录制", "Operation recordings", language)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Script window view

struct PlayerScriptsView: View {
    @ObservedObject var transport: PlayerTransport

    @State private var selection: String?
    @State private var search = ""
    @State private var playbackMode: PlaybackMode = .count
    @State private var playbackCount = 1
    @State private var playbackSeconds = 60
    @State private var playbackIntervalMilliseconds = 0
    @State private var playbackSpeed: Double = 1

    private var language: Int { transport.language }

    private var filteredScripts: [PlayerScriptSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return transport.scripts }
        return transport.scripts.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    private var selectedScript: PlayerScriptSummary? {
        guard let selection else { return nil }
        return transport.scripts.first { $0.id == selection }
    }

    private var recordingBusy: Bool { transport.scriptRecording != .idle }
    private var playbackBusy: Bool { transport.scriptPlayback != .idle }
    /// Script commands are handled by the player bridge: without a live stream
    /// the window still shows the last list, but bridge actions stay disabled.
    private var bridgeAvailable: Bool { transport.linkState.isRunning }
    private var canStartRecording: Bool { !playbackBusy && transport.linkState.isRunning }
    private var canStartPlayback: Bool {
        selectedScript != nil && !recordingBusy && !playbackBusy && transport.linkState.isRunning
    }

    var body: some View {
        VStack(spacing: WbSpace.zero) {
            header
            Divider().overlay(WbColor.borderSubtle)
            if let error = transport.scriptError {
                errorBanner(error)
            }
            HSplitView {
                scriptListPane
                    .frame(minWidth: 250, idealWidth: 280, maxHeight: .infinity)
                detailPane
                    .frame(minWidth: 320, maxHeight: .infinity)
            }
        }
        .background(WbColor.surface)
        .onAppear {
            transport.scriptList()
            if selection == nil { selection = transport.scripts.first?.id }
        }
        .onChange(of: transport.scripts) { scripts in
            if let selection, scripts.contains(where: { $0.id == selection }) { return }
            self.selection = scripts.first?.id
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("操作录制", "Operation recordings", language))
                    .wbFont(WbType.headline)
                Text(t("录制玩家的触摸与按键，稍后按原样回放。",
                       "Record the player's touches and keys, then replay them.", language))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
            Spacer()
            Button(t("刷新", "Refresh", language)) { transport.scriptList() }
                .disabled(!bridgeAvailable)
                .help(t("刷新操作录制列表（⌘R）", "Refresh the recording list (⌘R)", language))
            Button(t("导入…", "Import…", language)) { importScript() }
                .disabled(!bridgeAvailable)
                .help(t("从 JSON 文件导入操作录制", "Import an operation recording from JSON", language))
        }
        .padding(.horizontal, WbSpace.lg)
        .padding(.vertical, WbSpace.md)
        .background(WbColor.chrome)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WbSpace.sm) {
            Image(systemName: WbIcon.warning)
                .foregroundStyle(WbColor.negative)
            Text(message)
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(t("关闭", "Dismiss", language)) { transport.clearScriptError() }
                .controlSize(.small)
        }
        .padding(.horizontal, WbSpace.lg)
        .padding(.vertical, WbSpace.sm)
    }

    // MARK: List

    private var scriptListPane: some View {
        VStack(spacing: WbSpace.zero) {
            NativeSearchField(text: $search,
                              placeholder: t("搜索操作录制", "Search recordings", language),
                              identifier: "recordings-search")
                .frame(height: 30)
                .padding(WbSpace.sm)

            if filteredScripts.isEmpty {
                emptyListState
            } else {
                List(selection: $selection) {
                    ForEach(filteredScripts) { script in
                        scriptRow(script)
                            .tag(script.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(WbColor.raised)
    }

    private var emptyListState: some View {
        VStack(spacing: WbSpace.sm) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: WbIconSize.iconLg))
                .foregroundStyle(WbColor.textTertiary)
            Text(transport.scripts.isEmpty
                 ? t("暂无操作录制", "No operation recordings yet", language)
                 : t("没有匹配的录制", "No matching recordings", language))
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textSecondary)
            if transport.scripts.isEmpty {
                Text(t("在右侧点击“开始录制”，然后操作设备。",
                       "Click “Start recording” on the right, then use the device.", language))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scriptRow(_ script: PlayerScriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(script.name)
                .wbFont(WbType.body.weighted(.medium))
                .lineLimit(1)
            HStack(spacing: WbSpace.xs) {
                Text(PlayerScriptFormat.duration(script.duration_ms))
                    .wbFont(WbType.code)
                    .foregroundStyle(WbColor.textSecondary)
                Text("·")
                    .foregroundStyle(WbColor.textTertiary)
                Text(String(format: t("%d 个事件", "%d events", language), script.event_count))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
            HStack(spacing: WbSpace.xs) {
                Text(PlayerScriptFormat.resolution(script.display, language: language))
                    .wbFont(WbType.caption)
                Text("·")
                Text(PlayerScriptFormat.createdAt(script.created_at))
                    .wbFont(WbType.caption)
            }
            .foregroundStyle(WbColor.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(script.name)
        .accessibilityValue(PlayerScriptFormat.duration(script.duration_ms))
    }

    // MARK: Detail

    private var detailPane: some View {
        Form {
            Section {
                recordingRows
            } header: {
                Text(t("录制", "Recording", language))
                    .wbFont(WbType.title)
            }
            Section {
                playbackRows
            } header: {
                Text(t("回放设置", "Playback settings", language))
                    .wbFont(WbType.title)
            }
            if let script = selectedScript {
                Section {
                    scriptRows(script)
                } header: {
                    Text(script.name)
                        .wbFont(WbType.title)
                        .lineLimit(1)
                }
            } else {
                Section {
                    emptyDetailRows
                } header: {
                    Text(t("脚本详情", "Script details", language))
                        .wbFont(WbType.title)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var recordingRows: some View {
        HStack(spacing: WbSpace.sm) {
            Image(systemName: "record.circle")
                .foregroundStyle(recordingBusy ? WbColor.negative : WbColor.textSecondary)
            Text(PlayerScriptText.recordingState(transport.scriptRecording, language: language))
                .wbFont(WbType.body.weighted(.medium))
            if transport.scriptRecording == .recording {
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text(PlayerScriptFormat.elapsed(elapsedRecording))
                        .wbFont(WbType.code)
                        .foregroundStyle(WbColor.textSecondary)
                }
            }
            Spacer()
        }
        HStack(spacing: WbSpace.sm) {
            switch transport.scriptRecording {
            case .idle:
                Button(t("开始录制", "Start recording", language)) { transport.scriptRecordStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartRecording)
            case .recording:
                Button(t("暂停", "Pause", language)) { transport.scriptRecordPause() }
                Button(t("停止并保存…", "Stop and save…", language)) { stopRecording() }
                Button(t("放弃", "Discard", language)) { transport.scriptRecordCancel() }
            case .paused:
                Button(t("继续", "Resume", language)) { transport.scriptRecordResume() }
                Button(t("停止并保存…", "Stop and save…", language)) { stopRecording() }
                Button(t("放弃", "Discard", language)) { transport.scriptRecordCancel() }
            }
            Spacer()
        }
        Text(t("录制触摸、按键、文本和工具栏按键；旋转不会录制。",
               "Touches, keys, text and toolbar keys are recorded; rotation is not.", language))
            .wbFont(WbType.caption)
            .foregroundStyle(WbColor.textTertiary)
        if playbackBusy {
            Text(t("回放期间无法录制。", "Recording is unavailable during playback.", language))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
    }

    @ViewBuilder private var playbackRows: some View {
        HStack(spacing: WbSpace.sm) {
            Text(t("模式", "Mode", language))
                .foregroundStyle(WbColor.textSecondary)
            Spacer()
            Picker("", selection: $playbackMode) {
                ForEach(PlaybackMode.allCases, id: \.self) { mode in
                    Text(PlayerScriptText.mode(mode, language: language)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
        if playbackMode == .count {
            HStack(spacing: WbSpace.sm) {
                Text(t("次数", "Loops", language))
                    .foregroundStyle(WbColor.textSecondary)
                Spacer()
                Stepper(value: $playbackCount, in: 1...1000) {
                    Text(String(format: "%d", playbackCount))
                        .wbFont(WbType.caption)
                        .monospacedDigit()
                }
                .labelsHidden()
                Text(String(format: t("%d 次", "%d loops", language), playbackCount))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
        }
        if playbackMode == .duration {
            HStack(spacing: WbSpace.sm) {
                Text(t("时长", "Duration", language))
                    .foregroundStyle(WbColor.textSecondary)
                Spacer()
                Stepper(value: $playbackSeconds, in: 1...86400) {
                    Text(String(format: "%d", playbackSeconds))
                        .wbFont(WbType.caption)
                        .monospacedDigit()
                }
                .labelsHidden()
                Text(String(format: t("%d 秒", "%d s", language), playbackSeconds))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
        }
        HStack(spacing: WbSpace.sm) {
            Text(t("循环间隔", "Loop interval", language))
                .foregroundStyle(WbColor.textSecondary)
            Spacer()
            TextField("", value: $playbackIntervalMilliseconds, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
            Text(t("毫秒", "ms", language))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
        HStack(spacing: WbSpace.sm) {
            Text(t("倍速", "Speed", language))
                .foregroundStyle(WbColor.textSecondary)
            Spacer()
            Picker("", selection: $playbackSpeed) {
                ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { speed in
                    Text(String(format: "%.2g×", speed)).tag(speed)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)
        }
        HStack(spacing: WbSpace.sm) {
            switch transport.scriptPlayback {
            case .idle:
                Button(t("回放", "Play", language)) { startPlayback() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartPlayback)
            case .playing:
                Button(t("暂停", "Pause", language)) { transport.scriptPlayPause() }
                Button(t("停止", "Stop", language)) { transport.scriptPlayStop() }
            case .paused:
                Button(t("继续", "Resume", language)) { transport.scriptPlayResume() }
                Button(t("停止", "Stop", language)) { transport.scriptPlayStop() }
            }
            Spacer()
            if playbackBusy {
                Text(PlayerScriptText.loop(loop: transport.scriptPlaybackLoop,
                                           total: transport.scriptPlaybackTotal,
                                           mode: transport.scriptPlaybackMode,
                                           language: language))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
        }
        if let name = transport.scriptPlaybackName, playbackBusy {
            Text(String(format: t("正在回放：%@", "Playing: %@", language), name))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textTertiary)
                .lineLimit(1)
        }
        if recordingBusy {
            Text(t("录制期间无法回放。", "Playback is unavailable while recording.", language))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
    }

    @ViewBuilder private func scriptRows(_ script: PlayerScriptSummary) -> some View {
        HStack(spacing: WbSpace.lg) {
            Label(PlayerScriptFormat.duration(script.duration_ms), systemImage: "clock")
                .foregroundStyle(WbColor.textSecondary)
            Label(String(format: t("%d 个事件", "%d events", language), script.event_count),
                  systemImage: "list.number")
                .foregroundStyle(WbColor.textSecondary)
            Label(PlayerScriptFormat.resolution(script.display, language: language),
                  systemImage: "rectangle.on.rectangle")
                .foregroundStyle(WbColor.textSecondary)
            Spacer()
            Text(PlayerScriptFormat.createdAt(script.created_at))
                .foregroundStyle(WbColor.textTertiary)
        }
        .wbFont(WbType.caption)
        if let warning = compatibilityWarning(script) {
            Label(warning, systemImage: WbIcon.warning)
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: WbSpace.sm) {
            Button(t("重命名…", "Rename…", language)) { rename(script) }
                .disabled(!bridgeAvailable)
            Button(t("导出…", "Export…", language)) { exportScript(script) }
                .disabled(!bridgeAvailable)
            Spacer()
            Button(t("删除", "Delete", language), role: .destructive) { delete(script) }
                .disabled(!bridgeAvailable)
        }
    }

    @ViewBuilder private var emptyDetailRows: some View {
        Text(transport.scripts.isEmpty
             ? t("没有任何操作录制", "No operation recordings", language)
             : t("选择一个操作录制", "Select an operation recording", language))
            .wbFont(WbType.body)
        Text(transport.scripts.isEmpty
             ? t("点击上方的“开始录制”，然后操作设备来创建第一份录制。",
                 "Click “Start recording” above and use the device to create the first recording.", language)
             : t("选择后可以回放、重命名、导出或删除。",
                 "Then replay, rename, export or delete it.", language))
            .wbFont(WbType.caption)
            .foregroundStyle(WbColor.textSecondary)
    }

    private func compatibilityWarning(_ script: PlayerScriptSummary) -> String? {
        guard let display = script.display, display.width > 0, display.height > 0,
              transport.frameWidth > 0, transport.frameHeight > 0 else { return nil }
        guard display.width != transport.frameWidth || display.height != transport.frameHeight else {
            return nil
        }
        return String(format: t("该录制是在 %d×%d 分辨率下录制的；当前画面为 %d×%d。坐标仍会按当前画面换算。",
                                "This recording was captured at %d×%d; the current screen is %d×%d. Coordinates are still mapped to the current screen.",
                                language),
                      display.width, display.height, transport.frameWidth, transport.frameHeight)
    }

    // MARK: Actions

    private var elapsedRecording: TimeInterval {
        guard let started = transport.scriptRecordingStartedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    private func recordingOptions() -> PlaybackOptions {
        var options = PlaybackOptions()
        options.mode = playbackMode
        switch playbackMode {
        case .count:
            options.count = max(1, playbackCount)
            options.duration_ms = 0
        case .duration:
            options.count = 0
            options.duration_ms = max(1, playbackSeconds) * 1000
        case .infinite:
            options.count = 0
            options.duration_ms = 0
        }
        options.interval_ms = min(max(0, playbackIntervalMilliseconds), 24 * 60 * 60 * 1000)
        options.speed = playbackSpeed
        return options
    }

    private func startPlayback() {
        guard let script = selectedScript else { return }
        transport.scriptPlayStart(id: script.id, options: recordingOptions())
    }

    private func stopRecording() {
        guard let name = PlayerScriptPrompts.askName(
            defaultValue: PlayerScriptFormat.suggestedRecordingName(language: language),
            language: language) else {
            transport.scriptRecordCancel()
            return
        }
        transport.scriptRecordStop(name: name)
    }

    private func rename(_ script: PlayerScriptSummary) {
        guard let name = PlayerScriptPrompts.askRename(current: script.name, language: language) else { return }
        transport.scriptRename(id: script.id, name: name)
    }

    private func delete(_ script: PlayerScriptSummary) {
        guard PlayerScriptPrompts.confirmDelete(name: script.name, language: language) else { return }
        transport.scriptDelete(id: script.id)
    }

    private func exportScript(_ script: PlayerScriptSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = t("操作录制.json", "operation-recording.json", language)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transport.scriptExport(id: script.id, path: url.path)
    }

    private func importScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transport.scriptImport(path: url.path)
    }
}
