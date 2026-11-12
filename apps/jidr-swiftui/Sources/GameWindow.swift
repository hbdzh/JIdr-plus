// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import CoreGraphics
import Foundation
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
final class PlayerTransport: ObservableObject {
    enum RecordingState { case idle, starting, recording, stopping }

    @Published var recording: RecordingState = .idle {
        didSet { if recording == .idle { recordingStartedAt = nil } }
    }
    @Published var connectionEnded = false
    @Published var recordingStateUnknown = false
    @Published var language = 1
    /// What the window shows when there is no live frame (booting/stopped/lost).
    @Published private(set) var linkState: PlayerLinkState = .connecting
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var dropHover: PlayerDrop.Label?
    @Published private(set) var reinstallPrompt: PlayerReinstallPrompt?
    @Published private(set) var frameWidth = 0
    @Published private(set) var frameHeight = 0
    @Published private(set) var device: String?
    @Published private(set) var dataDirectory: String?
    /// A sibling `jidr-center-bridge` exposes `--logcat`; the player itself no
    /// longer shows a Logcat UI (it lives in the device center), but the bridge
    /// capability stays available without changing the player bridge.
    @Published private(set) var logcatExecutable: String?

    // MARK: Operation recordings (docs/player-scripts.md)
    enum ScriptRecordingState: Equatable { case idle, recording, paused }
    enum ScriptPlaybackState: Equatable { case idle, playing, paused }

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
    @Published private(set) var scriptError: String?
    var scriptPlaybackActive: Bool { scriptPlayback != .idle }

    /// Per-device rebindable shortcuts, loaded by the window controller.
    let shortcuts = GameShortcutsStore()
    let mapping = KeyMappingStore()

    var onFrame: ((CGImage, Int) -> Void)?
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
    private let inputQueue = DispatchQueue(label: "jidr.prototype.input")
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
        if let name = ProcessInfo.processInfo.environment["JIDR_PROTOTYPE_TEST_PASTEBOARD"], !name.isEmpty {
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
        discoverLogcatExecutable(playerBridge: executable)
    }

    func start(device: String, width: Int, height: Int, executable: String, quality: UInt8 = 1) throws {
        prepareStreaming(device: device, width: width, height: height, executable: executable, quality: quality)
        try launch()
    }

    private func discoverLogcatExecutable(playerBridge: String) {
        let sibling = URL(fileURLWithPath: playerBridge).deletingLastPathComponent()
            .appendingPathComponent("jidr-center-bridge")
        logcatExecutable = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling.path : nil
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
        onStatus?("")
        markRecordingInterrupted()
        resetScriptSession()
        reconnectPromptIfEditing()
    }

