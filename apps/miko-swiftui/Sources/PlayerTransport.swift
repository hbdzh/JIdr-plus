// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// A small, opt-in measurement sample carried with its matching image. It never
/// retains frame pixels or asks CGDataProvider to copy a full image for a probe.
struct PlayerFrameProbeSample {
    let receivedAt: TimeInterval
    let red: Double
    let green: Double
    let blue: Double
}

// This prototype intentionally requires an explicit device and data directory.
// It never starts, stops, or changes the configuration of an emulator.
final class PlayerTransport: ObservableObject, SyncBridgeTarget {
    enum RecordingState { case idle, starting, recording, stopping }

    @Published var recording: RecordingState = .idle {
        didSet { if recording == .idle { recordingStartedAt = nil } }
    }
    @Published var connectionEnded = false
    @Published var stoppingDevice = false
    @Published var recordingStateUnknown = false
    @Published var language = 1
    @Published var recordAudio = true
    /// What the window shows when there is no live frame (booting/stopped/lost).
    @Published private(set) var linkState: PlayerLinkState = .connecting
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var dropHover: PlayerDrop.Label?
    @Published private(set) var reinstallPrompt: PlayerReinstallPrompt?
    @Published private(set) var frameWidth = 0
    @Published private(set) var frameHeight = 0
    @Published private(set) var device: String?
    @Published private(set) var dataDirectory: String?

    // MARK: Operation recordings (docs/player-scripts.md)
    enum ScriptRecordingState: Equatable { case idle, recording, paused }
    enum ScriptPlaybackState: Equatable { case idle, playing, paused }
    enum GamepadState: Equatable { case disconnected, connecting, connected }

    @Published var gamepadState: GamepadState = .disconnected
    var onToggleGamepad: (() -> Void)?

    /// Scripts listed by the bridge (`script_list` / `saved` notifications).
    @Published private(set) var scripts: [PlayerScriptSummary] = []
    @Published private(set) var scriptRecording: ScriptRecordingState = .idle
    @Published private(set) var scriptPlayback: ScriptPlaybackState = .idle
    /// Current/total loop for the player HUD (`count == 0` means infinite).
    @Published private(set) var scriptPlaybackLoop = 0
    @Published private(set) var scriptPlaybackTotal = 0
    @Published private(set) var scriptPlaybackName: String?
    @Published private(set) var scriptPlaybackMode: PlaybackMode = .count
    @Published private(set) var scriptRecordingStartedAt: Date?
    @Published private(set) var scriptRecordedEvents = 0
    @Published private(set) var scriptRecordFinishing = false
    @Published private(set) var scriptError: String?
    var scriptPlaybackActive: Bool { scriptPlayback != .idle }

    // MARK: Multi-device input synchronizer (D45)
    @Published var syncRole: PlayerSyncRole = .off
    @Published var syncFollowerLocked: Bool = false
    @Published var syncMemberCount: Int = 0
    @Published var syncLockedHintVisible: Bool = false
    var onSyncEvent: ((Int, [String: Any]) -> Void)?
    var onSyncBusy: ((String) -> Void)?
    var onSyncTakeOver: (() -> Void)?
    var onOpenSyncPanel: (() -> Void)?
    var onSyncBridgeLost: (() -> Void)?
    var onSyncLeaderRelease: (() -> Void)?
    var onSyncDisplaySizeChanged: ((Int, Int) -> Void)?
    private var syncLockedHintWorkItem: DispatchWorkItem?
    var syncDeviceID: String? { device }

    /// Per-device rebindable shortcuts, loaded by the window controller.
    let shortcuts = GameShortcutsStore()
    let mapping = KeyMappingStore()

