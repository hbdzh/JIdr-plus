// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct Device: Identifiable, Decodable, Equatable {
    struct Status: Decodable, Equatable { let state: String }
    struct ImageInfo: Decodable, Equatable { let api: Int; let tag: String }
    struct Root: Decodable, Equatable {
        let mode: String
        let health: String?
        /// Set for a Full-root device once Magisk was installed.
        let magisk_version: String?
        let verified_at: String?
    }
    struct Runtime: Decodable, Equatable {
        let adb_serial: String?
        let console_port: Int?
        let grpc_port: Int?
        let pid: Int?
        /// RFC 3339; daemon timestamps feed the Session section.
        let started_at: String?
        var startedDate: Date? { DaemonTime.date(started_at) }
    }
    let root: Root
    let runtime: Runtime?
    let profile: String
    let sdk_root: String
    struct Launch: Decodable, Equatable { let audio: Bool?; let quick_boot: Bool?; let camera_back: String?; let camera_front: String? }
    let launch: Launch
    let auto_hibernate_minutes: Int?
    let id: String
    let name: String
    let status: Status
    let image: ImageInfo
    var running: Bool { status.state == "running" }
    var stopped: Bool { ["stopped", "crashed", "hibernated"].contains(status.state) }
    func statusText(language: Int) -> String {
        switch status.state {
        case "running": return language == 0 ? "Running" : "运行中"
        case "stopped": return language == 0 ? "Stopped" : "已停止"
        case "starting", "booting": return language == 0 ? "Starting" : "正在启动"
        case "stopping": return language == 0 ? "Stopping" : "正在停止"
        case "hibernated": return language == 0 ? "Hibernated" : "已休眠"
        case "crashed": return language == 0 ? "Crashed" : "异常退出"
        default: return status.state
        }
    }
    var profileLabel: String { profile.replacingOccurrences(of: "_", with: " ").capitalized }
    var androidVersion: String {
        let known = [28:"9",29:"10",30:"11",31:"12",32:"12L",33:"13",34:"14",35:"15",36:"16"]
        return known[image.api].map { "Android \($0) · API \(image.api)" } ?? "Android API \(image.api)"
    }
    /// Image tag as users read it (same mapping as the Slint launcher).
    var imageLabel: String { Self.imageTagLabel(image.tag) }
    static func imageTagLabel(_ tag: String) -> String {
        switch tag {
        case "google_apis": return "Google APIs"
        case "google_apis_playstore", "playstore": return "Play Store"
        case "default": return "AOSP"
        case "aosp_atd": return "AOSP ATD"
        case "google_atd": return "Google ATD"
        default: return tag.replacingOccurrences(of: "_", with: " ")
        }
    }
}
struct Details: Decodable {
    let device: Device
    let config: [String:String]
    let disk_usage: UInt64?
}
struct AndroidApp: Identifiable, Decodable {
    var id: String { package }
    let package: String
    let name: String
    let icon: String?
}
struct AppList: Decodable {
    let apps: [AndroidApp]
    /// False when Android build tools are missing and only package names show.
    let metadata_available: Bool?
    let incomplete_metadata: Bool?
}
struct RootPresentation: Identifiable { let id: String; let name: String }
enum FullRootState { case running, verified(String), failed(String) }

/// Sheets the center window can present. Kept in the model so the command
/// palette, menus and keyboard shortcuts can open the same UI as the buttons.
enum CenterSheet: String, Identifiable {
    case newDevice
    case setupSDK
    case settings
    case snapshots
    case details
    case edit
    var id: String { rawValue }
}

/// Confirmation for an APK that cannot replace an app signed with another key.
struct ReinstallPrompt: Identifiable {
    let id = UUID()
    let device: String
    let deviceName: String
    let apkPath: String
    var apkName: String { URL(fileURLWithPath: apkPath).lastPathComponent }
}

/// A user-readable failure created by the center itself.
struct CenterMessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Per-bridge partial-line buffer; owned by the serial parse queue after start.
private final class ReadBuffer {
    var data = Data()
}