    /// A script recording/playback lives inside the bridge process: when the
    /// stream ends, no script can still be running. Clear the UI state so the
    /// HUD cannot stay on a dead connection.
    private func resetScriptSession() {
        scriptRecording = .idle
        scriptPlayback = .idle
        scriptRecordingStartedAt = nil
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
        panel.nameFieldStringValue = t("Jidr 截图.png", "Jidr screenshot.png", language)
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
            panel.nameFieldStringValue = t("Jidr 录屏.mp4", "Jidr recording.mp4", language)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                onStatus?(t("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name.", language))
                return
            }
            recording = .starting
            recordingStartedAt = Date()
            send(["type": "start_recording", "path": url.path])
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
        clearScriptError()
        send(["type": "script_record_start"])
    }

    func scriptRecordPause() { send(["type": "script_record_pause"]) }

    func scriptRecordResume() { send(["type": "script_record_resume"]) }

    func scriptRecordStop(name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { return }
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
            decoder.consume(data) { frame in
                // The decoder has already parsed this frame, so the stream and
                // the bridge keep flowing; only the CGImage/presentation work is
                // skipped while no part of the window is on screen.
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
        if line.hasPrefix("JIDR_CLIPBOARD:") {
            let payload = String(line.dropFirst("JIDR_CLIPBOARD:".count))
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
        } else if line.hasPrefix("JIDR_MAPPING_PATH:") {
            let payload = String(line.dropFirst("JIDR_MAPPING_PATH:".count))
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
        } else if line.hasPrefix("JIDR_RECORD:") {
            let payload = String(line.dropFirst("JIDR_RECORD:".count))
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
        } else if line.hasPrefix("JIDR_APP:") {
            let payload = String(line.dropFirst("JIDR_APP:".count))
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
        } else if line.hasPrefix("JIDR_OPERATION:") {
            let payload = String(line.dropFirst("JIDR_OPERATION:".count))
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
        } else if line.hasPrefix("JIDR_SCRIPT:") {
            let payload = String(line.dropFirst("JIDR_SCRIPT:".count))
            guard let data = payload.data(using: .utf8),
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.applyScriptNotification(result)
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

    /// Applies one `JIDR_SCRIPT:` notification from the bridge on the main queue.
    private func applyScriptNotification(_ value: [String: Any]) {
        let op = value["op"] as? String ?? ""
        switch op {
        case "record":
            let state = value["state"] as? String ?? ""
            switch state {
            case "recording":
                scriptRecording = .recording
                if scriptRecordingStartedAt == nil { scriptRecordingStartedAt = Date() }
                scriptError = nil
            case "paused":
                scriptRecording = .paused
            case "saved":
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                upsertScriptSummary(value["script"])
                scriptList()
            case "stopped":
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                scriptList()
            case "failed":
                scriptRecording = .idle
                scriptRecordingStartedAt = nil
                scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                    message: value["message"] as? String,
                                                    language: language)
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
            case "failed":
                scriptPlayback = .idle
                scriptPlaybackLoop = 0
                scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                    message: value["message"] as? String,
                                                    language: language)
            default:
                break
            }
        case "error":
            scriptError = PlayerScriptText.error(code: value["code"] as? String,
                                                message: value["message"] as? String,
                                                language: language)
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

final class ScreenView: NSView, NSTextInputClient {
    var transport: PlayerTransport?
    var image: CGImage? { didSet { needsDisplay = true } }
    private var rotation = 0
    private var mappedKeys: [UInt16: (id: Int, x: Double, y: Double)] = [:]
    func present(_ frame: CGImage, rotation next: Int) {
        if rotation != next { releaseMappedKeys(); transport?.mapping.rotationChanged(); rotation = next }
        image = frame
    }
    private var marked = NSMutableAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var dragging = false
    private var lastTouch: (CGFloat, CGFloat)?
    private var gesture: PlayerGesture = .single
    private var secondFingerDown = false
    private var secondFinger: (x: Double, y: Double)?
    private var pendingKey: (UInt16, String)?
    private var pressedKeys: [UInt16: String] = [:]
    private var pressedModifiers: Set<String> = []
    private var scriptPlaybackBlocked = false
    private var windowObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        transport?.setDropHover(draggedURL(sender))
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { transport?.setDropHover(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedURL(sender), sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count == 1 else { return false }
        transport?.setDropHover(nil)
        transport?.sendFile(url)
        return true
    }
    private func draggedURL(_ sender: NSDraggingInfo) -> URL? {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
              url.isFileURL else { return nil }
        return url
    }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.releaseHeldInputs() }
        } else {
            windowObserver = nil
        }
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    private var imageRect: NSRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        if let image {
            let backing = window?.backingScaleFactor ?? 1
            let exact = abs(imageRect.width * backing - CGFloat(image.width)) < 0.5 && abs(imageRect.height * backing - CGFloat(image.height)) < 0.5
            NSGraphicsContext.current?.imageInterpolation = exact ? .none : .high
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: imageRect)
            transport?.onFrameDrawn?()
        }
        if let mapping = transport?.mapping {
            for binding in mapping.visibleBindings where binding.rotation == rotation {
                let p = NSPoint(x: imageRect.minX + imageRect.width * binding.x, y: imageRect.minY + imageRect.height * binding.y)
                let circle = NSRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)
                NSColor(WbColor.accentContainer).withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: circle).fill()
                let label = binding.key == "SPACE" ? "SPC" : binding.key
                let markerFont = WbFontResolver.nsFont(family: WbType.label.family, weight: .semibold, size: WbType.label.size)
                let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: NSColor(WbColor.textOnAccent)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
            }
        }
        if marked.length > 0 {
            let box = NSRect(x: 12, y: max(12, bounds.height - 46), width: max(0, bounds.width - 24), height: 34)
            NSColor(WbColor.chrome).withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            marked.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 6))
        }
    }
    private func normalized(_ event: NSEvent) -> (CGFloat, CGFloat)? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return (min(1, max(0, (point.x - rect.minX) / rect.width)),
                min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func sendTouch(_ event: NSEvent, down: Bool) {
        let rect = imageRect, point = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.height > 0 else { return }
        if !dragging && !rect.contains(point) { return }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        let y = min(1, max(0, (point.y - rect.minY) / rect.height))
        lastTouch = (x, y)
        transport?.noteInput()
        transport?.send(["type": "touch", "x": x, "y": y, "down": down])
    }
    /// ⌥ drag = pinch, ⇧⌥ drag = two-finger pan. The second finger travels as a
    /// mapped touch (identifier 3) and goes through the same rotation mapping.
    private func secondFingerPoint(_ event: NSEvent) -> (x: Double, y: Double)? {
        guard let image, let (x, y) = normalized(event) else { return nil }
        return PlayerTouch.secondFinger(gesture, x: Double(x), y: Double(y),
                                        shownWidth: Double(image.width), shownHeight: Double(image.height))
    }
    private func sendSecondFinger(_ point: (x: Double, y: Double), down: Bool) {
        transport?.noteInput()
        transport?.send(["type": "mapped_touch", "id": PlayerTouch.secondFingerID,
                         "x": point.x, "y": point.y, "down": down])
    }
    override func mouseDown(with event: NSEvent) {
        guard !scriptPlaybackActive else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        if let mapping = transport?.mapping, mapping.editing {
            mapping.place(x: Double((point.x - imageRect.minX) / imageRect.width), y: Double((point.y - imageRect.minY) / imageRect.height), rotation: rotation)
            transport?.onStatus?("请按一个字母、数字或空格绑定")
            return
        }
        gesture = PlayerGesture.from(option: event.modifierFlags.contains(.option),
                                     shift: event.modifierFlags.contains(.shift))
        dragging = true
        if gesture.needsSecondFinger, let second = secondFingerPoint(event) {
            secondFinger = second
            secondFingerDown = true
            sendSecondFinger(second, down: true)
        }
        sendTouch(event, down: true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, !scriptPlaybackActive else { return }
        if secondFingerDown, let second = secondFingerPoint(event) {
            secondFinger = second
            sendSecondFinger(second, down: true)
        }
        sendTouch(event, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        if scriptPlaybackActive { clearHeldInputState(); return }
        guard dragging else { return }
        if secondFingerDown, let second = secondFinger {
            sendSecondFinger(second, down: false)
        }
        sendTouch(event, down: false)
        dragging = false
        secondFingerDown = false
        secondFinger = nil
        gesture = .single
    }
    private func releaseMappedKeys() {
        for value in mappedKeys.values { transport?.send(["type": "mapped_touch", "id": value.id, "x": value.x, "y": value.y, "down": false]) }
        mappedKeys.removeAll()
    }
    /// Playback owns input in the bridge. The view stops sending ordinary input
    /// while a script plays; held state is dropped locally without sending
    /// releases because the bridge already released it on playback start.
    func setScriptPlaybackBlocked(_ blocked: Bool) {
        guard blocked != scriptPlaybackBlocked else { return }
        scriptPlaybackBlocked = blocked
        if blocked { clearHeldInputState() }
    }

    private func clearHeldInputState() {
        mappedKeys.removeAll()
        dragging = false
        secondFingerDown = false
        secondFinger = nil
        pendingKey = nil
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        marked = NSMutableAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    private var scriptPlaybackActive: Bool {
        scriptPlaybackBlocked || transport?.scriptPlaybackActive == true
    }

    fileprivate func releaseHeldInputs() {
        releaseMappedKeys()
        if secondFingerDown, let secondFinger { sendSecondFinger(secondFinger, down: false) }
        secondFingerDown = false
        secondFinger = nil
        if dragging, let lastTouch {
            transport?.send(["type": "touch", "x": lastTouch.0, "y": lastTouch.1, "down": false])
            dragging = false
        }
        for key in pressedKeys.values { transport?.send(["type": "key", "key": key, "down": false]) }
        for key in pressedModifiers { transport?.send(["type": "key", "key": key, "down": false]) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
    }
    override func resignFirstResponder() -> Bool {
        releaseHeldInputs()
        return super.resignFirstResponder()
    }
    override func flagsChanged(with event: NSEvent) {
        guard !scriptPlaybackActive else { return }
        for (flag, key) in [(NSEvent.ModifierFlags.shift, "Shift"), (.control, "Control"), (.option, "Alt")] {
            let down = event.modifierFlags.contains(flag)
            if down && !pressedModifiers.contains(key) {
                pressedModifiers.insert(key)
                transport?.send(["type": "key", "key": key, "down": true])
            } else if !down && pressedModifiers.remove(key) != nil {
                transport?.send(["type": "key", "key": key, "down": false])
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        guard !scriptPlaybackActive else { return }
        if let mapping = transport?.mapping, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            let raw = event.charactersIgnoringModifiers ?? ""
            let key = raw == " " ? "SPACE" : raw.uppercased()
            if mapping.editing {
                if mapping.pending && mapping.assign(key) { transport?.onStatus?("已绑定 \(key)") }
                else if mapping.pending { transport?.onStatus?("请使用字母、数字或空格") }
                return
            }
            if mappedKeys[event.keyCode] != nil { return }
            if mapping.enabled, let binding = mapping.scheme.bindings.first(where: { $0.key == key && $0.rotation == rotation }) {
                guard let id = (3...9).first(where: { id in !mappedKeys.values.contains(where: { $0.id == id }) }) else { return }
                mappedKeys[event.keyCode] = (id, binding.x, binding.y)
                transport?.noteInput()
                transport?.send(["type": "mapped_touch", "id": id, "x": binding.x, "y": binding.y, "down": true])
                return
            }
        }
        if event.isARepeat && pressedKeys[event.keyCode] != nil { return }
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v": transport?.paste(); return
            case "c": transport?.copy(cut: false); return
            case "x": transport?.copy(cut: true); return
            case "a": transport?.send(["type": "select_all"]); return
            default: break
            }
        }
        let specials: [UInt16: String] = [36: "Enter", 48: "Tab", 51: "Backspace", 53: "Escape", 117: "Delete", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp"]
        if let key = specials[event.keyCode], !hasMarkedText() {
            pressedKeys[event.keyCode] = key
            transport?.noteInput()
            transport?.send(["type": "key", "key": key, "down": true])
            return
        }
        if !event.isARepeat, let value = event.charactersIgnoringModifiers, value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first, scalar.isASCII, !CharacterSet.controlCharacters.contains(scalar) {
            pendingKey = (event.keyCode, value.lowercased())
        }
        interpretKeyEvents([event])
        pendingKey = nil
    }
    override func keyUp(with event: NSEvent) {
        if scriptPlaybackActive {
            _ = mappedKeys.removeValue(forKey: event.keyCode)
            _ = pressedKeys.removeValue(forKey: event.keyCode)
            return
        }
        if let value = mappedKeys.removeValue(forKey: event.keyCode) {
            transport?.send(["type": "mapped_touch", "id": value.id, "x": value.x, "y": value.y, "down": false])
            return
        }
        if let key = pressedKeys.removeValue(forKey: event.keyCode) { transport?.send(["type": "key", "key": key, "down": false]) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !scriptPlaybackActive else {
            marked = NSMutableAttributedString(string: "")
            markedSelection = NSRange(location: 0, length: 0)
            needsDisplay = true
            return
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        marked = NSMutableAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
        if !wasComposing, let pendingKey, text.unicodeScalars.count == 1, text.unicodeScalars.first?.isASCII == true {
            pressedKeys[pendingKey.0] = pendingKey.1
            transport?.send(["type": "key", "key": pendingKey.1, "down": true])
        } else if !text.isEmpty {
            transport?.send(["type": "text", "text": text])
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !scriptPlaybackActive else { return }
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let markedFont = WbFontResolver.nsFont(family: WbType.body.family, weight: .regular, size: WbType.title.size)
        marked = NSMutableAttributedString(string: value, attributes: [.foregroundColor: NSColor(WbColor.textPrimary), .font: markedFont])
        markedSelection = selectedRange
        needsDisplay = true
    }
    func unmarkText() { marked = NSMutableAttributedString(string: ""); needsDisplay = true }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.foregroundColor, .font] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = NSRect(x: 12, y: max(12, bounds.height - 46), width: 1, height: 24)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) { }
}

struct PlayerView: NSViewRepresentable {
    let transport: PlayerTransport
    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.transport = transport
        transport.mapping.onChange = { [weak view, weak transport] in
            guard let view else { return }
            if let mapping = transport?.mapping, !mapping.enabled || mapping.editing { view.releaseHeldInputs() }
            view.needsDisplay = true
        }
        transport.onFrame = { [weak view] image, rotation in view?.present(image, rotation: rotation) }
        return view
    }
    func updateNSView(_ view: ScreenView, context: Context) {
        view.setScriptPlaybackBlocked(transport.scriptPlaybackActive)
    }
}

private let sidebarWidth: CGFloat = 48

final class SidebarState: ObservableObject {
    @Published var visible = true
}

final class GameWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onWarning: ((String) -> Void)?
    let transport = PlayerTransport()
    let chrome = PlayerChromeState()
    /// The daemon device this window shows; the Device menu uses it to act on
    /// the key window's device (same id the center opened the window for).
    private(set) var deviceID = ""
    /// Human name in the window title; kept for the Window menu.
    private(set) var displayTitle = ""
    private let sidebar = SidebarState()
    private var sidebarButton: NSButton?
    private var pinButton: NSButton?
    private var stateStore: GameWindowStateStore?
    private var visibilityObservers: [NSObjectProtocol] = []
    /// Raw occlusion state observed while the window was known to be on screen.
    /// Some host/SDK combinations (seen on macOS 27 with an older SDK) report an
    /// unrecognised flag instead of `OcclusionState.visible`, so compare against
    /// this baseline rather than trusting the flag alone.
    private var occlusionBaseline: UInt?
    var window: NSWindow?
    private var aspect: CGFloat = 720.0 / 1280.0
    private var side: CGFloat = sidebarWidth
    private var didReceiveSize = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var keyMonitor: Any?
    private var languageCancellable: AnyCancellable?
    private var fullscreenObservers: [NSObjectProtocol] = []
    /// Re-clamps the window when displays are plugged in, unplugged or resized.
    private var screenChangeObserver: NSObjectProtocol?

    private func fitWindow() {
        guard let window else { return }
        let current = window.contentLayoutRect.size
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(200, visible.height - (window.frame.height - current.height) - 24)
        let maxWidth = max(200, visible.width - 24)
        let height = min(current.height, maxHeight, (maxWidth - side) / aspect)
        window.setContentSize(NSSize(width: height * aspect + side, height: height))
        let frame = window.frame
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let decorations = sender.frame.height - sender.contentLayoutRect.height
        let old = sender.contentLayoutRect.size
        let proposedHeight = max(180, frameSize.height - decorations)
        let widthHeight = max(180, (frameSize.width - side) / aspect)
        let height = abs(proposedHeight - old.height) >= abs(widthHeight - old.height) ? proposedHeight : widthHeight
        return NSSize(width: height * aspect + side, height: height + decorations)
    }

    @objc private func toggleSidebar() {
        sidebar.visible.toggle()
        side = sidebar.visible ? sidebarWidth : 0
        updateSidebarButton()
        fitWindow()
    }

    /// The player keeps the native titlebar and traffic lights; its two
    /// accessory buttons pick up the dark chrome tokens so they sit in the
    /// same visual system as the device toolbar.
    private func styleTitlebarButton(_ button: NSButton, symbol: String, label: String,
                                     tint: Color = JidrColor.textSecondary.dark) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(tint)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func updateSidebarButton() {
        let label = sidebar.visible
            ? t("隐藏侧边栏", "Hide sidebar", transport.language)
            : t("显示侧边栏", "Show sidebar", transport.language)
        guard let sidebarButton else { return }
        styleTitlebarButton(sidebarButton,
                            symbol: sidebar.visible ? WbIcon.hideDetails : WbIcon.showDetails,
                            label: label)
    }

    private func addSidebarButton(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggleSidebar)
        button.setAccessibilityRole(.button)
        accessory.view = button
        sidebarButton = button
        window.addTitlebarAccessoryViewController(accessory)
        updateSidebarButton()
    }

    @objc private func togglePin() {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        updatePinButton()
    }

    private func updatePinButton() {
        let pinned = window?.level == .floating
        let label = pinned
            ? t("取消窗口置顶", "Unpin window", transport.language)
            : t("窗口置顶", "Pin window", transport.language)
        guard let pinButton else { return }
        styleTitlebarButton(pinButton,
                            symbol: pinned ? WbIcon.pinned : WbIcon.pin,
                            label: label,
                            tint: pinned ? JidrColor.accentText.dark : JidrColor.textSecondary.dark)
    }

    private func addPinButton(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePin)
        button.setAccessibilityRole(.button)
        accessory.view = button
        pinButton = button
        window.addTitlebarAccessoryViewController(accessory)
        updatePinButton()
    }

    private func saveState() {
        guard let window, let stateStore, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = window.frame
        let state = GameWindowState(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                    sidebar: sidebar.visible, onTop: window.level == .floating, landscape: aspect > 1,
                                    screen: displayIdentifier(window.screen))
        do { try stateStore.save(state) } catch { onWarning?(windowStateMessage(error)) }
    }

    /// Display text for a window-state error: the store reports stable codes,
    /// the player window is where the current language is known.
    private func windowStateMessage(_ error: Error) -> String {
        guard let state = error as? GameWindowStateStore.StateError else { return error.localizedDescription }
        switch state.code {
        case "windowstate.invalid_device":
            return t("设备标识无效。", "Invalid device identifier.", transport.language)
        case "windowstate.invalid_state":
            return t("窗口设置无效，原文件未覆盖。", "The window settings are invalid; the file was not overwritten.", transport.language)
        case "windowstate.changed":
            return t("窗口设置已被其他程序修改，未覆盖原文件。", "The window settings were changed by another program; the file was not overwritten.", transport.language)
        case "windowstate.data_unavailable":
            return t("数据目录不可用，未保存窗口设置。", "The data directory is unavailable; the window settings were not saved.", transport.language)
        default:
            return state.code
        }
    }

    func open(device: String, width: Int, height: Int, executable: String, displayName: String? = nil,
              quality: UInt8 = 1, dataDirectory: String? = nil,
              launch: PlayerLaunchState = .running, onStartDevice: (() -> Void)? = nil) {
        guard width > 0, height > 0 else { return }
        deviceID = device
        displayTitle = displayName ?? device
        aspect = CGFloat(width) / CGFloat(height)
        var saved: GameWindowState?
        var legacy: (sidebar: Bool, onTop: Bool)?
        if let dataDirectory {
            do {
                let store = try GameWindowStateStore(dataDirectory: dataDirectory, device: device)
                saved = try store.load()
                stateStore = store
                if saved == nil { legacy = try store.legacyPreferences() }
            } catch {
                onWarning?(windowStateMessage(error))
            }
            transport.shortcuts.load(dataDirectory: dataDirectory, device: device)
            if ProcessInfo.processInfo.environment["JIDR_PLAYER_FIXTURE"] == "1" {
                // The fixture has no daemon connect_info response to supply
                // this path. Keep local mapping editing usable in its temp home.
                transport.mapping.load(path: URL(fileURLWithPath: dataDirectory)
                    .appendingPathComponent("keymaps").appendingPathComponent("\(device).json").path)
            }
        }
        if let sidebarVisible = saved?.sidebar ?? legacy?.sidebar {
            sidebar.visible = sidebarVisible
            side = sidebarVisible ? sidebarWidth : 0
        }
        let initialHeight: CGFloat = 740
        occlusionBaseline = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: initialHeight * aspect + side, height: initialHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(displayName ?? device) — Jidr"
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        // Chrome only: dark ground and a design-drawn hairline under the native
        // titlebar (ContentView draws it) instead of the system separator.
        window.backgroundColor = NSColor(JidrColor.surfaceChrome.dark)
        window.titlebarSeparatorStyle = .none
        window.contentView = NSHostingView(rootView: ContentView(transport: transport, mapping: transport.mapping, sidebar: sidebar, chrome: chrome))
        addSidebarButton(to: window)
        self.window = window
        window.level = (saved?.onTop ?? legacy?.onTop ?? false) ? .floating : .normal
        addPinButton(to: window)
        updateSidebarButton()
        observeFullscreen(window)
        observeDisplayVisibility(window)
        installKeyMonitor()
        languageCancellable = transport.$language.sink { [weak self] _ in
            self?.updateSidebarButton()
            self?.updatePinButton()
        }
        wireChrome()
        transport.onPixelPerfect = { [weak self] in self?.applyPixelPerfectSize() }
        transport.onFitScreen = { [weak self] in self?.fitScreen() }
        transport.onFrameSize = { [weak self] width, height in
            guard let self, width > 0, height > 0 else { return }
            self.frameWidth = width
            self.frameHeight = height
            let next = CGFloat(width) / CGFloat(height)
            if !self.didReceiveSize || abs(next - self.aspect) > 0.001 {
                self.aspect = next
                self.didReceiveSize = true
                self.fitWindow()
                if self.chrome.pixelPerfect { self.applyPixelPerfectSize() }
            }
        }
        transport.onDataDirectory = { [weak self] path in
            guard let self else { return }
            self.transport.shortcuts.load(dataDirectory: path, device: device)
        }
        transport.onStartDevice = onStartDevice
        if let saved, let frame = restoredFrame(saved) {
            // Restores the saved display when it still exists and clamps the
            // frame into that display's visible area (multi-display + Retina:
            // everything here is AppKit points, never pixels).
            window.setFrame(frame, display: false)
            if saved.landscape != (aspect > 1) { fitWindow() }
        } else {
            fitWindow()
            window.center()
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.clampToVisibleScreen() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        transport.prepareStreaming(device: device, width: width, height: height,
                                   executable: executable, quality: quality)
        switch launch {
        case .running:
            do {
                try transport.start(device: device, width: width, height: height, executable: executable, quality: quality)
            } catch {
                transport.onStatus?(t("无法启动桥接：", "Unable to start the connection: ", transport.language) + error.localizedDescription)
            }
        case .booting, .stopped:
            transport.applyLaunchState(launch)
        }
    }

    /// The `NSScreenNumber` of a display, as stored in the window state.
    private func displayIdentifier(_ screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return number.stringValue
    }

    private var screenGeometries: [GameWindowScreen] {
        NSScreen.screens.map { GameWindowScreen(id: displayIdentifier($0), visible: $0.visibleFrame) }
    }

    /// Frame to restore: same display when it exists, clamped into its visible
    /// area; falls back to the main display when that monitor is gone.
    private func restoredFrame(_ saved: GameWindowState) -> NSRect? {
        GameWindowRestore.restoreFrame(saved, screens: screenGeometries, fallback: NSScreen.main?.visibleFrame)
    }

    /// Displays changed (unplugged, resolution change): keep the window fully
    /// reachable and keep the device aspect after the clamp.
    private func clampToVisibleScreen() {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let visible = screenGeometries.first { $0.id == displayIdentifier(window.screen) }?.visible
            ?? NSScreen.main?.visibleFrame
        guard let visible else { return }
        let clamped = GameWindowRestore.clamp(window.frame, to: visible)
        if clamped != window.frame { window.setFrame(clamped, display: true) }
        fitWindow()
    }

    // MARK: Menu accessors

    /// "View ▸ Show/Hide Sidebar" for the key window.
    var sidebarVisible: Bool { sidebar.visible }
    func toggleSidebarFromMenu() { toggleSidebar() }

    /// Dock/menu "open this device": never opens a duplicate window.
    func focusFromMenu() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Chrome state

    private func wireChrome() {
        chrome.pixelPerfectAction = { [weak self] in self?.applyPixelPerfectSize() }
        chrome.fitAction = { [weak self] in self?.fitScreen() }
        chrome.toggleFullscreenAction = { [weak self] in self?.toggleFullscreen() }
        chrome.toggleSidebarAction = { [weak self] in self?.toggleSidebar() }
        chrome.chooseScreenshotAction = { [weak self] in self?.transport.chooseScreenshot() }
        chrome.toggleRecordingAction = { [weak self] in self?.transport.toggleRecording() }
        chrome.chooseAPKAction = { [weak self] in self?.transport.chooseFile(apkOnly: true) }
        chrome.chooseFileAction = { [weak self] in self?.transport.chooseFile(apkOnly: false) }
        chrome.advancedAction = { [weak self] in self?.transport.onAdvanced?() }
    }

    private func fitScreen() {
        chrome.pixelPerfect = false
        fitWindow()
    }

    private func applyPixelPerfectSize() {
        guard let window, frameWidth > 0, frameHeight > 0, let screen = window.screen else { return }
        let scale = window.backingScaleFactor
        let size = NSSize(width: CGFloat(frameWidth) / scale + side, height: CGFloat(frameHeight) / scale)
        let full = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard !window.styleMask.contains(.fullScreen),
              full.width <= screen.visibleFrame.width, full.height <= screen.visibleFrame.height else {
            transport.onStatus?(t("原始像素大小超出当前屏幕", "The original size does not fit this display", transport.language))
            return
        }
        window.setContentSize(size)
        let frame = window.frame, visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                                      y: min(max(frame.minY, visible.minY), visible.maxY - frame.height)))
        chrome.pixelPerfect = true
    }

    private func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func toggleOverlay() {
        chrome.overlay.toggle()
    }

    /// Mirrors the window's on-screen visibility into the transport. Frames
    /// keep being parsed while hidden, but no CGImage or display work happens
    /// until the window is visible again.
    private func observeDisplayVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in self?.refreshDisplayVisibility() }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            visibilityObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: update))
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
    }

    /// A window counts as shown when it is on the active Space, ordered in, not
    /// miniaturized, the app is not hidden and the occlusion state does not
    /// contradict that.
    private func refreshDisplayVisibility() {
        guard let window else {
            transport.setDisplayVisible(false)
            return
        }
        let onScreen = window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && !NSApp.isHidden
        guard onScreen else {
            transport.setDisplayVisible(false)
            return
        }
        let state = window.occlusionState
        if occlusionBaseline == nil, state.contains(.visible) || state.rawValue != 0 {
            occlusionBaseline = state.rawValue
        }
        // A different, non-visible state than the known on-screen baseline means
        // AppKit reports the window as fully occluded. When the host does not
        // expose a usable state at all (baseline nil) stay visible instead of
        // freezing on a value we cannot interpret.
        if let baseline = occlusionBaseline,
           state.rawValue != baseline,
           !state.contains(.visible) {
            transport.setDisplayVisible(false)
            return
        }
        transport.setDisplayVisible(true)
    }

    private func observeFullscreen(_ window: NSWindow) {
        let center = NotificationCenter.default
        fullscreenObservers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.chrome.fullscreen = true
            self?.chrome.reveal = false
        })
        fullscreenObservers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.chrome.fullscreen = false
            self.chrome.reveal = false
            self.side = self.sidebar.visible ? sidebarWidth : 0
            self.fitWindow()
        })
    }

    // MARK: Window shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil, event.window === self.window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeMonitors() {
        languageCancellable?.cancel()
        languageCancellable = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
        fullscreenObservers.removeAll()
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    /// Returns true when the player consumed the key (it then never reaches the
    /// device). Esc only leaves fullscreen; otherwise it is a game key.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = characters.lowercased()
        let language = transport.language
        if transport.shortcuts.capture != nil {
            if event.keyCode == 53 {
                transport.shortcuts.cancelCapture()
                return true
            }
            if let failure = transport.shortcuts.assign(key: characters,
                                                        command: flags.contains(.command),
                                                        control: flags.contains(.control),
                                                        shift: flags.contains(.shift),
                                                        alt: flags.contains(.option)) {
                onStatusNotice(ShortcutFailure.describe(failure, language: language))
            } else {
                onStatusNotice(t("快捷键已更新。", "Shortcut updated.", language))
            }
            return true
        }
        if event.keyCode == 53 && chrome.fullscreen, NSApp.modalWindow == nil, window?.attachedSheet == nil {
            toggleFullscreen()
            return true
        }
        if flags == [.control, .command], key == "f" {
            toggleFullscreen()
            return true
        }
        if flags == [.command, .option], key == "i" {
            toggleOverlay()
            return true
        }
        if flags == [.command, .option], key == "0" {
            applyPixelPerfectSize()
            return true
        }
        if let binding = ShortcutBinding.make(key: characters,
                                              command: flags.contains(.command),
                                              control: flags.contains(.control),
                                              shift: flags.contains(.shift),
                                              alt: flags.contains(.option)),
           let action = transport.shortcuts.action(for: binding) {
            perform(action)
            return true
        }
        return false
    }

    private func perform(_ action: GameShortcutAction) {
        switch action {
        case .screenshot: transport.chooseScreenshot()
        case .fullscreen: toggleFullscreen()
        case .sidebar: toggleSidebar()
        case .overlay: toggleOverlay()
        case .advanced: transport.onAdvanced?()
        }
    }

    private func onStatusNotice(_ text: String) {
        transport.onStatus?(text)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard transport.recording == .idle else {
            transport.onStatus?(t("请先停止录屏并等待保存完成", "Stop recording and wait for it to finish saving first", transport.language))
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
        removeMonitors()
        transport.setDisplayVisible(false)
        transport.stop()
        onClose?()
        // AppKit may still be processing the close event after its delegate returns.
        DispatchQueue.main.async { [self] in _ = self }
    }

    deinit {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }
}