    var onFrame: ((CGImage, Int) -> Void)?
    private(set) var lastFrame: CGImage?
    var onStatus: ((String) -> Void)?
    var onFrameSize: ((Int, Int) -> Void)?
    /// Optional measurement hooks. Normal app launches leave these nil.
    /// Decode runs on the reader queue; draw runs on the main queue.
    var measureDecodedFrame: ((DecodedFrame) -> PlayerFrameProbeSample)?
    var onMeasuredFramePresented: ((PlayerFrameProbeSample) -> Void)?
    var onFrameDrawn: (() -> Void)?
    var onFrameReplaced: (() -> Void)?
    var bridgeProcessIdentifier: Int32? { process?.processIdentifier }
    var onReconnect: (() -> Void)?
    var onAdvanced: (() -> Void)?
    var onPixelPerfect: (() -> Void)?
    var onFitScreen: (() -> Void)?
    var onStartDevice: (() -> Void)?
    var onDataDirectory: ((String) -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var frames: Pipe?
    private var diagnostics: Pipe?
    private let inputQueue = DispatchQueue(label: "miko.prototype.input")
    private let decoder = FrameDecoder()
    private let decoderLock = NSLock()
    private var pendingFrame: (CGImage, Int, PlayerFrameProbeSample?)?
    private var frameScheduled = false
    private let frameLock = NSLock()
    private var diagnosticBuffer = Data()
    private var lastDiagnostic = ""
    private var generation = UUID()
    private var stopping = false
    private var startParameters: (device: String, width: Int, height: Int, executable: String, quality: UInt8)?
    private var stats = PlayerFrameStats()
    private var reinstallAPK: URL?
    private var pendingUninstallAPK: URL?
    private let pasteboard: NSPasteboard = {
        if let name = ProcessInfo.processInfo.environment["MIKO_PROTOTYPE_TEST_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }()
    private var copySequence = 0
    private var pendingCopy: (id: Int, changeCount: Int)?
    private var didReceiveFrame = false

    // MARK: Display visibility (decode gating)
    //
    // The window controller writes the latest AppKit visibility on the main
    // thread; the frame reader queue reads it before creating any CGImage. A
    // dedicated lock keeps that read cheap and independent from `frameLock`.
    private let visibilityLock = NSLock()
    private var _displayVisible = true

    /// Whether decoded frames should currently be turned into CGImages and
    /// handed to the window. Frames are always parsed so the bridge never
    /// blocks on a full stdout pipe.
    var displayVisible: Bool {
        visibilityLock.lock()
        defer { visibilityLock.unlock() }
        return _displayVisible
    }

    /// Called on the main thread from the player window's occlusion/order
    /// notifications. Hiding drops any pending image so a restored window can
    /// only show a frame decoded after it became visible again.
    func setDisplayVisible(_ visible: Bool) {
        visibilityLock.lock()
        let changed = _displayVisible != visible
        _displayVisible = visible
        visibilityLock.unlock()
        guard changed, !visible else { return }
        frameLock.lock()
        pendingFrame = nil
        frameLock.unlock()
    }

    /// Records how to reach this device without opening a stream, so a window
    /// opened for a stopped/booting device can start streaming later
    /// (`applyLaunchState(.running)`).
    func prepareStreaming(device: String, width: Int, height: Int, executable: String, quality: UInt8 = 1) {
        self.device = device
        startParameters = (device, width, height, executable, quality)
    }

    func start(device: String, width: Int, height: Int, executable: String, quality: UInt8 = 1) throws {
        prepareStreaming(device: device, width: width, height: height, executable: executable, quality: quality)
        try launch()
    }

    private func launch() throws {
        guard let parameters = startParameters, process == nil else { return }
        stopping = false
        connectionEnded = false
        didReceiveFrame = false
        lastDiagnostic = ""
        diagnosticBuffer.removeAll()
        decoder.reset()
        let token = UUID()
        generation = token
        let child = Process(), stdin = Pipe(), framePipe = Pipe(), diagnosticPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: parameters.executable)
        child.arguments = [parameters.device, String(parameters.width), String(parameters.height), String(parameters.quality)]
        child.standardInput = stdin
        child.standardOutput = framePipe
        child.standardError = diagnosticPipe
        framePipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeFrames(data)
        }
        diagnosticPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.consumeDiagnostics(data, generation: token)
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.stopping else { return }
                self.processEnded()
            }
        }
        process = child
        input = stdin
        frames = framePipe
        diagnostics = diagnosticPipe
        try child.run()
        linkState = .connecting
        onStatus?(t("正在连接设备…", "Connecting to the device…", language))
    }

    /// Starts pulling frames for a device the caller already reported running.
    func beginStreaming() {
        guard process == nil else { return }
        do { try launch() }
        catch { startFailed(error) }
    }

    private func startFailed(_ error: Error) {
        connectionEnded = true
        linkState = .disconnected(reason: error.localizedDescription)
        onStatus?(t("无法启动桥接：", "Unable to start the connection: ", language) + error.localizedDescription)
    }

    private func processEnded() {
        // Diagnostics already queued on the main thread belong to the ended
        // stream and must not put an interrupted recording back into motion.
        generation = UUID()
        process = nil
        input = nil
        frames = nil
        diagnostics = nil
        connectionEnded = true
        linkState = PlayerExitClassifier.classify(diagnostic: lastDiagnostic)
        let scriptInterrupted = scriptRecording != .idle || scriptPlayback != .idle
        onStatus?(scriptInterrupted ? t("连接中断，操作录制或回放已停止。", "Connection lost; recording or playback stopped.", language) : "")
        markRecordingInterrupted()
        resetScriptSession()
        if syncRole != .off {
            syncRole = .off
            syncFollowerLocked = false
            syncLockedHintVisible = false
            onSyncBridgeLost?()
        }
        reconnectPromptIfEditing()
    }

    /// A script recording/playback lives inside the bridge process: when the
    /// stream ends, no script can still be running. Clear the UI state so the
    /// HUD cannot stay on a dead connection.
    private func resetScriptSession() {
        scriptRecording = .idle
        scriptPlayback = .idle
        scriptRecordingStartedAt = nil
        scriptRecordedEvents = 0
        scriptRecordFinishing = false
        scriptPlaybackMode = .count
        scriptPlaybackLoop = 0
        scriptPlaybackTotal = 0
        scriptPlaybackName = nil
    }

    /// The recording job belongs to the daemon. Losing its reporting stream
    /// cannot establish that the file was saved, but must release the UI's
    /// pending phase so the window can close. Keep the uncertainty explicit.
    private func markRecordingInterrupted() {
        guard recording != .idle else { return }
        recordingStateUnknown = true
        recording = .idle
        onStatus?(t("连接已结束，录屏状态未知；请在设备中心检查录屏。",
                    "The connection ended and the recording state is unknown. Check it in the device center.",
                    language))
    }

    private func reconnectPromptIfEditing() {
        // The state card disables Reconnect while an edit or recording is open;
        // this hint explains why, using the same policy as the center.
        if mapping.editing {
            onStatus?(t("请先保存或取消键位编辑。", "Save or cancel the key-mapping edit first", language))
        }
    }

    /// Applies a state the device center owns (device starting or stopped).
    func applyLaunchState(_ state: PlayerLaunchState) {
        switch state {
        case .running:
            connectionEnded = false
            if process == nil {
                beginStreaming()
            } else if !didReceiveFrame {
                linkState = .connecting
            }
        case .booting(let progress, let message):
            onStatus?("")
            markRecordingInterrupted()
            stopProcess()
            connectionEnded = false
            linkState = .booting(progress: progress.map { min(1, max(0, $0)) }, message: message)
        case .stopped(let reason):
            onStatus?("")
            markRecordingInterrupted()
            stopProcess()
            connectionEnded = false
            linkState = .stopped(reason: reason)
        }
    }

    func reconnect() {
        guard GameReconnectPolicy.permits(disconnected: linkState.canReconnect || connectionEnded,
                                          editing: mapping.editing,
                                          recording: recording != .idle,
                                          recordingUnknown: recordingStateUnknown) else { return }
        if let onReconnect {
            // The center uses this flag to retire the disconnected controller.
            // Only a successful new stream may clear it.
            onReconnect()
            return
        }
        beginStreaming()
    }

    func startDevice() { onStartDevice?() }

    func sendSyncMode(
        role: String,
        lock: Bool,
        leader: String?,
        leaderDisplay: SyncDisplaySize?,
        adaptation: String,
        syncKeyboard: Bool,
        syncText: Bool,
        syncToolKeys: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncRole = PlayerSyncRole(rawValue: role) ?? .off
            self.syncFollowerLocked = (self.syncRole == .follower && lock)
            if self.syncRole != .follower || !lock {
                self.syncLockedHintVisible = false
            }
        }
        var payload: [String: Any] = [
            "type": "sync_mode",
            "role": role,
            "lock": lock,
            "adaptation": adaptation,
            "sync_keyboard": syncKeyboard,
            "sync_text": syncText,
            "sync_tool_keys": syncToolKeys,
        ]
        if let leader {
            payload["leader"] = leader
        }
        if let leaderDisplay {
            payload["leader_display"] = [
                "width": leaderDisplay.width,
                "height": leaderDisplay.height,
            ]
        }
        send(payload)
    }

    func sendSyncInput(seq: Int, event: [String: Any]) {
        send([
            "type": "sync_input",
            "seq": seq,
            "event": event,
        ])
    }

    func sendSyncRelease() {
        send(["type": "sync_release"])
    }

    func showSyncLockedHint() {
        syncLockedHintWorkItem?.cancel()
        syncLockedHintVisible = true
        let work = DispatchWorkItem { [weak self] in
            self?.syncLockedHintVisible = false
        }
        syncLockedHintWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        inputQueue.async { [weak self] in
            guard let self, let process = self.process, process.isRunning, let input = self.input else { return }
            var line = data
            line.append(10)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }
    }

    /// Writes one command synchronously; only used while tearing the bridge
    /// down so a pending async write cannot lose the final script stop.
    private func sendBestEffort(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let process, process.isRunning, let input else { return }
        var line = data
        line.append(10)
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    func noteInput(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stats.recordInput(at: now)
    }

    func frameSnapshot() -> PlayerFrameStats.Snapshot {
        stats.snapshot(at: ProcessInfo.processInfo.systemUptime)
    }

    func setDropHover(_ url: URL?) {
        guard let url else { dropHover = nil; return }
        dropHover = PlayerDrop.label(for: PlayerDrop.classify(url), device: device ?? "", language: language)
    }

    // MARK: Commands

    func chooseScreenshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = t("miko 截图.png", "miko screenshot.png", language)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send(["type": "screenshot", "path": url.path])
        onStatus?(t("正在保存截图…", "Saving the screenshot…", language))
    }

    func toggleRecording() {
        guard !recordingStateUnknown else {
            onStatus?(t("录屏状态未知，请先在设备中心确认。", "The recording state is unknown. Confirm it in the device center first.", language))
            return
        }
        switch recording {
        case .idle:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = t("miko 录屏.mp4", "miko recording.mp4", language)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                onStatus?(t("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name.", language))
                return
            }
            let includeAudio = recordAudio
            recording = .starting
            recordingStartedAt = Date()
            send(["type": "start_recording", "path": url.path, "audio": includeAudio])
            onStatus?(t("正在启动录屏…", "Starting the recording…", language))
        case .recording:
            recording = .stopping
            send(["type": "stop_recording"])
            onStatus?(t("正在保存录屏…", "Saving the recording…", language))
        case .starting, .stopping:
            break
        }
    }

    func chooseFile(apkOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if apkOnly, let apk = UTType(filenameExtension: "apk") { panel.allowedContentTypes = [apk] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sendFile(url)
    }

    func sendFile(_ url: URL) {
        guard url.isFileURL else {
            onStatus?(t("请选择有效的本地文件路径", "Choose a valid local file path", language))
            return
        }
        if url.pathExtension.lowercased() == "apk" { reinstallAPK = url }
        send(["type": "send_file", "path": url.path])
        onStatus?(url.pathExtension.lowercased() == "apk"
                  ? t("正在安装应用…", "Installing the app…", language)
                  : t("正在发送文件…", "Sending the file…", language))
    }

    /// Confirms a signature-conflict reinstall: inspect the APK to find its
    /// package, uninstall it (data is lost) and install the APK again.
    func confirmReinstall() {
        guard let prompt = reinstallPrompt else { return }
        reinstallPrompt = nil
        guard !prompt.apkPath.isEmpty else {
            onStatus?(t("无法确定要重装的应用；请重新选择 APK。", "Cannot tell which app to reinstall. Choose the APK again.", language))
            return
        }
        pendingUninstallAPK = URL(fileURLWithPath: prompt.apkPath)
        send(["type": "app_inspect", "path": prompt.apkPath])
        onStatus?(t("正在检查应用包名…", "Checking the app package…", language))
    }

    func cancelReinstall() { reinstallPrompt = nil }

    func paste() {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            onStatus?(t("Mac 剪贴板中没有可粘贴的文本", "The Mac clipboard has no text to paste", language))
            return
        }
        send(["type": "paste", "text": text])
    }

    func copy(cut: Bool) {
        copySequence += 1
        let id = copySequence
        pendingCopy = (id, pasteboard.changeCount)
        send(["type": cut ? "cut" : "copy", "request_id": id])
        // The bridge answers from the Android clipboard stream; tell the user
        // when no new Android clipboard event arrives instead of staying silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let pending = self.pendingCopy, pending.id == id else { return }
            self.pendingCopy = nil
            self.onStatus?(t("复制超时：Android 剪贴板没有更新。", "Copy timed out: the Android clipboard did not update.", self.language))
        }
    }

    // MARK: Operation recording commands (docs/player-scripts.md)

    func scriptRecordStart() {
        scriptRecordedEvents = 0
        clearScriptError()
        send(["type": "script_record_start"])
    }

    func scriptRecordPause() { send(["type": "script_record_pause"]) }

    func scriptRecordResume() { send(["type": "script_record_resume"]) }

    func scriptRecordStop(name: String) {
        guard !scriptRecordFinishing else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { return }
        scriptRecordFinishing = true
        send(["type": "script_record_stop", "name": value])
    }

    func scriptRecordCancel() { send(["type": "script_record_cancel"]) }

    func scriptList() { send(["type": "script_list"]) }

    func scriptDelete(id: String) { send(["type": "script_delete", "id": id]) }

    func scriptRename(id: String, name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { return }
        send(["type": "script_rename", "id": id, "name": value])
    }

    func scriptImport(path: String) { send(["type": "script_import", "path": path]) }

    func scriptExport(id: String, path: String) {
        send(["type": "script_export", "id": id, "path": path])
    }

    func scriptPlayStart(id: String, options: PlaybackOptions) {
        clearScriptError()
        scriptPlaybackMode = options.mode
        send(["type": "script_play_start", "id": id, "options": options.jsonObject])
    }

    func scriptPlayPause() { send(["type": "script_play_pause"]) }

    func scriptPlayResume() { send(["type": "script_play_resume"]) }

    func scriptPlayStop() { send(["type": "script_play_stop"]) }

    func clearScriptError() { scriptError = nil }

    @discardableResult
    func stop() -> Bool {
        // Closing the window exits the bridge; send the script stop first so
        // the recorder/player can release held inputs cleanly.
        if scriptRecording != .idle { sendBestEffort(["type": "script_record_cancel"]) }
        if scriptPlayback != .idle { sendBestEffort(["type": "script_play_stop"]) }
        resetScriptSession()
        stopping = true
        stopProcess()
        return true
    }

    private func stopProcess() {
        stopping = true
        generation = UUID()
        frames?.fileHandleForReading.readabilityHandler = nil
        diagnostics?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        let child = process
        process = nil
        input = nil
        frames = nil
        diagnostics = nil
        if child?.isRunning == true { child?.terminate() }
    }

    // MARK: Frame and diagnostic streams

    private func consumeFrames(_ data: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        let valid = autoreleasepool {
            decoder.consume(data, shouldDecode: { displayVisible }) { frame in
                // Visibility may have changed while a frame was being read.
                // The stream keeps flowing even when presentation is skipped.
                guard displayVisible else {
                    frameLock.lock()
                    pendingFrame = nil
                    frameLock.unlock()
                    return
                }
                let measurement = measureDecodedFrame?(frame)
                let width = frame.width, height = frame.height, rotation = frame.rotation
                let pixels = frame.pixels
                guard let provider = CGDataProvider(data: pixels as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
                frameLock.lock()
                if pendingFrame != nil { onFrameReplaced?() }
                pendingFrame = (image, rotation, measurement)
                let schedule = !frameScheduled
                if schedule { frameScheduled = true }
                frameLock.unlock()
                if schedule {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.frameLock.lock()
                        let frame = self.pendingFrame
                        self.pendingFrame = nil
                        self.frameScheduled = false
                        self.frameLock.unlock()
                        guard let frame, self.displayVisible else { return }
                        self.display(frame.0, width: width, height: height, rotation: frame.1, measurement: frame.2)
                    }
                }
            }
        }
        if !valid { stop() }
    }

    private func display(_ image: CGImage, width: Int, height: Int, rotation: Int, measurement: PlayerFrameProbeSample?) {
        lastFrame = image
        stats.recordFrame(width: width, height: height, rotation: rotation,
                          at: ProcessInfo.processInfo.systemUptime)
        if !didReceiveFrame {
            didReceiveFrame = true
            connectionEnded = false
            linkState = .running
        }
        if frameWidth != width || frameHeight != height {
            frameWidth = width
            frameHeight = height
            onFrameSize?(width, height)
            onSyncDisplaySizeChanged?(width, height)
        }
        onFrame?(image, rotation)
        if let measurement { onMeasuredFramePresented?(measurement) }
    }

    private func consumeDiagnostics(_ data: Data, generation token: UUID) {
        diagnosticBuffer.append(data)
        while let newline = diagnosticBuffer.firstIndex(of: 10) {
            let line = String(decoding: diagnosticBuffer.prefix(upTo: newline), as: UTF8.self)
            diagnosticBuffer.removeSubrange(...newline)
            if !line.isEmpty { lastDiagnostic = line }
            handleDiagnostic(line, generation: token)
        }
    }

    private func handleDiagnostic(_ line: String, generation token: UUID) {
        if line.hasPrefix("MIKO_CLIPBOARD:") {
            let payload = String(line.dropFirst("MIKO_CLIPBOARD:".count))
            if let data = payload.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = value["request_id"] as? Int, let text = value["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, let pending = self.pendingCopy, pending.id == id else { return }
                    self.pendingCopy = nil
                    guard self.pasteboard.changeCount == pending.changeCount else {
                        self.onStatus?(t("Mac 剪贴板已变化，请重新复制", "The Mac clipboard changed. Copy again", self.language))
                        return
                    }
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(text, forType: .string)
                }
            }
        } else if line.hasPrefix("MIKO_MAPPING_PATH:") {
            let payload = String(line.dropFirst("MIKO_MAPPING_PATH:".count))
            if let data = payload.data(using: .utf8),
               let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let path = result["path"] as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.mapping.load(path: path)
                    let url = URL(fileURLWithPath: path)
                    let root = url.deletingLastPathComponent().deletingLastPathComponent().path
                    self.dataDirectory = root
                    self.onDataDirectory?(root)
                    let prefs = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gui-prefs.json")
                    if let data = try? Data(contentsOf: prefs),
                       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let value = object["language"] as? Int, (0...1).contains(value) {
                        self.language = value
                    }
                }
            }
        } else if line.hasPrefix("MIKO_RECORD:") {
            let payload = String(line.dropFirst("MIKO_RECORD:".count))
            if let data = payload.data(using: .utf8),
               let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let state = result["state"] as? String, let message = result["message"] as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case "recording":
                        self.recording = .recording
                        if self.recordingStartedAt == nil { self.recordingStartedAt = Date() }
                    case "finished", "failed":
                        self.recording = .idle
                        self.recordingStateUnknown = false
                    case "stop_failed":
                        if self.recording == .stopping { self.recording = .recording }
                    default:
                        break
                    }
                    self.onStatus?(message)
                }
            }
        } else if line.hasPrefix("MIKO_APP:") {
            let payload = String(line.dropFirst("MIKO_APP:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                let ok = result["ok"] as? Bool == true
                switch result["op"] as? String {
                case "inspect":
                    if ok, let package = result["package"] as? String, !package.isEmpty {
                        self.send(["type": "app_uninstall", "package": package])
                        self.onStatus?(t("正在卸载旧版本…", "Uninstalling the installed version…", self.language))
                    } else {
                        self.pendingUninstallAPK = nil
                        self.onStatus?(self.appFailureMessage(result["message"] as? String))
                    }
                case "uninstall":
                    if ok {
                        guard let apk = self.pendingUninstallAPK else {
                            let package = result["package"] as? String ?? ""
                            self.onStatus?(t("已卸载 %@", "Uninstalled %@", self.language)
                                .replacingOccurrences(of: "%@", with: package))
                            return
                        }
                        self.pendingUninstallAPK = nil
                        self.sendFile(apk)
                        self.onStatus?(t("旧版本已卸载，正在重新安装…", "The old version was uninstalled; reinstalling…", self.language))
                    } else {
                        self.pendingUninstallAPK = nil
                        self.onStatus?(self.appFailureMessage(result["message"] as? String))
                    }
                default:
                    break
                }
            }
        } else if line.hasPrefix("MIKO_OPERATION:") {
            let payload = String(line.dropFirst("MIKO_OPERATION:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = result["message"] as? String else { return }
            let readable: String
            if message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                readable = t("安装失败：模拟器存储空间不足，请先释放空间。",
                             "Install failed: the emulator is out of storage. Free some space first.",
                             language)
            } else if message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || message.contains("signatures do not match") {
                readable = t("安装失败：应用签名不匹配，原应用及数据未删除。",
                             "Install failed: the app signature does not match. The installed app and its data were not deleted.",
                             language)
            } else {
                readable = message
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                if result["ok"] as? Bool == false,
                   message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || message.contains("signatures do not match"),
                   let apk = self.reinstallAPK {
                    self.reinstallPrompt = PlayerReinstallPrompt(apkPath: apk.path,
                                                                 fileName: apk.lastPathComponent,
                                                                 signatureMismatch: true)
                }
                self.onStatus?(readable)
            }
        } else if line.hasPrefix("MIKO_SCRIPT:") {
            let payload = String(line.dropFirst("MIKO_SCRIPT:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.applyScriptNotification(result)
            }
        } else if line.hasPrefix("MIKO_SYNC:") {
            let payload = String(line.dropFirst("MIKO_SYNC:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let seq = result["seq"] as? Int,
                  let event = result["event"] as? [String: Any] else { return }
            let now = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onSyncEvent?(seq, event)
                _ = now
            }
        } else if line.hasPrefix("MIKO_SYNC_STATUS:") {
            let payload = String(line.dropFirst("MIKO_SYNC_STATUS:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let message = result["message"] as? String ?? ""
            let state = result["state"] as? String
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch state {
                case "busy":
                    self.syncRole = .off
                    self.syncFollowerLocked = false
                    self.syncLockedHintVisible = false
                    self.onSyncBusy?(message)
                case "release":
                    self.onSyncLeaderRelease?()
                default:
                    self.onSyncBusy?(message)
                }
            }
        } else if line.hasPrefix("Invalid input") || line.contains("unknown variant") {
            // The player bridge does not know a command yet (the M2 commands
            // arrive with the pending bridge increment); say so instead of
            // presenting the raw serde error as a successful action.
            let detail = line.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onStatus?(self.unsupportedBridgeMessage(detail))
            }
        } else if !line.isEmpty {
            // A bridge crash prints its final Rust error; the state card shows
            // the translated diagnosis, so do not duplicate it as a transient
            // status bubble.
            guard !line.hasPrefix("Error:") else { return }
            let value = line
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onStatus?(value)
            }
        }
    }

    /// Applies one `MIKO_SCRIPT:` notification from the bridge on the main queue.
    func applyScriptNotification(_ value: [String: Any]) {
        let op = value["op"] as? String ?? ""
        switch op {
        case "record":
            if let count = value["event_count"] as? Int { scriptRecordedEvents = max(0, count) }
            let state = value["state"] as? String ?? ""
            switch state {
            case "recording":
                scriptRecording = .recording
                if scriptRecordingStartedAt == nil { scriptRecordingStartedAt = Date() }
                scriptError = nil
            case "paused":
                scriptRecording = .paused
            case "saved":
                scriptRecordFinishing = false
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                upsertScriptSummary(value["script"])
                NotificationCenter.default.post(name: .playerScriptsChanged, object: nil)
                onStatus?(t("录制已保存", "Recording saved", language))
                scriptList()
            case "stopped":
                scriptRecordFinishing = false
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                scriptList()
            case "failed":
                scriptRecordFinishing = false
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                    message: value["message"] as? String,
                                                    language: language)
                onStatus?(scriptError ?? "")
            default:
                break
            }
        case "list":
            scripts = (value["scripts"] as? [Any])?.compactMap { PlayerScriptSummary.decode($0) } ?? []
            scripts.sort { $0.created_at > $1.created_at }
        case "play":
            if let loop = value["loop"] as? Int { scriptPlaybackLoop = loop }
            scriptPlaybackTotal = value["count"] as? Int ?? 0
            if value["duration_ms"] != nil {
                scriptPlaybackMode = .duration
            } else if scriptPlaybackTotal == 0 {
                scriptPlaybackMode = .infinite
            } else {
                scriptPlaybackMode = .count
            }
            if let name = value["name"] as? String, !name.isEmpty { scriptPlaybackName = name }
            switch value["state"] as? String ?? "" {
            case "playing":
                scriptPlayback = .playing
                scriptError = nil
            case "paused":
                scriptPlayback = .paused
            case "finished", "stopped":
                scriptPlayback = .idle
                scriptPlaybackLoop = 0
                onStatus?((value["state"] as? String) == "finished"
                          ? t("回放已完成", "Playback finished", language)
                          : t("回放已停止", "Playback stopped", language))
            case "failed":
                scriptPlayback = .idle
                scriptPlaybackLoop = 0
                scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                    message: value["message"] as? String,
                                                    language: language)
                onStatus?(scriptError ?? "")
            default:
                break
            }
        case "error":
            scriptRecordFinishing = false
            scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                message: value["message"] as? String,
                                                language: language)
            onStatus?(scriptError ?? "")
        default:
            break
        }
    }

    private func upsertScriptSummary(_ raw: Any?) {
        guard let summary = PlayerScriptSummary.decode(raw) else { return }
        if let index = scripts.firstIndex(where: { $0.id == summary.id }) {
            scripts[index] = summary
        } else {
            scripts.append(summary)
        }
        scripts.sort { $0.created_at > $1.created_at }
    }

    private func unsupportedBridgeMessage(_ detail: String?) -> String {
        let base = t("桥接暂不支持该操作（等待 M1 桥接增量）。",
                     "The bridge does not support this action yet (waiting for the M1 bridge increment).",
                     language)
        guard let detail, !detail.isEmpty else { return base }
        return base + " " + detail
    }

    /// Readable text for an app.inspect/app.uninstall failure: never present a
    /// failure as success and keep the package lookup failure actionable.
    private func appFailureMessage(_ raw: String?) -> String {
        let detail = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail.isEmpty {
            return t("操作未完成，请重试。", "The operation did not complete. Try again.", language)
        }
        if detail.contains("not_found") || detail.contains("not found") {
            return t("设备上找不到该应用，请确认包名。", "The app was not found on the device. Check the package name.", language)
        }
        return t("操作失败：", "The operation failed: ", language) + detail
    }
}