final class CenterModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var deviceListLoaded = false
    var isEmptyDeviceLibrary: Bool { deviceListLoaded && devices.isEmpty }
    @Published var selected: String?
    @Published var details: Details?
    @Published var apps: [AndroidApp] = []
    @Published var appsLoading = false
    @Published var appsError: String?
    @Published var appsNote: String?
    private let appListLoader = AppListLoader<AppList>()
    @Published var notice = ""
    @Published var busy = Set<String>()
    @Published var recording = Set<String>()
    @Published private var requestProgress: [Int:String] = [:]
    @Published private var bootProgress: [String:Double] = [:]
    @Published var language = 1
    @Published var appearance = 0
    weak var centerWindow: NSWindow?
    @Published var deviceQuery = ""
    @Published var detailsVisible = true
    @Published var settingsCategory = 0
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var taskPanel: TaskPanelController?
    private(set) var paletteWindow: PaletteWindowController?
    @Published var tileURL = ""
    @Published var dataDirectory: String?
    @Published var rootPresentation: RootPresentation?
    @Published var fullRoot: [String:FullRootState] = [:]
    @Published var sdkInstalling = false
    @Published var sdkInstallJob: String?
    @Published var sdkCancelPending = false
    @Published var sdkInstallMessage = ""
    @Published var sdkInstallFraction: Double?
    @Published var sdkInstallError: String?
    @Published var sdkInstallSucceeded: Bool?

    // Connection to the daemon through the center bridge.
    @Published private(set) var connection: ConnectionPhase = .connecting
    private let reconnectPolicy = ReconnectPolicy.standard
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var health = ConnectionHealth()
    private var heartbeat: Timer?
    private var heartbeatGeneration = 0
    private var heartbeatPending = false
    private var stopping = false
    private var bridgeSession = 0
    /// When the current bridge session last became usable; a session that dies
    /// sooner than `stableSessionDuration` is a flap and must not reset the
    /// retry budget.
    private var onlineSince: Date?
    private let stableSessionDuration: TimeInterval = 5
    /// Methods answered by the bridge itself, without the daemon. A reply to
    /// one of them does not prove the daemon is reachable.
    private let localMethods: Set<String> = ["center.prefs.get", "center.prefs.set", "center.paths",
                                             "center.about", "center.toolpath.set", "center.migration.preflight"]
    private var requestMethods: [Int:String] = [:]

    // Background tasks (daemon jobs).
    @Published private(set) var jobs: [JobInfo] = []
    @Published var jobsError: String?
    private var jobsTimer: Timer?

    // Transient feedback and overlays.
    @Published var toast: Toast?
    private var toastDismissWork: DispatchWorkItem?
    @Published var paletteOpen = false
    @Published var tasksOpen = false
    @Published private(set) var quitReason: String?
    @Published var sheet: CenterSheet?
    @Published var searchFocusRequest = 0
    @Published var deleteRequested = false
    @Published var reinstallPrompt: ReinstallPrompt?
    @Published var paletteQuery = "" { didSet { if paletteSelection != 0 { paletteSelection = 0 } } }
    @Published var paletteSelection = 0
    private var pendingSheetAfterDetails: CenterSheet?

    private var process = Process()
    private var input = Pipe()
    private var output = Pipe()
    private let parseQueue = DispatchQueue(label: "local.jidr.center.parse", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "local.jidr.center.decode", qos: .userInitiated)
    private var callbacks: [Int:(Result<Any,Error>)->Void] = [:]
    private var progressCallbacks: [Int:(String,String?,Double?)->Void] = [:]
    private var requestDevices: [Int:String] = [:]
    private var mutations = Set<Int>()
    /// Job ids started by this center, so a device held by our own job is not
    /// reported as "in use by another client".
    private(set) var ownJobs = Set<String>()
    var hasMutations: Bool { !mutations.isEmpty }
    private var sequence = 0
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false
    private var jobsGeneration = 0
    private var jobsInFlight = false
    private var jobsPending = false
    private var eventRefreshWork: DispatchWorkItem?
    private var detailGeneration = 0
    private var selectionCleared = false
    private(set) var players: [String:GameWindowController] = [:]
    private var advancedWindows: [String:AdvancedToolsWindowController] = [:]
    private var openingPlayers = Set<String>()
    /// Last launch state handed to a player window, so device refreshes do not
    /// reapply it (reapplying `.running` would reset the window's status).
    var appliedLaunch = [String: PlayerLaunchState]()
    let bridgeExecutable: String
    let centerExecutable: String
    var onPlayersChanged: (() -> Void)?

    init(center: String, bridge: String) throws {
        bridgeExecutable = bridge; centerExecutable = center
        try startBridge()
        bootstrapBridge()
    }
    // MARK: - Bridge process lifecycle

    /// Starts a fresh bridge process. `Process` cannot be run twice, so every
    /// reconnect creates a new process and pair of pipes.
    private func startBridge() throws {
        bridgeSession += 1
        let session = bridgeSession
        resetRefreshTracking()
        let readBuffer = ReadBuffer()
        output.fileHandleForReading.readabilityHandler = nil
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath:centerExecutable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Split lines and parse JSON on the serial parse queue; only the
            // resulting events touch the model on the main thread.
            self?.parseQueue.async { self?.receive(data, session: session, buffer: readBuffer) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeTerminated(session: session) }
        }
        try process.run()
        self.process = process
        self.input = input
        self.output = output
    }

    /// Requests the state the center needs from a fresh bridge: preferences,
    /// paths, devices and jobs (also used after a reconnect).
    private func bootstrapBridge() {
        call("center.prefs.get") { [weak self] result in
            if case .success(let value) = result, let prefs = value as? [String:Any] {
                self?.language = prefs["language"] as? Int ?? 1
                self?.appearance = prefs["appearance"] as? Int ?? 0
                self?.tileURL = prefs["tile_url"] as? String ?? ""
            }
        }
        call("center.paths") { [weak self] result in
            if case .success(let value) = result, let paths = value as? [String:Any] {
                self?.dataDirectory = paths["data"] as? String
            }
        }
        refresh()
        refreshJobs()
    }

    private func bridgeTerminated(session: Int) {
        guard session == bridgeSession else { return }
        output.fileHandleForReading.readabilityHandler = nil
        appsLoading = false
        failPendingRequests()
        guard !stopping else { return }
        noteSessionEnded()
        scheduleReconnect()
    }

    /// A bridge session that lasted long enough retries from a fresh budget;
    /// a flapping one keeps backing off until the attempt cap shows "disconnected".
    private func noteSessionEnded() {
        if let since = onlineSince, Date().timeIntervalSince(since) >= stableSessionDuration {
            reconnectAttempt = 0
        }
        onlineSince = nil
    }

    private func failPendingRequests() {
        resetRefreshTracking()
        let pending = Array(callbacks.values)
        callbacks.removeAll(); progressCallbacks.removeAll(); mutations.removeAll()
        requestDevices.removeAll(); requestProgress.removeAll(); requestMethods.removeAll(); bootProgress.removeAll()
        for done in pending { done(.failure(connectionEndedError())) }
    }

    private func connectionEndedError() -> Error {
        CenterMessageError(message: text("后台连接已结束", "The background connection ended"))
    }

    private func scheduleReconnect() {
        guard !stopping, reconnectWorkItem == nil else { return }
        stopHeartbeat()
        reconnectAttempt += 1
        guard !reconnectPolicy.isExhausted(afterAttempt: reconnectAttempt) else {
            connection = .disconnected
            showError(text("无法重新连接到后台服务。请检查后台进程后重试。", "Could not reconnect to the background service. Check the daemon and try again."))
            return
        }
        connection = .reconnecting(attempt: reconnectAttempt)
        let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.relaunchBridge()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func relaunchBridge() {
        guard !stopping else { return }
        do {
            try startBridge()
            bootstrapBridge()
        } catch {
            scheduleReconnect()
        }
    }

    /// The daemon socket closed or stopped answering: fail what is in flight,
    /// restart the bridge, and show "reconnecting" until a reply arrives.
    private func connectionLost() {
        guard !stopping, reconnectWorkItem == nil else { return }
        appsLoading = false
        stopHeartbeat()
        failPendingRequests()
        noteSessionEnded()
        scheduleReconnect()
        if process.isRunning {
            process.terminate()
        }
    }

    private func bridgeAnswered() {
        // Once a restart is scheduled, replies still draining from the doomed
        // bridge session must not cancel the "reconnecting" state.
        guard !stopping, reconnectWorkItem == nil, connection != .online else { return }
        let wasReconnecting: Bool
        if case .reconnecting = connection { wasReconnecting = true } else { wasReconnecting = false }
        connection = .online
        onlineSince = Date()
        health.recordSuccess()
        startHeartbeat()
        if wasReconnecting { showToast(text("已重新连接到后台服务。", "Reconnected to the background service.")) }
    }

    /// Manual retry from the disconnected banner; starts a fresh backoff run.
    func retryConnection() {
        guard connection == .disconnected else { return }
        reconnectAttempt = 0
        scheduleReconnect()
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: centerHeartbeatInterval, repeats: true) { [weak self] _ in
            self?.probeDaemon()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        heartbeatPending = false
        heartbeatGeneration &+= 1
    }

    /// A cheap `device.list` probe catches a daemon that died while the bridge
    /// process stayed alive (the bridge has no health check of its own).
    private func probeDaemon() {
        guard connection.isOnline, !stopping, !heartbeatPending else { return }
        heartbeatPending = true
        heartbeatGeneration &+= 1
        let generation = heartbeatGeneration
        let session = bridgeSession
        call("device.list") { [weak self] result in
            guard let self, generation == self.heartbeatGeneration, session == self.bridgeSession else { return }
            self.heartbeatPending = false
            switch result {
            case .success: self.health.recordSuccess()
            case .failure(let error):
                if self.health.recordFailure(error.localizedDescription) { self.connectionLost() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + centerHeartbeatTimeout) { [weak self] in
            guard let self, generation == self.heartbeatGeneration, self.heartbeatPending, !self.stopping else { return }
            self.heartbeatPending = false
            // A daemon that leaves a probe unanswered for the whole timeout is
            // treated as gone: the bridge is restarted (safe and idempotent).
            self.connectionLost()
        }
    }

    /// The palette shows eight rows (Slint shows eight): keyboard selection
    /// only moves through the rows the user can see.
    var paletteVisibleCount: Int { min(8, paletteFiltered.count) }

    var connectionLabel: String {
        switch connection {
        case .connecting: return text("正在连接…", "Connecting…")
        case .online: return ""
        case .reconnecting(let attempt): return text("正在重新连接…（第 \(attempt) 次）", "Reconnecting… (attempt \(attempt))")
        case .disconnected: return text("后台已断开", "Disconnected")
        }
    }

    var connectionNeedsRetry: Bool { connection == .disconnected }

    // MARK: - Requests

    func call(_ method: String, _ params: [String:Any] = [:], onProgress: ((String,String?,Double?)->Void)? = nil, done: @escaping (Result<Any,Error>) -> Void) {
        sequence += 1; let id = sequence
        guard process.isRunning, let data = try? JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params]) else {
            done(.failure(CenterMessageError(message: text("后台未连接", "The background service is not connected")))); return
        }
        callbacks[id] = done
        progressCallbacks[id] = onProgress
        requestMethods[id] = method
        if let device = params["device"] as? String { requestDevices[id] = device }
        let readOnly = ["device.list", "device.details", "app.list", "app.inspect", "image.list", "profile.list", "snapshot.list", "sdk.status", "settings.get", "cache.list", "center.about", "center.paths", "center.prefs.get", "center.quit", "center.migration.preflight", "battery.get", "gps.get", "network.get", "network.proxy.get", "sensor.get", "logcat.dump", "root.cacert.list", "device.props.get", "dev.get", "clipboard.get", "jobs.list", "jobs.get", "daemon.status"]
        if !readOnly.contains(method) { mutations.insert(id) }
        do { try input.fileHandleForWriting.write(contentsOf:data + Data([10])) }
        catch { callbacks.removeValue(forKey:id); progressCallbacks.removeValue(forKey:id); mutations.remove(id); requestDevices.removeValue(forKey:id); done(.failure(error)) }
    }
    /// Split NDJSON and parse each event on the serial parse queue. Only the
    /// resulting dictionaries are handed to the main thread, keeping line
    /// buffering and JSONSerialization off the UI thread.
    private func receive(_ data: Data, session: Int, buffer: ReadBuffer) {
        buffer.data.append(data)
        while let end = buffer.data.firstIndex(of: 10) {
            let line = Data(buffer.data.prefix(upTo: end))
            buffer.data.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String:Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.applyEvent(event, session: session) }
        }
    }

    private func applyEvent(_ event: [String:Any], session: Int) {
        guard session == bridgeSession else { return }
        guard let kind = event["type"] as? String else { return }
        if kind == "device_event" {
            bridgeAnswered()
            var immediateRefresh = false
            if let event = event["event"] as? [String:Any], let topic = event["topic"] as? String,
               let data = event["data"] as? [String:Any], let device = data["device"] as? String {
                if topic == "device.boot", let progress = data["progress"] as? Double {
                    // Boot progress is a cheap, high-frequency signal: update it
                    // immediately but never trigger a full list refresh for it.
                    let value = min(1, max(0, progress))
                    if bootProgress[device] != value { bootProgress[device] = value }
                    return
                } else {
                    if topic == "device.boot_failed" { bootProgress.removeValue(forKey:device) }
                    immediateRefresh = topic == "device.boot_failed"
                        || topic.localizedCaseInsensitiveContains("error")
                        || topic.localizedCaseInsensitiveContains("failed")
                }
            }
            if immediateRefresh { refreshImmediately() } else { scheduleCoalescedRefresh() }
            return
        }
        guard let id = event["id"] as? Int else { return }
        let method = requestMethods[id]
        if kind == "progress" {
            bridgeAnswered()
            progressCallbacks[id]?(event["message"] as? String ?? "", event["job"] as? String, event["progress"] as? Double)
            if let message = event["message"] as? String, !message.isEmpty {
                if requestDevices[id] != nil { requestProgress[id] = message }
                else { notice = OperationMessages.progress(message,language:language) }
            }
            return
        }
        requestProgress.removeValue(forKey:id)
        progressCallbacks.removeValue(forKey:id)
        requestDevices.removeValue(forKey:id)
        requestMethods.removeValue(forKey:id)
        mutations.remove(id)
        guard let completion = callbacks.removeValue(forKey:id) else { return }
        if kind == "error" {
            let message = event["message"] as? String ?? "操作失败"
            completion(.failure(CenterMessageError(message: message)))
            if let method, !localMethods.contains(method) { bridgeAnswered() }
            if ConnectionHealth.looksDisconnected(message) { connectionLost() }
        } else {
            completion(.success(event["result"] ?? NSNull()))
            if let method, !localMethods.contains(method) { bridgeAnswered() }
        }
    }

    // MARK: - Coalesced refresh scheduling

    /// Ordinary device events arrive in bursts; one trailing refresh per short
    /// window avoids one `device.list` + `jobs.list` pair per event.
    private func scheduleCoalescedRefresh() {
        guard eventRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventRefreshWork = nil
            guard !self.stopping, self.process.isRunning else { return }
            self.refresh(); self.refreshJobs()
        }
        eventRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func refreshImmediately() {
        eventRefreshWork?.cancel(); eventRefreshWork = nil
        refresh(); refreshJobs()
    }

    private func resetRefreshTracking() {
        refreshInFlight = false; refreshPending = false
        jobsInFlight = false; jobsPending = false
        eventRefreshWork?.cancel(); eventRefreshWork = nil
    }

    /// Decode the two large list payloads off the main thread, then hand the
    /// typed value back on the main queue. Callers keep their existing
    /// generation/session checks in the main-thread completion.
    private func decodeDevicesInBackground(_ value: Any,
                                           completion: @escaping (Result<[Device],Error>) -> Void) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<[Device],Error>
            do { result = .success(try self.decode(value, as: [Device].self)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func decodeJobsInBackground(_ value: Any,
                                        completion: @escaping (Result<[JobInfo],Error>) -> Void) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<[JobInfo],Error>
            do { result = .success(try self.decode(value, as: [JobInfo].self)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func decode<T:Decodable>(_ value:Any, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject:value, options:.fragmentsAllowed))
    }
    func text(_ chinese:String, _ english:String) -> String { language == 0 ? english : chinese }

    // MARK: - Feedback and overlays

    func showToast(_ text: String, tone: ToastTone = .positive) {
        let toast = tone == .negative ? Toast.negative(text) : Toast.positive(text)
        self.toast = toast
        toastDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + toast.duration, execute: work)
    }
    func showError(_ message: String) { showToast(message, tone: .negative) }
    func showError(_ error: Error) { showError(readable(error)) }
    func dismissToast() { toastDismissWork?.cancel(); toastDismissWork = nil; toast = nil }
    /// Localizes a daemon/bridge error for the current language.
    func readable(_ error: Error) -> String {
        OperationMessages.error(error.localizedDescription, language: language)
    }

    func openPalette() {
        setTasksOpen(false)
        quitReason = nil
        paletteQuery = ""
        paletteSelection = 0
        paletteOpen = true
        if paletteWindow == nil { paletteWindow = PaletteWindowController(model: self) }
        paletteWindow?.present(relativeTo: centerWindow ?? NSApp.mainWindow)
    }
    func togglePalette() { paletteOpen ? dismissOverlay() : openPalette() }
    func hidePalette() {
        paletteOpen = false
        paletteWindow?.window?.orderOut(nil)
    }
    func closeOverlay() {
        if paletteOpen { hidePalette() }
        else { setTasksOpen(false); quitReason = nil }
    }
    func dismissOverlay() { closeOverlay() }
    func openTasks() {
        paletteOpen = false
        paletteWindow?.window?.orderOut(nil)
        quitReason = nil
        setTasksOpen(true)
        refreshJobs()
    }
    private func setTasksOpen(_ open: Bool) {
        tasksOpen = open
        if open {
            if taskPanel == nil { taskPanel = TaskPanelController(model: self) }
            if taskPanel?.window?.isMiniaturized == true { taskPanel?.window?.deminiaturize(nil) }
            taskPanel?.showWindow(nil)
            taskPanel?.window?.makeKeyAndOrderFront(nil)
        } else { taskPanel?.window?.orderOut(nil) }
        if open || hasActiveJobs { startJobsTimer() } else { stopJobsTimer() }
    }
    func taskPanelDidClose() { setTasksOpen(false); quitReason = nil }
    func present(_ sheet: CenterSheet) {
        hidePalette()
        if sheet == .settings {
            if settingsWindow == nil { settingsWindow = SettingsWindowController(model: self) }
            settingsWindow?.showWindow(nil)
            settingsWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        // Swapping the presented sheet in place is not reliable; dismiss the
        // current one first so menu/palette actions always land.
        if self.sheet != nil {
            self.sheet = nil
            DispatchQueue.main.async { [weak self] in self?.sheet = sheet }
        } else {
            self.sheet = sheet
        }
    }
    /// Opens a sheet that needs freshly loaded `device.details`.
    func presentDeviceSheet(_ sheet: CenterSheet, device: String) {
        hidePalette()
        if selected != device || details?.device.id != device {
            pendingSheetAfterDetails = sheet
            select(device)
        } else { present(sheet) }
    }

    // MARK: - Shortcuts

    /// Handles a key-down from the local event monitor; false lets the event
    /// reach the responder chain (text editing and everything unclaimed).
    func handleShortcutEvent(_ event: NSEvent) -> Bool {
        // A sheet owns its keyboard while it is up (its own Esc/Return before
        // the center's globals); do not steal keys across windows.
        guard sheet == nil else { return false }
        let input = ShortcutInput(
            key: Self.keyName(for: event),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            context: paletteOpen ? .palette : .window,
            isEditingText: Self.isEditingText(event.window)
        )
        guard let command = ShortcutResolver.resolve(input) else { return false }
        switch command {
        case .palette:
            togglePalette()
        case .newDevice:
            present(.newDevice)
        case .settings:
            present(.settings)
        case .refreshDevices:
            refresh(); refreshJobs()
        case .focusSearch:
            guard !paletteOpen else { return false }
            searchFocusRequest += 1
        case .dismissOverlay:
            guard paletteOpen || tasksOpen else { return false }
            closeOverlay()
        case .paletteUp:
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: -1, count: paletteVisibleCount)
        case .paletteDown:
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: 1, count: paletteVisibleCount)
        case .paletteConfirm:
            let entries = Array(paletteFiltered.prefix(paletteVisibleCount))
            guard paletteSelection >= 0, paletteSelection < entries.count else { return false }
            let entry = entries[paletteSelection]
            closeOverlay()
            runPaletteAction(entry.action)
        }
        return true
    }

    private static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 53: return "escape"
        case 36, 76: return "return"
        case 126: return "up"
        case 125: return "down"
        default: return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }
    private static func isEditingText(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        // SwiftUI text fields are edited by an NSTextView field editor.
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

    // MARK: - Quit guard

    /// Why quitting is unsafe right now; nil means it is safe. The quit path
    /// shows this in the task list instead of blocking silently.
    var quitBlockReason: String? {
        if hasActiveRecording || !recording.isEmpty { return text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first.") }
        if hasPlayers { return self.text("请先关闭游戏窗口。", "Close the game window first.") }
        let active = activeJobs.count
        if active > 0 {
            return self.text("还有 \(active) 个后台任务正在运行。取消它们或等待完成后再退出。", "\(active) background task(s) are still running. Cancel them or wait for them to finish before quitting.")
        }
        if hasMutations { return self.text("正在等待当前设备操作完成…", "Waiting for the current device operation to finish…") }
        return nil
    }

    func presentQuitBlocker() {
        paletteOpen = false
        paletteWindow?.window?.orderOut(nil)
        quitReason = quitBlockReason ?? self.text("暂时无法退出。", "Cannot quit right now.")
        setTasksOpen(true)
        refreshJobs()
    }

    /// Undoes `beginSafeQuit` when the daemon refused to stop, so the center
    /// can keep working (and reconnect if the bridge went away meanwhile).
    func resumeAfterFailedQuit() {
        stopping = false
        if process.isRunning { startHeartbeat() } else { scheduleReconnect() }
    }

    /// Pins the model to shutdown so a closing bridge is not restarted.
    func beginSafeQuit() {
        stopping = true
        onlineSince = nil
        stopHeartbeat()
        jobsTimer?.invalidate(); jobsTimer = nil
        hidePalette()
        setTasksOpen(false)
    }

    // MARK: - Jobs

    var activeJobs: [JobInfo] { jobs.filter(\.isActive) }
    var hasActiveJobs: Bool { jobs.contains(where: \.isActive) }

    func refreshJobs() {
        guard !stopping, process.isRunning else { return }
        if jobsInFlight { jobsPending = true; return }
        jobsInFlight = true
        jobsGeneration += 1; let generation = jobsGeneration
        let session = bridgeSession
        call("jobs.list", ["all": true]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.decodeJobsInBackground(value) { [weak self] decoded in
                    guard let self else { return }
                    if session == self.bridgeSession, generation == self.jobsGeneration {
                        switch decoded {
                        case .success(let list):
                            if self.jobs != list { self.jobs = list }
                            self.ownJobs.formIntersection(Set(list.map(\.id)))
                            if self.jobsError != nil { self.jobsError = nil }
                            self.syncJobsTimer()
                        case .failure(let error): self.jobsError = self.readable(error)
                        }
                    }
                    self.finishJobsRefresh(session: session)
                }
            case .failure(let error):
                if session == self.bridgeSession, generation == self.jobsGeneration {
                    self.jobsError = self.readable(error)
                }
                self.finishJobsRefresh(session: session)
            }
        }
    }
    private func finishJobsRefresh(session: Int) {
        guard session == bridgeSession else { return }
        jobsInFlight = false
        if jobsPending { jobsPending = false; refreshJobs() }
    }
    private func syncJobsTimer() {
        if hasActiveJobs || tasksOpen { startJobsTimer() } else { stopJobsTimer() }
    }
    private func startJobsTimer() {
        guard jobsTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshJobs() }
        RunLoop.main.add(timer, forMode: .common)
        jobsTimer = timer
    }
    private func stopJobsTimer() {
        jobsTimer?.invalidate(); jobsTimer = nil
    }
    func cancelJob(_ id: String) {
        guard !stopping else { return }
        showToast(text("正在取消任务…", "Cancelling task…"))
        call("jobs.cancel", ["job": id]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.refreshJobs()
            case .failure(let error): self.showError(self.readable(error))
            }
        }
    }

    // MARK: - SDK install

    func startSDKInstall(_ plan: SDKInstallPlan) {
        guard !sdkInstalling else { return }
        sdkInstalling = true; sdkCancelPending = false; sdkInstallJob = nil; sdkInstallError = nil; sdkInstallFraction = nil; sdkInstallSucceeded = nil
        sdkInstallMessage = text("正在准备安装…", "Preparing installation…")
        call(plan.method,plan.parameters,onProgress:{ [weak self] message, job, fraction in
            guard let self else { return }
            if let job { self.sdkInstallJob = job; self.ownJobs.insert(job) }
            if !message.isEmpty { self.sdkInstallMessage = OperationMessages.progress(message,language:self.language) }
            self.sdkInstallFraction = SDKInstallPlan.validProgress(fraction)
        }) { [weak self] result in
            guard let self else { return }
            let cancellationRequested = self.sdkCancelPending
            self.sdkInstalling = false; self.sdkCancelPending = false; self.sdkInstallJob = nil
            switch result {
            case .success:
                self.sdkInstallSucceeded = true
                self.sdkInstallMessage = self.text("SDK 安装完成。", "SDK installation complete.")
                self.showToast(self.sdkInstallMessage)
                self.refresh(); self.refreshJobs()
            case .failure(let error):
                self.sdkInstallSucceeded = false
                if SDKInstallPlan.wasCancelled(error.localizedDescription,requested:cancellationRequested) {
                    self.sdkInstallMessage = self.text("SDK 安装已取消。", "SDK installation cancelled.")
                    self.showToast(self.sdkInstallMessage)
                } else {
                    let readable = OperationMessages.error(error.localizedDescription,language:self.language)
                    self.sdkInstallError = readable
                    self.sdkInstallMessage = self.text("SDK 安装未完成。", "SDK installation did not finish.")
                    self.showError(self.sdkInstallMessage + " " + readable)
                }
                self.refreshJobs()
            }
        }
    }
    func cancelSDKInstall() {
        guard sdkInstalling, !sdkCancelPending, let job = sdkInstallJob else { return }
        sdkCancelPending = true
        call("jobs.cancel",["job":job]) { [weak self] result in
            guard let self, self.sdkInstalling, case .failure(let error) = result else { return }
            self.sdkCancelPending = false
            self.sdkInstallError = OperationMessages.error(error.localizedDescription,language:self.language)
            self.showError(self.sdkInstallError ?? self.readable(error))
        }
    }
    var displayNotice: String { OperationMessages.notice(notice,language:language) }
    func creationError(_ error:Error) -> String {
        let message = error.localizedDescription
        guard language == 0 else { return message }
        let translations = [
            "请填写名称并选择镜像及配置。":"Enter a name and select an image and profile.",
            "内存必须介于 512 和 65536 MB 之间。":"Memory must be between 512 and 65536 MB.",
            "CPU 核心数必须介于 1 和 16 之间。":"CPU cores must be between 1 and 16.",
            "设备存储必须介于 2 和 256 GB 之间。":"Device storage must be between 2 and 256 GB.",
            "请选择有效的 Root 模式。":"Select a valid root mode.",
            "Play 商店镜像不支持 Shell root，请选择其他 Root 模式。":"Play Store images do not support shell root. Choose another root mode."
        ]
        return translations[message] ?? message
    }
    /// Raw boot fraction for the player window (nil before the first event).
    func bootProgressFraction(for device: String) -> Double? { bootProgress[device] }
    func progress(for device:String) -> String? {
        if let value = bootProgress[device], devices.first(where: { $0.id == device })?.running != true {
            return text("正在启动 \(Int(value * 100))%", "Starting \(Int(value * 100))%")
        }
        return requestDevices.filter { $0.value == device }.keys.sorted().reversed().compactMap { requestProgress[$0] }.first.map { OperationMessages.progress($0,language:language) }
    }
    func refresh() {
        guard process.isRunning else { return }
        eventRefreshWork?.cancel(); eventRefreshWork = nil
        if refreshInFlight { refreshPending = true; return }
        refreshInFlight = true
        refreshGeneration += 1; let generation = refreshGeneration
        let session = bridgeSession
        call("device.list") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.decodeDevicesInBackground(value) { [weak self] decoded in
                    guard let self else { return }
                    if session == self.bridgeSession, generation == self.refreshGeneration {
                        switch decoded {
                        case .success(let list): self.applyDeviceList(list)
                        case .failure(let error): self.notice = error.localizedDescription
                        }
                    }
                    self.finishRefresh(session: session)
                }
            case .failure(let error):
                if session == self.bridgeSession, generation == self.refreshGeneration {
                    self.notice = error.localizedDescription
                }
                self.finishRefresh(session: session)
            }
        }
    }
    private func finishRefresh(session: Int) {
        guard session == bridgeSession else { return }
        refreshInFlight = false
        if refreshPending { refreshPending = false; refresh() }
    }
    private func applyDeviceList(_ list: [Device]) {
        let previousID = selected
        let previousState = devices.first(where: { $0.id == previousID })?.status.state
        if devices != list { devices = list }
        if !deviceListLoaded { deviceListLoaded = true }
        for device in list where device.running || device.stopped { bootProgress.removeValue(forKey: device.id) }
        if !list.contains(where: { $0.id == selected }), selected != nil || !selectionCleared {
            if let next = list.first?.id { select(next) }
            else {
                let deliberatelyCleared = selectionCleared
                setDeviceSelection(nil)
                selectionCleared = deliberatelyCleared
            }
        } else if let id = selected,
                  details == nil || previousState != list.first(where: { $0.id == id })?.status.state {
            load(id)
        }
        syncPlayerLaunchStates()
    }

    /// A successful command reply alone does not prove deletion. Read back the
    /// authoritative list before reporting success or changing the selection.
    private func verifyDeletion(_ id: String, then: (() -> Void)?) {
        let session = bridgeSession
        call("device.list") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                guard session == self.bridgeSession else { return }
                self.busy.remove(id); self.refreshJobs()
                self.showError(self.text("无法确认设备已删除：", "Could not verify device deletion: ") + self.readable(error))
            case .success(let value):
                self.decodeDevicesInBackground(value) { [weak self] decoded in
                    guard let self, session == self.bridgeSession else { return }
                    self.busy.remove(id); self.refreshJobs()
                    switch decoded {
                    case .success(let list):
                        self.refreshGeneration += 1 // Retire any older list requests.
                        self.applyDeviceList(list)
                        guard !list.contains(where: { $0.id == id }) else {
                            self.showError(self.text("删除未生效，设备仍在列表中。请重试或检查后台日志。",
                                                     "Deletion did not take effect. The device is still listed. Retry or check the background logs."))
                            return
                        }
                        self.showToast(self.text("设备已删除", "Device deleted"))
                        then?()
                    case .failure(let error):
                        self.showError(self.text("无法确认设备已删除：", "Could not verify device deletion: ") + self.readable(error))
                    }
                }
            }
        }
    }
    func setDeviceSelection(_ id: String?) {
        guard let id else {
            selectionCleared = true
            detailGeneration += 1
            appListLoader.cancel()
            pendingSheetAfterDetails = nil
            selected = nil; details = nil; apps = []
            appsLoading = false; appsError = nil; appsNote = nil
            return
        }
        if selected != id { select(id) }
    }
    func select(_ id:String) { selectionCleared = false; selected = id; details = nil; apps = []; appsNote = nil; load(id) }
    func load(_ id:String) {
        detailGeneration += 1; let generation = detailGeneration
        call("device.details", ["device":id]) { [weak self] result in
            guard let self, self.selected == id, self.detailGeneration == generation else { return }
            do {
                self.details = try self.decode(result.get(), as:Details.self)
                if let pending = self.pendingSheetAfterDetails, self.details?.device.id == id {
                    self.pendingSheetAfterDetails = nil
                    self.sheet = pending
                }
            } catch { self.notice = error.localizedDescription }
        }
        appListLoader.cancel()
        appsError = nil
        appsNote = nil
        guard devices.first(where:{$0.id == id})?.running == true else { apps = []; appsLoading = false; return }
        appsLoading = true
        appListLoader.load(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.selected == id && self.detailGeneration == generation && self.devices.first(where:{$0.id == id})?.running == true
        }, request: { [weak self] done in
            guard let self else { return }
            self.call("app.list", ["device":id]) { result in
                done(result.flatMap { value in Result { try self.decode(value, as:AppList.self) } })
            }
        }, onRetry: { }, completion: { [weak self] result in
            guard let self else { return }
            self.appsLoading = false
            switch result {
            case .success(let list):
                self.apps = list.apps
                self.appsError = nil
                if list.apps.isEmpty {
                    self.appsNote = nil
                } else if list.metadata_available == false {
                    self.appsNote = self.text("未找到 Android 构建工具，暂以包名显示应用。", "App names and icons need Android build tools; package names are shown.")
                } else if list.incomplete_metadata == true {
                    self.appsNote = self.text("部分应用名称或图标暂不可用。", "Some app names or icons are unavailable.")
                } else { self.appsNote = nil }
            case .failure(let error):
                self.appsError = self.text("无法读取应用列表：", "Could not load apps: ") + error.localizedDescription
            }
        })
    }
    func operation(_ method:String, id:String, params:[String:Any] = [:], then: (() -> Void)? = nil) {
        guard !busy.contains(id) else { return }
        busy.insert(id); var args = params; args["device"] = id
        call(method,args,onProgress:{ [weak self] _, job, _ in
            if let job { self?.ownJobs.insert(job) }
        }) { [weak self] result in
            guard let self else { return }
            if method == "device.delete", case .success = result {
                self.verifyDeletion(id, then: then)
                return
            }
            self.busy.remove(id)
            switch result {
            case .success:
                self.showToast(self.text("操作完成", "Completed"))
                self.refresh(); self.refreshJobs()
                if self.selected == id { self.load(id) }
                then?()
            case .failure(let error):
                let message = error.localizedDescription
                if method == "file.install", message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                    self.showError(self.text("安装失败：设备空间不足。可释放空间，或新建更大容量的设备。", "Installation failed: the device is out of storage. Free some space or create a larger device."))
                } else if method == "file.install", let apk = args["apk"] as? String, Self.isSignatureMismatch(message) {
                    self.promptReinstall(device:id, apkPath:apk)
                } else { self.showError(self.readable(error)) }
                self.refresh(); self.refreshJobs()
            }
        }
    }
    static func isSignatureMismatch(_ message: String) -> Bool {
        message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE")
            || message.contains("INSTALL_FAILED_SHARED_USER_INCOMPATIBLE")
            || message.contains("signatures do not match")
    }
    func setupFullRoot(_ id:String, name:String) {
        guard !busy.contains(id) else { return }
        busy.insert(id); fullRoot[id] = .running
        rootPresentation = RootPresentation(id:id,name:name)
        call("root.set",["device":id,"mode":"magisk"],onProgress:{ [weak self] _, job, _ in
            if let job { self?.ownJobs.insert(job) }
        }) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            switch result {
            case .success(let value):
                if let object = value as? [String:Any], let verification = object["verification"] as? [String:Any], verification["ok"] as? Bool == true {
                    self.fullRoot[id] = .verified(object["magisk_version"] as? String ?? "")
                    self.showToast(self.text("完整 Root 验证成功。", "Full root verified."))
                } else {
                    let reason = self.text("未收到成功的 Root 验证结果。", "Root verification did not report success.")
                    self.fullRoot[id] = .failed(reason)
                    self.showError(reason)
                }
            case .failure(let error):
                let message = self.readable(error)
                self.fullRoot[id] = .failed(message)
                self.showError(message)
            }
            self.refresh(); self.refreshJobs()
            if self.selected == id { self.load(id) }
        }
    }
    /// Opens (or reveals) the device window. A device that is still starting
    /// opens in its booting state and a stopped one in its stopped state, with
    /// the window's Start button wired back to `start(_:)` (parity with the
    /// Slint device tab, which keeps the screen visible in every state).
    func openGame(_ id:String, launch: PlayerLaunchState? = nil) {
        if let existing = players[id], let window = existing.window {
            if GameReconnectPolicy.permits(disconnected:existing.transport.connectionEnded,
                                           editing:existing.transport.mapping.editing,
                                           recording:existing.transport.recording != .idle,
                                           recordingUnknown:existing.transport.recordingStateUnknown) {
                window.performClose(nil)
                guard players[id] == nil else { return }
            } else {
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); return
            }
        }
        guard openingPlayers.insert(id).inserted else { return }
        call("device.details", ["device":id]) { [weak self] result in
            guard let self else { return }
            self.openingPlayers.remove(id)
            do {
                let details = try self.decode(result.get(), as:Details.self)
                guard let width = Int(details.config["hw.lcd.width"] ?? ""),
                      let height = Int(details.config["hw.lcd.height"] ?? "") else {
                    self.showError(self.text("设备尚未就绪", "Device is not ready")); return
                }
                guard let dataDirectory = self.dataDirectory else {
                    self.showError(self.text("无法读取数据目录", "Cannot read the data directory")); return
                }
                let quality: UInt8
                do { quality = try WindowQualityStore(dataDirectory:dataDirectory,device:id).load() }
                catch { self.showError(self.readable(error)); return }
                let launchState = launch ?? self.playerLaunchState(for: details.device)
                self.appliedLaunch[id] = launchState
                let player = GameWindowController()
                player.transport.language = self.language
                player.transport.onReconnect = { [weak self] in self?.openGame(id) }
                player.transport.onAdvanced = { [weak self] in self?.openAdvanced(id, name:details.device.name) }
                player.onWarning = { [weak self] message in self?.showError(message) }
                player.onClose = { [weak self] in
                    self?.players.removeValue(forKey: id)
                    self?.appliedLaunch.removeValue(forKey: id)
                    self?.onPlayersChanged?()
                }
                self.players[id] = player
                player.open(device:id,width:width,height:height,executable:self.bridgeExecutable,displayName:details.device.name,quality:quality,dataDirectory:dataDirectory,
                            launch: launchState,
                            onStartDevice: { [weak self] in self?.start(id) })
                self.onPlayersChanged?()
            } catch { self.showError(self.readable(error)) }
        }
    }
    func openAdvanced(_ id:String, name:String, root:Bool = false) {
        if let existing = advancedWindows[id], let window = existing.window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); return
        }
        let controller = AdvancedToolsWindowController(model:self, id:id, name:name, root:root)
        controller.onClose = { [weak self] in self?.advancedWindows.removeValue(forKey:id) }
        advancedWindows[id] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func reconnectAfterRestart(_ id:String) {
        guard let player = players[id], GameReconnectPolicy.permits(disconnected:player.transport.connectionEnded,
                editing:player.transport.mapping.editing,recording:player.transport.recording != .idle,
                recordingUnknown:player.transport.recordingStateUnknown) else { return }
        openGame(id)
    }
    func isPlayerOpen(_ id:String) -> Bool { players[id] != nil }
    var hasPlayers: Bool { !players.isEmpty }
    var hasActiveRecording: Bool { players.values.contains { $0.transport.recording != .idle } }
    func closePlayers() { for player in Array(players.values) { player.window?.performClose(nil) } }
    func closePlayerForStop(_ id:String) -> Bool {
        if recording.contains(id) || players[id]?.transport.recording != .idle && players[id] != nil {
            showError(text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first.")); return false
        }
        players[id]?.window?.performClose(nil)
        if players[id] != nil { showError(text("请先关闭游戏窗口。", "Close the game window first.")); return false }
        return true
    }
    func stop(_ id:String) {
        guard closePlayerForStop(id) else { return }
        operation("device.stop",id:id)
    }
    func start(_ id:String, coldBoot:Bool = false) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        guard !busy.contains(id) else { return }
        if device.running { openGame(id); return }
        busy.insert(id)
        let booting = PlayerLaunchState.booting(progress: bootProgressFraction(for: id),
                                                message: self.text("正在启动设备…", "Starting the device…"))
        if players[id] != nil {
            applyLaunchState(booting, to: id)
        } else {
            openGame(id, launch: booting)
        }
        var params: [String:Any] = ["device": id]
        if coldBoot { params["cold_boot"] = true }
        call("device.start", params, onProgress: { [weak self] message, job, fraction in
            guard let self else { return }
            if let job { self.ownJobs.insert(job) }
            let text = message.isEmpty ? self.text("正在启动设备…", "Starting the device…")
                                       : OperationMessages.progress(message, language: self.language)
            self.applyLaunchState(.booting(progress: fraction, message: text), to: id)
        }) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            switch result {
            case .success:
                self.applyLaunchState(.running, to: id)
                self.showToast(self.text("设备已启动。", "Device started."))
            case .failure(let error):
                let reason = self.readable(error)
                self.applyLaunchState(.stopped(reason: reason), to: id)
                self.showError(reason)
            }
            self.refresh(); self.refreshJobs()
            if self.selected == id { self.load(id) }
        }
    }
    func restart(_ id:String) {
        guard closePlayerForStop(id) else { return }
        operation("device.stop",id:id) { [weak self] in self?.start(id) }
    }
    func setPreference(_ field:String, _ value:Int) {
        call("center.prefs.set",[field:value]) { [weak self] result in
            switch result {
            case .success:
                if field == "language" { self?.language = value; self?.players.values.forEach { $0.transport.language = value } }
                if field == "appearance" { self?.appearance = value }
            case .failure(let error): self?.showError(self?.readable(error) ?? error.localizedDescription)
            }
        }
    }
    func chooseFile(device:String, apk:Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if apk, let type = UTType(filenameExtension:"apk") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation(apk ? "file.install" : "file.push",id:device,params:apk ? ["apk":url.path,"replace":true] : ["local":url.path])
    }
    func screenshot(device:String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = text("Jidr 截图.png", "Jidr screenshot.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation("media.screenshot",id:device,params:["path":url.path])
    }
    func openScreenshotFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Jidr",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            if !NSWorkspace.shared.open(folder) { showError(text("无法打开截图目录。", "Cannot open the screenshots folder.")) }
        } catch { showError(error) }
    }
    func toggleRecording(device:String) {
        if recording.contains(device) {
            call("media.record_stop",["device":device]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.showToast(self.text("正在保存录屏…", "Saving recording…"))
                case .failure(let error): self.showError(self.readable(error))
                }
            }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = text("Jidr 录屏.mp4", "Jidr recording.mp4")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath:url.path) else { showError(text("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name.")); return }
        recording.insert(device); showToast(text("正在启动录屏…", "Starting recording…"))
        call("media.record",["device":device,"path":url.path]) { [weak self] result in
            guard let self else { return }; self.recording.remove(device)
            switch result {
            case .success: self.showToast(self.text("录屏已保存", "Recording saved"))
            case .failure(let error): self.showError(self.readable(error))
            }
        }
    }
    func launch(_ app:AndroidApp, device:String) {
        openGame(device)
        call("app.launch", ["device":device,"package":app.package]) { [weak self] result in
            if case .failure(let error) = result { self?.showError(self?.readable(error) ?? error.localizedDescription) }
        }
    }
    func close() {
        paletteWindow?.close(); paletteWindow = nil
        taskPanel?.close(); taskPanel = nil
        settingsWindow?.close(); settingsWindow = nil
        stopping = true
        stopHeartbeat()
        jobsTimer?.invalidate(); jobsTimer = nil
        toastDismissWork?.cancel(); toastDismissWork = nil
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        try? input.fileHandleForWriting.close()
    }
}
