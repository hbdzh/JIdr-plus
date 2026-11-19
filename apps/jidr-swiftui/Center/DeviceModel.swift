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
    var profileLabel: String { DevicePresentation.profile(profile) }
    var androidVersion: String {
        let known = [28:"9",29:"10",30:"11",31:"12",32:"12L",33:"13",34:"14",35:"15",36:"16"]
        return known[image.api].map { "Android \($0) · API \(image.api)" } ?? "Android API \(image.api)"
    }
    var androidVersionShort: String {
        let known = [28:"9",29:"10",30:"11",31:"12",32:"12L",33:"13",34:"14",35:"15",36:"16"]
        return known[image.api].map { "Android \($0)" } ?? "Android API \(image.api)"
    }
    /// Image tag as users read it (same mapping as the Slint launcher).
    var imageLabel: String { Self.imageTagLabel(image.tag) }
    static func imageTagLabel(_ tag: String) -> String {
        DevicePresentation.imageTag(tag)
    }
}
struct Details: Decodable {
    let device: Device
    let config: [String:String]
    let disk_usage: UInt64?
}
struct DeviceHardware: Equatable {
    let width: String
    let height: String
    let memory: String
    let cores: String
    let density: String

    var memoryGB: String {
        guard let megabytes = Int(memory) else { return "— GB" }
        let value = String(format: "%.3f", Double(megabytes) / 1024)
        let trimmed = value.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return "\(trimmed) GB"
    }

    init(config: [String: String]) {
        func value(_ key: String) -> String {
            guard let raw = config[key], let number = Int(raw), number > 0 else { return "—" }
            return String(number)
        }
        width = value("hw.lcd.width")
        height = value("hw.lcd.height")
        memory = value("hw.ramSize")
        cores = value("hw.cpu.ncore")
        density = value("hw.lcd.density")
    }

    func summary(language: Int) -> String {
        let cpu = language == 0 ? "\(cores) cores" : "\(cores) 核"
        return "\(width) × \(height) · \(memoryGB) · \(cpu) · \(density) DPI"
    }

    func gridSummary(language: Int) -> String {
        let cpu = language == 0 ? "\(cores) cores" : "\(cores) 核"
        return "\(width) × \(height) · \(density) DPI\n\(memoryGB) · \(cpu)"
    }
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
    case folderSync
    case edit
    case imageManagement
    var id: String { rawValue }
}

private enum CenterManagedPanel: Equatable {
    case palette, tasks
    case device(CenterSheet)
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
struct StorageEstimateInfo: Decodable {
    let source_data: String
    let destination: String
    let source_bytes: UInt64
    let required_bytes: UInt64
    let available_bytes: UInt64
}

struct StorageMigrationInfo: Decodable {
    let root: String
    let data: String
    let cache: String
    let logs: String
    let previous_data: String
    let files: UInt64
    let bytes: UInt64
    let qcow_disks: Int
    let source_cleaned: Bool?
    let cleanup_error: String?
}

struct CenterMessageError: LocalizedError {
    let message: String
    var code: String? = nil
    var data: [String: Any]? = nil
    var errorDescription: String? { message }
    var isQuickBootSaveFailure: Bool { data?["operation"] as? String == "quick_boot_save" }
}

/// Per-bridge partial-line buffer; owned by the serial parse queue after start.
private final class ReadBuffer {
    var data = Data()
}

struct DeviceDeletionTarget: Equatable {
    let id: String
    let name: String
}

final class CenterModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var deviceListLoaded = false
    @Published var gridView = false
    @Published var sidebarVisible = true
    @Published private(set) var showingAllDevices = false
    var isEmptyDeviceLibrary: Bool { deviceListLoaded && devices.isEmpty }
    @Published var selected: String?
    @Published private(set) var deviceThumbnails: [String: CGImage] = [:]
    @Published private(set) var cardHardware: [String: DeviceHardware] = [:]
    private var cardHardwareQueue: [String] = []
    private var cardHardwareInFlight: String?
    private var cardHardwareGeneration: [String: Int] = [:]
    /// Visible list focus used only for keyboard navigation, never as a menu target.
    @Published var keyboardDevice: String?
    var listHasKeyboardFocus = false
    @Published var details: Details?
    @Published var detailsLoading = false
    @Published var detailsError: String?
    var detailsReadTimeout: TimeInterval = 8
    private var readDeadlines: [Int: DispatchWorkItem] = [:]
    @Published var apps: [AndroidApp] = []
    @Published var appsLoading = false
    @Published var appsError: String?
    @Published var appsNote: String?
    private let appListLoader = AppListLoader<AppList>()
    @Published var notice = ""
    @Published var busy = Set<String>()
    private var pendingWindowStops = Set<String>()
    private var stoppingDevices = Set<String>()
    private var startingDevices = Set<String>()
    private var startJobs: [String: String] = [:]
    private var startCancelRequested = Set<String>()
    @Published var recording = Set<String>()
    @Published private var requestProgress: [Int:String] = [:]
    @Published private var bootProgress: [String:Double] = [:]
    @Published var language = 1
    @Published var appearance = 0
    @Published var recordAudio = true
    @Published private(set) var migratingStorage = false
    weak var centerWindow: NSWindow?
    @Published var deviceQuery = "" {
        didSet {
            if oldValue != deviceQuery { searchDeviceApps(); reconcileSearchSelection() }
        }
    }
    @Published private(set) var appSearchMatches: [String: String] = [:]
    private var appSearchGeneration = 0
    private var appSearchWork: DispatchWorkItem?
    var filteredDevices: [Device] {
        devices.filter { deviceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(deviceQuery) || appSearchMatches[$0.id] != nil }
    }
    private func searchDeviceApps() {
        appSearchGeneration += 1
        let generation = appSearchGeneration
        let query = deviceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        appSearchWork?.cancel()
        appSearchMatches = [:]
        guard !query.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.appSearchGeneration == generation else { return }
            for device in self.devices where device.running {
                self.call("app.list", ["device": device.id]) { [weak self] result in
                    guard let self, self.appSearchGeneration == generation,
                          self.devices.contains(where: { $0.id == device.id && $0.running }),
                          let value = try? result.get(), let apps = try? self.decode(value, as: AppList.self),
                          let match = apps.apps.first(where: { $0.name.localizedCaseInsensitiveContains(query) || $0.package.localizedCaseInsensitiveContains(query) }) else { return }
                    self.appSearchMatches[device.id] = match.name
                }
            }
        }
        appSearchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func reconcileSearchSelection() {
        if let id = selected, !filteredDevices.contains(where: { $0.id == id }) {
            setDeviceSelection(nil)
        }
    }
    @Published var settingsCategory = 0
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var deviceSheetPanel: DeviceSheetPanelController?
    private var pendingSDKPresentation = false
    private var pendingSettingsPresentation = false
    private var sdkSheetIsClosing = false
    private var pendingPanelAfterSDK: CenterManagedPanel?
    private lazy var panelCoordinator = PanelCoordinator<CenterManagedPanel>(
        present: { [weak self] panel in self?.showManagedPanel(panel) },
        dismiss: { [weak self] panel, completion in
            guard let self else { completion(); return }
            self.hideManagedPanel(panel, completion: completion)
        },
        didDismiss: { [weak self] panel in self?.managedPanelDidClose(panel) }
    )
    private(set) var taskPanel: TaskPanelController?
    private(set) var paletteWindow: PaletteWindowController?
    @Published var tileURL = ""
    @Published var dataDirectory: String?
    @Published var rootPresentation: RootPresentation?
    @Published var fullRoot: [String:FullRootState] = [:]
    @Published var onboardingInstallForegroundRequired = false
    @Published var sdkInstalling = false
    @Published var sdkInstallJob: String?
    @Published var sdkCancelPending = false
    @Published var sdkInstallMessage = ""
    @Published var sdkInstallFraction: Double?
    @Published var sdkInstallError: String?
    @Published var sdkInstallSucceeded: Bool?
    private var sdkCancellation = SDKCancellationRequest()

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
                                             "center.about", "center.toolpath.set"]
    private var requestMethods: [Int:String] = [:]

    // Background tasks (daemon jobs).
    @Published private(set) var jobs: [JobInfo] = []
    @Published var jobsError: String?
    private var jobsTimer: Timer?
    private var microphoneSessions: [String: MicrophoneSession] = [:]
    func microphoneSession(for id: String) -> MicrophoneSession {
        if let session = microphoneSessions[id] { return session }
        let session = MicrophoneSession()
        microphoneSessions[id] = session
        return session
    }

    // Transient feedback and overlays.
    @Published var toast: Toast?
    private var toastDismissWork: DispatchWorkItem?
    @Published private(set) var paletteOpen = false
    @Published private(set) var tasksOpen = false
    @Published private(set) var quitReason: String?
    @Published private(set) var sheet: CenterSheet?
    @Published private(set) var snapshotRevisions: [String: UInt64] = [:]
    @Published private(set) var imageInventoryRevision: UInt64 = 0
    @Published var searchFocusRequest = 0
    @Published var deleteTarget: DeviceDeletionTarget?
    var deleteRequested: Bool {
        get { deleteTarget != nil }
        set { if !newValue { deleteTarget = nil } }
    }
    func requestDeletion(_ id: String) {
        guard let device = devices.first(where: { $0.id == id }), device.stopped, !busy.contains(id) else { return }
        deleteTarget = DeviceDeletionTarget(id: id, name: device.name)
    }
    func confirmDeletion(_ target: DeviceDeletionTarget) {
        deleteTarget = nil
        guard let device = devices.first(where: { $0.id == target.id }), device.stopped, !busy.contains(target.id) else {
            showError(text("设备状态已变化，请重新确认删除目标。", "The device state changed. Review the deletion target again."))
            return
        }
        operation("device.delete", id: target.id)
    }
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
    private var deviceToolPanels: [String:DeviceToolsPanelController] = [:]
    private var openingPlayers = Set<String>()
    /// Last launch state handed to a player window, so device refreshes do not
    /// reapply it (reapplying `.running` would reset the window's status).
    var appliedLaunch = [String: PlayerLaunchState]()
    let bridgeExecutable: String
    let centerExecutable: String
    var onPlayersChanged: (() -> Void)?
    let syncHub = SyncHub()
    let syncPanel = SyncPanelCoordinator()
    private var backgroundSyncPlayers = Set<String>()
    private var pendingVisibleSyncPlayers = Set<String>()

    init(center: String, bridge: String) throws {
        bridgeExecutable = bridge; centerExecutable = center
        try startBridge()
        configureSyncHub()
        bootstrapBridge()
    }

    private func configureSyncHub() {
        syncHub.ensureBridge = { [weak self] id in
            guard let self, self.players[id] == nil else { return }
            self.backgroundSyncPlayers.insert(id)
            self.openGame(id, hidden: true)
        }
        syncHub.releaseBackgroundBridge = { [weak self] id in
            guard let self else { return }
            self.backgroundSyncPlayers.remove(id)
            self.pendingVisibleSyncPlayers.remove(id)
            if let player = self.players[id] {
                player.stopDeviceOnClose = false
                player.window?.close()
            }
        }
        syncHub.reportHealth = { [weak self] device, status, counters in
            guard let self else { return }
            var statusObj: [String: Any]
            switch status {
            case .ready: statusObj = ["state": "ready"]
            case .lagging: statusObj = ["state": "lagging"]
            case .detached: statusObj = ["state": "detached"]
            case .error(let message): statusObj = ["state": "error", "message": message]
            }
            self.call("sync.report", [
                "device": device,
                "status": statusObj,
                "counters": ["forwarded": counters.forwarded, "dropped": counters.dropped],
            ]) { _ in }
        }
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
        for id in Array(cardHardware.keys) { refreshCardHardware(id) }
        call("center.prefs.get") { [weak self] result in
            if case .success(let value) = result, let prefs = value as? [String:Any] {
                self?.language = prefs["language"] as? Int ?? 1
                self?.appearance = prefs["appearance"] as? Int ?? 0
                self?.tileURL = prefs["tile_url"] as? String ?? ""
                self?.recordAudio = prefs["record_audio"] as? Bool ?? true
            }
        }
        call("center.paths") { [weak self] result in
            if case .success(let value) = result, let paths = value as? [String:Any] {
                self?.dataDirectory = paths["data"] as? String
            }
        }
        refresh()
        refreshJobs()
        refreshSyncStatus()
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
        for work in readDeadlines.values { work.cancel() }
        readDeadlines.removeAll()
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
        if wasReconnecting { notice = ""; showToast(text("已重新连接到后台服务。", "Reconnected to the background service.")) }
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
        guard connection.isOnline, !stopping, !migratingStorage, !heartbeatPending else { return }
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

    /// The viewport scrolls; every matching entry is keyboard-accessible.
    var paletteResultCount: Int { paletteFiltered.count }

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
        let readOnly = ["host.budget", "device.list", "device.details", "app.list", "app.inspect", "image.list", "image.inventory", "profile.list", "snapshot.list", "sdk.status", "sdk.license_details", "settings.get", "cache.list", "center.about", "center.paths", "center.prefs.get", "center.quit", "center.storage.estimate", "battery.get", "gps.get", "network.get", "network.proxy.get", "network.shaping.get", "identity.get", "file.sync.list", "input.gamepad.list", "input.gamepad.get", "sensor.get", "logcat.dump", "root.cacert.list", "device.props.get", "dev.get", "clipboard.get", "jobs.list", "jobs.get", "daemon.status"]
        if !readOnly.contains(method) { mutations.insert(id) }
        if method == "device.details" || method == "host.budget" {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let completion = self.callbacks.removeValue(forKey: id) else { return }
                self.readDeadlines.removeValue(forKey: id)
                self.progressCallbacks.removeValue(forKey: id)
                self.requestMethods.removeValue(forKey: id)
                self.requestDevices.removeValue(forKey: id)
                let message = method == "host.budget"
                    ? self.text("读取内存预算超时，请重试。", "Loading the memory budget timed out. Try again.")
                    : self.text("读取设备详情超时，请重试。", "Loading device details timed out. Try again.")
                completion(.failure(CenterMessageError(message: message)))
            }
            readDeadlines[id] = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + detailsReadTimeout, execute: timeout)
        }
        do { try input.fileHandleForWriting.write(contentsOf:data + Data([10])) }
        catch { readDeadlines.removeValue(forKey: id)?.cancel(); requestMethods.removeValue(forKey: id); callbacks.removeValue(forKey:id); progressCallbacks.removeValue(forKey:id); mutations.remove(id); requestDevices.removeValue(forKey:id); done(.failure(error)) }
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
            if let event = event["event"] as? [String:Any], let topic = event["topic"] as? String {
                if topic == "sync.state" {
                    let data = event["data"] as? [String:Any]
                    applySyncStateData(data?["session"])
                    return
                }
                if topic == "sync.follower_error" {
                    if let data = event["data"] as? [String:Any] {
                        let name = data["name"] as? String ?? (data["device"] as? String ?? "")
                        let message = data["message"] as? String ?? ""
                        let detail = message.isEmpty ? name : "\(name): \(message)"
                        syncHub.recordError(detail)
                        showError(text("同步器错误：\(detail)", "Synchronizer error: \(detail)"))
                    }
                    return
                }
            }
            if let event = event["event"] as? [String:Any], let topic = event["topic"] as? String,
               let data = event["data"] as? [String:Any], let device = data["device"] as? String {
                if topic == "device.updated", cardHardware[device] != nil || cardHardwareInFlight == device || cardHardwareQueue.contains(device) {
                    refreshCardHardware(device)
                }
                if topic == "device.boot", let progress = data["progress"] as? Double {
                    // Boot progress is a cheap, high-frequency signal: update it
                    // immediately but never trigger a full list refresh for it.
                    let value = min(1, max(0, progress))
                    if bootProgress[device] != value { bootProgress[device] = value }
                    if !pendingWindowStops.contains(device), !stoppingDevices.contains(device),
                       startingDevices.contains(device) || devices.first(where: { $0.id == device })?.status.state == "booting"
                           || devices.first(where: { $0.id == device })?.status.state == "starting" {
                        applyLaunchState(.booting(progress: value, message: self.progress(for: device) ?? ""), to: device)
                    }
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
            let hasProgressHandler = progressCallbacks[id] != nil
            progressCallbacks[id]?(event["message"] as? String ?? "", event["job"] as? String, event["progress"] as? Double)
            if let message = event["message"] as? String, !message.isEmpty {
                if requestDevices[id] != nil { requestProgress[id] = message }
                else if !hasProgressHandler { notice = OperationMessages.progress(message,language:language) }
            }
            return
        }
        requestProgress.removeValue(forKey:id)
        progressCallbacks.removeValue(forKey:id)
        requestDevices.removeValue(forKey:id)
        readDeadlines.removeValue(forKey: id)?.cancel()
        requestMethods.removeValue(forKey:id)
        mutations.remove(id)
        guard let completion = callbacks.removeValue(forKey:id) else { return }
        if kind == "error" {
            let message = event["message"] as? String ?? "操作失败"
            completion(.failure(CenterMessageError(message: message, code: event["code"] as? String, data: event["data"] as? [String: Any])))
            if let method, !localMethods.contains(method) { bridgeAnswered() }
            if !migratingStorage, ConnectionHealth.looksDisconnected(message) { connectionLost() }
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

    private func showManagedPanel(_ panel: CenterManagedPanel) {
        switch panel {
        case .palette:
            paletteQuery = ""
            paletteSelection = 0
            paletteOpen = true
            if paletteWindow == nil { paletteWindow = PaletteWindowController(model: self) }
            paletteWindow?.present(relativeTo: centerWindow ?? NSApp.mainWindow)
        case .tasks:
            tasksOpen = true
            if taskPanel == nil { taskPanel = TaskPanelController(model: self) }
            taskPanel?.showWindow(nil)
            startJobsTimer()
            refreshJobs()
        case .device(let kind):
            guard let parent = centerWindow else { panelCoordinator.request(nil); return }
            sheet = kind
            deviceSheetPanel = DeviceSheetPanelController(model: self, kind: kind, parent: parent)
        }
    }

    private func hideManagedPanel(_ panel: CenterManagedPanel, completion: @escaping () -> Void) {
        switch panel {
        case .palette:
            if let paletteWindow { paletteWindow.dismissPanel(completion: completion) } else { completion() }
        case .tasks:
            if let taskPanel { taskPanel.dismissPanel(completion: completion) } else { completion() }
        case .device:
            if let deviceSheetPanel { deviceSheetPanel.dismissPanel(completion: completion) } else { completion() }
        }
    }

    private func managedPanelDidClose(_ panel: CenterManagedPanel) {
        switch panel {
        case .palette: paletteOpen = false
        case .tasks:
            tasksOpen = false
            if panelCoordinator.desired != .tasks { quitReason = nil }
            if !hasActiveJobs { stopJobsTimer() }
        case .device(let kind):
            let deviceID = deviceSheetPanel?.deviceID
            deviceSheetPanel = nil
            sheet = nil
            if kind == .snapshots, let deviceID {
                snapshotRevisions[deviceID, default: 0] &+= 1
            }
            if kind == .imageManagement { imageInventoryRevision &+= 1 }
        }
        if panelCoordinator.desired == nil && sheet == nil && !pendingSDKPresentation && !pendingSettingsPresentation {
            switch panel {
            case .palette, .tasks: searchFocusRequest += 1
            case .device: break
            }
        }
    }

    private func requestManagedPanel(_ panel: CenterManagedPanel) {
        // Never discard a device form as a side effect of opening another
        // surface. It must be explicitly saved or cancelled first.
        if case .device = panelCoordinator.active, panelCoordinator.active != panel { return }
        pendingSDKPresentation = false
        pendingSettingsPresentation = false
        if sheet == .setupSDK || sdkSheetIsClosing {
            pendingPanelAfterSDK = panel
            if sheet == .setupSDK { dismissSDKSheet() }
        } else {
            panelCoordinator.request(panel)
        }
    }

    func dismissSDKSheet() {
        if sheet == .setupSDK {
            sdkSheetIsClosing = true
            sheet = nil
        }
    }

    func sdkSheetDidDismiss() {
        sdkSheetIsClosing = false
        if pendingSDKPresentation {
            pendingSDKPresentation = false
            pendingPanelAfterSDK = nil
            sheet = .setupSDK
        } else if let pending = pendingPanelAfterSDK {
            pendingPanelAfterSDK = nil
            panelCoordinator.request(pending)
        }
    }

    func dismissDevicePanel(after completion: @escaping () -> Void = {}) {
        guard case .device = panelCoordinator.active else { completion(); return }
        panelCoordinator.dismissCurrent(after: completion)
    }

    func openPalette() {
        guard !onboardingInstallForegroundRequired else { showOnboardingInstallBlocker(); return }
        requestManagedPanel(.palette)
    }
    func togglePalette() {
        if panelCoordinator.desired == .palette { hidePalette() } else { openPalette() }
    }
    func hidePalette() {
        guard panelCoordinator.desired == .palette else { return }
        panelCoordinator.request(nil)
    }
    func closeOverlay() {
        switch panelCoordinator.desired {
        case .palette, .tasks: panelCoordinator.request(nil)
        default: break
        }
    }
    func dismissOverlay() { closeOverlay() }
    func openTasks() {
        guard !onboardingInstallForegroundRequired else { showOnboardingInstallBlocker(); return }
        if !tasksOpen { quitReason = nil }
        requestManagedPanel(.tasks)
    }
    private func setTasksOpen(_ open: Bool) {
        if open { requestManagedPanel(.tasks) }
        else if panelCoordinator.desired == .tasks { panelCoordinator.request(nil) }
        if !open && hasActiveJobs { startJobsTimer() }
    }
    func taskPanelDidClose() { setTasksOpen(false) }
    func showOnboardingInstallBlocker() {
        showToast(text("请等待安装完成，或先取消安装。", "Wait for installation to finish, or cancel it first."))
    }
    func present(_ sheet: CenterSheet) {
        guard !onboardingInstallForegroundRequired else { showOnboardingInstallBlocker(); return }
        if sheet == .newDevice && isEmptyDeviceLibrary { return }
        if case .device = panelCoordinator.active { return }
        if sheet == .settings {
            guard self.sheet != .setupSDK && !sdkSheetIsClosing else { return }
            pendingSDKPresentation = false
            pendingSettingsPresentation = true
            panelCoordinator.dismissCurrent { [weak self] in
                guard let self, self.pendingSettingsPresentation else { return }
                self.pendingSettingsPresentation = false
                if self.settingsWindow == nil { self.settingsWindow = SettingsWindowController(model: self) }
                self.settingsWindow?.showWindow(nil)
                self.settingsWindow?.window?.makeKeyAndOrderFront(nil)
            }
        } else if sheet == .setupSDK {
            pendingSettingsPresentation = false
            if sdkSheetIsClosing {
                pendingSDKPresentation = true
                pendingPanelAfterSDK = nil
                return
            }
            guard self.sheet != .setupSDK else { return }
            pendingSDKPresentation = true
            panelCoordinator.dismissCurrent { [weak self] in
                guard let self, self.pendingSDKPresentation else { return }
                self.pendingSDKPresentation = false
                self.sheet = .setupSDK
            }
        } else {
            requestManagedPanel(.device(sheet))
        }
    }

    /// Opens a sheet that needs freshly loaded `device.details`.
    func presentDeviceSheet(_ sheet: CenterSheet, device: String) {
        hidePalette()
        if selected != device || details?.device.id != device {
            select(device)
            pendingSheetAfterDetails = sheet
        } else { present(sheet) }
    }

    // MARK: - Shortcuts

    /// Handles a key-down from the local event monitor; false lets the event
    /// reach the responder chain (text editing and everything unclaimed).
    func handleShortcutEvent(_ event: NSEvent) -> Bool {
        // A sheet owns its keyboard while it is up (its own Esc/Return before
        // the center's globals); do not steal keys across windows.
        guard sheet == nil else { return false }
        if !paletteOpen, !tasksOpen, (listHasKeyboardFocus || Self.isDeviceListFocused(event.window)) {
            if event.keyCode == 48 { keyboardDevice = nil }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                let ids = filteredDevices.map(\.id)
                if event.keyCode == 125 || event.keyCode == 126, !ids.isEmpty {
                    moveKeyboardDevice(by: event.keyCode == 125 ? 1 : -1)
                    return true
                }
                if (event.keyCode == 36 || event.keyCode == 76), let id = keyboardDevice, ids.contains(id) {
                    focusOrOpenDeviceWindow(id)
                    return true
                }
            }
        }
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
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: -1, count: paletteResultCount)
        case .paletteDown:
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: 1, count: paletteResultCount)
        case .paletteConfirm:
            let entries = paletteFiltered
            guard paletteSelection >= 0, paletteSelection < entries.count else { return false }
            let entry = entries[paletteSelection]
            closeOverlay()
            runPaletteAction(entry.action)
        }
        return true
    }

    func moveKeyboardDevice(by delta: Int) {
        let ids = filteredDevices.map(\.id)
        guard !ids.isEmpty else { return }
        let current = keyboardDevice.flatMap { ids.firstIndex(of: $0) }
        let index = current.map { max(0, min(ids.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : ids.count - 1)
        keyboardDevice = ids[index]
    }

    private static func isDeviceListFocused(_ window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current.identifier?.rawValue == "jidr-device-list" { return true }
            view = current.superview
        }
        return false
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
        if migratingStorage { return text("正在迁移设备数据，请等待完成。", "Migrating device data; wait for it to finish.") }
        if hasActiveRecording || !recording.isEmpty { return text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first.") }
        if hasPlayers { return self.text("请先关闭游戏窗口。", "Close the game window first.") }
        return quitWorkBlockReason
    }

    /// A stop already acknowledged by the daemon continues even if this
    /// client disconnects. Never leave other work or running devices behind.
    var canQuitWhileStopping: Bool {
        let methods = mutations.compactMap { requestMethods[$0] }
        return Self.canLeaveStopsRunning(
            stopping: stoppingDevices,
            deviceStates: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.status.state) }),
            mutationMethods: methods,
            mutationCount: mutations.count,
            hasOtherWork: hasActiveRecording || !recording.isEmpty || hasPlayers || hasActiveJobs || !pendingWindowStops.isEmpty
        )
    }

    static func canLeaveStopsRunning(stopping: Set<String>, deviceStates: [String: String],
                                     mutationMethods: [String], mutationCount: Int, hasOtherWork: Bool) -> Bool {
        guard !hasOtherWork, deviceStates.values.contains("stopping"), mutationCount == stopping.count,
              mutationMethods.count == mutationCount,
              mutationMethods.allSatisfy({ $0 == "device.stop" }),
              stopping.allSatisfy({ deviceStates[$0] == "stopping" }) else { return false }
        return deviceStates.values.allSatisfy { state in
            ["stopped", "crashed", "hibernated", "stopping"].contains(state)
        }
    }

    var quitWorkBlockReason: String? {
        if hasActiveRecording || !recording.isEmpty { return text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first.") }
        let active = activeJobs.count
        if active > 0 {
            return self.text("还有 \(active) 个后台任务正在运行。取消它们或等待完成后再退出。", "\(active) background task(s) are still running. Cancel them or wait for them to finish before quitting.")
        }
        if hasMutations { return self.text("正在等待当前设备操作完成…", "Waiting for the current device operation to finish…") }
        return nil
    }

    func presentQuitBlocker() {
        quitReason = quitBlockReason ?? self.text("暂时无法退出。", "Cannot quit right now.")
        if let panel = deviceSheetPanel?.window {
            // Keep pending edits intact when the app cannot quit. Present the
            // reason on the active panel instead of replacing that panel.
            if panel.attachedSheet == nil {
                let alert = NSAlert()
                alert.messageText = text("暂时无法退出", "Can't quit yet")
                alert.informativeText = quitReason ?? ""
                alert.addButton(withTitle: text("好", "OK"))
                alert.beginSheetModal(for: panel)
            }
            return
        }
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
        guard !stopping, !migratingStorage, process.isRunning else { return }
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

    func startSDKInstall(_ plan: SDKInstallPlan, onFinish: @escaping (Bool) -> Void = { _ in }) {
        guard !sdkInstalling else { onFinish(false); return }
        sdkInstalling = true; sdkCancelPending = false; sdkCancellation.reset(); sdkInstallJob = nil; sdkInstallError = nil; sdkInstallFraction = nil; sdkInstallSucceeded = nil
        sdkInstallMessage = text("正在准备安装…", "Preparing installation…")
        call(plan.method,plan.parameters,onProgress:{ [weak self] message, job, fraction in
            guard let self else { return }
            if let job {
                self.sdkInstallJob = job; self.ownJobs.insert(job)
                if self.sdkCancelPending { self.sendSDKCancellation(job) }
            }
            if !message.isEmpty { self.sdkInstallMessage = OperationMessages.progress(message,language:self.language) }
            self.sdkInstallFraction = SDKInstallPlan.validProgress(fraction)
        }) { [weak self] result in
            guard let self else { return }
            let cancellationRequested = self.sdkCancelPending
            self.sdkInstalling = false; self.sdkCancelPending = false; self.sdkCancellation.reset(); self.sdkInstallJob = nil
            self.onboardingInstallForegroundRequired = false
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
            onFinish(self.sdkInstallSucceeded == true)
        }
    }
    func cancelSDKInstall() {
        guard sdkInstalling, sdkCancellation.request() else { return }
        sdkCancelPending = true
        if let job = sdkInstallJob { sendSDKCancellation(job) }
    }
    private func sendSDKCancellation(_ job: String) {
        guard sdkInstalling, sdkInstallJob == job, sdkCancellation.takeJob(job) != nil else { return }
        call("jobs.cancel",["job":job]) { [weak self] result in
            guard let self, self.sdkInstalling, self.sdkInstallJob == job, case .failure(let error) = result else { return }
            guard self.sdkCancellation.failed(job: job) else { return }
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
        if stoppingDevices.contains(device) {
            return text("正在安全停止设备，保存状态可能需要几分钟。", "Stopping safely; saving state may take a few minutes.")
        }
        if let value = bootProgress[device], devices.first(where: { $0.id == device })?.running != true {
            return text("正在启动 \(Int(value * 100))%", "Starting \(Int(value * 100))%")
        }
        return requestDevices.filter { $0.value == device }.keys.sorted().reversed().compactMap { requestProgress[$0] }.first.map { OperationMessages.progress($0,language:language) }
    }
    func refresh() {
        guard process.isRunning, !migratingStorage else { return }
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
        let ids = Set(list.map(\.id))
        if cardHardware.keys.contains(where: { !ids.contains($0) }) {
            cardHardware = cardHardware.filter { ids.contains($0.key) }
        }
        cardHardwareQueue.removeAll { !ids.contains($0) }
        let previousID = selected
        let previousState = devices.first(where: { $0.id == previousID })?.status.state
        if devices != list {
            devices = list
            if !deviceQuery.isEmpty { searchDeviceApps() }
        }
        if !deviceListLoaded { deviceListLoaded = true }
        for device in list where device.running || (device.stopped && !startingDevices.contains(device.id)) { bootProgress.removeValue(forKey: device.id) }
        if !list.contains(where: { $0.id == selected }), selected != nil || !selectionCleared {
            if let next = filteredDevices.first?.id { select(next) }
            else {
                let deliberatelyCleared = selectionCleared
                setDeviceSelection(nil)
                selectionCleared = deliberatelyCleared
            }
        } else if let id = selected,
                  (details == nil && detailsError == nil && !detailsLoading) || previousState != list.first(where: { $0.id == id })?.status.state {
            load(id)
        }
        reconcileSearchSelection()
        syncPlayerLaunchStates()
    }

    func loadCardHardware(_ id: String) {
        guard cardHardware[id] == nil, cardHardwareInFlight != id,
              !cardHardwareQueue.contains(id) else { return }
        cardHardwareQueue.append(id)
        loadNextCardHardware()
    }

    func refreshCardHardware(_ id: String) {
        cardHardware[id] = nil
        cardHardwareGeneration[id, default: 0] += 1
        if !cardHardwareQueue.contains(id) { cardHardwareQueue.append(id) }
        loadNextCardHardware()
    }

    private func loadNextCardHardware() {
        guard cardHardwareInFlight == nil, !cardHardwareQueue.isEmpty else { return }
        let id = cardHardwareQueue.removeFirst()
        let generation = cardHardwareGeneration[id, default: 0]
        cardHardwareInFlight = id
        call("device.details", ["device": id]) { [weak self] result in
            guard let self else { return }
            self.cardHardwareInFlight = nil
            if self.cardHardwareGeneration[id, default: 0] == generation,
               self.devices.contains(where: { $0.id == id }),
               case .success(let value) = result,
               let details = try? self.decode(value, as: Details.self), details.device.id == id {
                self.cardHardware[id] = DeviceHardware(config: details.config)
            }
            self.loadNextCardHardware()
        }
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
    func showAllDevices() {
        setDeviceSelection(nil)
        showingAllDevices = true
    }
    func setDeviceSelection(_ id: String?) {
        guard let id else {
            selectionCleared = true
            detailGeneration += 1
            appListLoader.cancel()
            pendingSheetAfterDetails = nil
            selected = nil; details = nil; detailsLoading = false; detailsError = nil; apps = []
            appsLoading = false; appsError = nil; appsNote = nil
            return
        }
        if selected != id { select(id) }
    }
    func select(_ id:String) {
        showingAllDevices = false
        pendingSheetAfterDetails = nil
        if !filteredDevices.contains(where: { $0.id == id }) { deviceQuery = "" }
        selectionCleared = false; selected = id; details = nil; apps = []; appsNote = nil; load(id)
    }
    func retryDetails() { if let id = selected { load(id) } }
    func load(_ id:String) {
        detailGeneration += 1; let generation = detailGeneration
        detailsLoading = true; detailsError = nil
        call("device.details", ["device":id]) { [weak self] result in
            guard let self, self.selected == id, self.detailGeneration == generation else { return }
            self.detailsLoading = false
            do {
                self.details = try self.decode(result.get(), as:Details.self)
                if let pending = self.pendingSheetAfterDetails, self.details?.device.id == id {
                    self.pendingSheetAfterDetails = nil
                    self.present(pending)
                }
            } catch {
                self.details = nil
                self.detailsError = self.readable(error)
            }
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
        if method == "device.stop" { stoppingDevices.insert(id) }
        busy.insert(id); var args = params; args["device"] = id
        call(method,args,onProgress:{ [weak self] _, job, _ in
            if let job { self?.ownJobs.insert(job) }
        }) { [weak self] result in
            guard let self else { return }
            if method == "device.stop" { self.stoppingDevices.remove(id) }
            if method == "device.delete", case .success = result {
                self.verifyDeletion(id, then: then)
                return
            }
            self.busy.remove(id)
            let stopPending = self.pendingWindowStops.contains(id)
            switch result {
            case .success:
                if method == "device.stop", stopPending {
                    self.pendingWindowStops.remove(id)
                    self.finishClosingPlayer(id)
                }
                self.showToast(self.text("操作完成", "Completed"))
                self.refresh(); self.refreshJobs()
                if self.selected == id { self.load(id) }
                if !stopPending { then?() }
            case .failure(let error):
                if method == "device.stop", stopPending {
                    self.pendingWindowStops.remove(id)
                    self.players[id]?.transport.stoppingDevice = false
                }
                let message = error.localizedDescription
                if method == "file.install", message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                    self.showError(self.text("安装失败：设备空间不足。可释放空间，或新建更大容量的设备。", "Installation failed: the device is out of storage. Free some space or create a larger device."))
                } else if method == "file.install", let apk = args["apk"] as? String, Self.isSignatureMismatch(message) {
                    self.promptReinstall(device:id, apkPath:apk)
                } else if method != "device.stop" || (error as? CenterMessageError)?.isQuickBootSaveFailure != true {
                    self.showError(self.readable(error))
                }
                self.refresh(); self.refreshJobs()
            }
            self.drainWindowStop(id)
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
            self.drainWindowStop(id)
        }
    }
    /// Opens (or reveals) the device window. A device that is still starting
    /// opens in its booting state and a stopped one in its stopped state, with
    /// the window's Start button wired back to `start(_:)` (parity with the
    /// Slint device tab, which keeps the screen visible in every state).
    func openGame(_ id:String, launch: PlayerLaunchState? = nil, hidden: Bool = false) {
        guard !pendingWindowStops.contains(id), !stoppingDevices.contains(id) else {
            if hidden { backgroundSyncPlayers.remove(id) }
            return
        }
        if !hidden {
            pendingVisibleSyncPlayers.insert(id)
            backgroundSyncPlayers.remove(id)
        }
        if let existing = players[id], let window = existing.window {
            pendingVisibleSyncPlayers.remove(id)
            if GameReconnectPolicy.permits(disconnected:existing.transport.connectionEnded,
                                           editing:existing.transport.mapping.editing,
                                           recording:existing.transport.recording != .idle,
                                           recordingUnknown:existing.transport.recordingStateUnknown) {
                existing.stopDeviceOnClose = false
                window.performClose(nil)
                if players[id] != nil { existing.stopDeviceOnClose = true }
                guard players[id] == nil else { return }
            } else if !hidden {
                backgroundSyncPlayers.remove(id)
                syncHub.markWindowVisible(for: id)
                existing.transport.setDisplayVisible(true)
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); return
            } else {
                return
            }
        }
        guard openingPlayers.insert(id).inserted else { return }
        call("device.details", ["device":id]) { [weak self] result in
            guard let self else { return }
            self.openingPlayers.remove(id)
            let becameVisible = self.pendingVisibleSyncPlayers.remove(id) != nil
            let effectiveHidden = hidden && !becameVisible
            guard !self.pendingWindowStops.contains(id), !self.stoppingDevices.contains(id) else {
                if effectiveHidden { self.backgroundSyncPlayers.remove(id) }
                return
            }
            if effectiveHidden && !self.backgroundSyncPlayers.contains(id) {
                return
            }
            do {
                let details = try self.decode(result.get(), as:Details.self)
                guard let width = Int(details.config["hw.lcd.width"] ?? ""),
                      let height = Int(details.config["hw.lcd.height"] ?? "") else {
                    if effectiveHidden { self.backgroundSyncPlayers.remove(id) }
                    self.showError(self.text("设备尚未就绪", "Device is not ready")); return
                }
                guard let dataDirectory = self.dataDirectory else {
                    if effectiveHidden { self.backgroundSyncPlayers.remove(id) }
                    self.showError(self.text("无法读取数据目录", "Cannot read the data directory")); return
                }
                let quality: UInt8
                do { quality = try WindowQualityStore(dataDirectory:dataDirectory,device:id).load() }
                catch {
                    if effectiveHidden { self.backgroundSyncPlayers.remove(id) }
                    self.showError(self.readable(error)); return
                }
                let launchState = self.startingDevices.contains(id)
                    ? PlayerLaunchState.booting(progress: self.bootProgressFraction(for: id),
                                                message: self.progress(for: id) ?? self.text("正在启动设备…", "Starting the device…"))
                    : (launch ?? self.playerLaunchState(for: details.device))
                self.appliedLaunch[id] = launchState
                let player = GameWindowController()
                player.chrome.scriptAction = { [weak self] action, completion in
                    self?.performScriptAction(action, completion: completion)
                }
                player.transport.language = self.language
                player.transport.recordAudio = self.recordAudio
                player.transport.onReconnect = { [weak self] in self?.openGame(id) }
                player.transport.onAdvanced = { [weak self] in self?.openAdvanced(id, name:details.device.name) }
                player.transport.onSyncEvent = { [weak self] seq, ev in
                    self?.syncHub.handleLeaderEvent(from: id, seq: seq, event: ev)
                }
                player.transport.onSyncBusy = { [weak self] msg in
                    guard let self else { return }
                    self.showError(msg.isEmpty ? self.text("正在录制或回放脚本的设备不能作为跟随端加入同步。", "Devices recording or playing a script cannot join sync as a follower.") : msg)
                    if let session = self.syncHub.session {
                        if session.leader == id || (session.followers.count == 1 && session.followers.first?.device == id) {
                            self.stopSync()
                        } else if session.followers.contains(where: { $0.device == id }) {
                            self.removeSyncFollower(id)
                        }
                    }
                }
                player.transport.onSyncBridgeLost = { [weak self] in
                    self?.syncHub.markBridgeLost(for: id)
                }
                player.transport.onSyncLeaderRelease = { [weak self] in
                    self?.syncHub.releaseFollowers(from: id)
                }
                player.transport.onSyncDisplaySizeChanged = { [weak self] frameW, frameH in
                    self?.reportSyncDisplayIfNeeded(id: id, frameWidth: frameW, frameHeight: frameH, lcdWidth: width, lcdHeight: height)
                }
                player.transport.onSyncTakeOver = { [weak self] in self?.setSyncLeader(id) }
                player.transport.onOpenSyncPanel = { [weak self] in self?.openSyncPanel() }
                player.transport.onToggleGamepad = { [weak self, weak transport = player.transport] in
                    guard let self, let transport else { return }
                    self.toggleGamepad(for: id, transport: transport)
                }
                if details.device.running {
                    self.call("input.gamepad.get", ["device": id]) { result in
                        if case .success(let value) = result,
                           let dict = value as? [String: Any],
                           let connected = dict["connected"] as? Bool {
                            player.transport.gamepadState = connected ? .connected : .disconnected
                        }
                    }
                }
                player.onWarning = { [weak self] message in self?.showError(message) }
                player.canClose = { [weak self] in
                    guard let self, self.recording.contains(id) else { return true }
                    self.showError(self.text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first."))
                    return false
                }
                player.onStopRequested = { [weak self] in self?.stopAfterWindowClose(id) }
                player.onClose = { [weak self, weak player] in
                    if let frame = player?.transport.lastFrame { self?.rememberThumbnail(frame, device: id) }
                    self?.syncHub.unregisterBridge(for: id)
                    self?.backgroundSyncPlayers.remove(id)
                    self?.players.removeValue(forKey: id)
                    self?.appliedLaunch.removeValue(forKey: id)
                    self?.onPlayersChanged?()
                }
                self.players[id] = player
                player.open(device:id,width:width,height:height,executable:self.bridgeExecutable,displayName:details.device.name,quality:quality,dataDirectory:dataDirectory,
                            launch: launchState, hidden: effectiveHidden,
                            onStartDevice: { [weak self] in self?.start(id) })
                self.syncHub.registerBridge(player.transport, for: id, background: effectiveHidden)
                self.onPlayersChanged?()
            } catch {
                if effectiveHidden { self.backgroundSyncPlayers.remove(id) }
                self.showError(self.readable(error))
            }
        }
    }

    private func toggleGamepad(for id: String, transport: PlayerTransport) {
        switch transport.gamepadState {
        case .disconnected:
            transport.gamepadState = .connecting
            call("input.gamepad.connect", ["device": id], onProgress: { [weak self, weak transport] _, progressMessage, _ in
                guard let self, let transport else { return }
                if let progressMessage, !progressMessage.isEmpty, transport.gamepadState != .connected {
                    transport.gamepadState = .connected
                    transport.onStatus?(self.text("已连接游戏手柄", "Game controller connected"))
                }
            }) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                transport.gamepadState = .disconnected
                if case .failure(let error) = result {
                    let message = OperationMessages.error(error.localizedDescription, language: self.language)
                    transport.onStatus?(message)
                    self.showError(message)
                }
            }
        case .connected:
            transport.gamepadState = .disconnected
            call("input.gamepad.disconnect", ["device": id]) { [weak self, weak transport] result in
                guard let self, let transport else { return }
                switch result {
                case .success:
                    transport.onStatus?(self.text("已断开游戏手柄", "Game controller disconnected"))
                case .failure(let error):
                    transport.gamepadState = .connected
                    let message = OperationMessages.error(error.localizedDescription, language: self.language)
                    transport.onStatus?(message)
                    self.showError(message)
                }
            }
        case .connecting:
            break
        }
    }
    /// A recording list can target any running device, including one whose
    /// player window is not open yet. Wait for its existing bridge to connect.
    private func performScriptAction(_ action: PlayerScriptAction, completion: @escaping (Bool) -> Void) {
        let running = devices.filter { $0.running }
        guard !running.isEmpty else {
            showError(text("请先启动设备。", "Start a device first."))
            completion(false)
            return
        }
        let target: Device
        if let activeLeader = syncHub.session?.leader,
           let leaderDevice = running.first(where: { $0.id == activeLeader }) {
            target = leaderDevice
        } else if running.count == 1 {
            target = running[0]
        } else {
            let alert = NSAlert()
            alert.messageText = text("选择目标设备", "Choose a device")
            alert.informativeText = text("选择要录制或回放操作的设备。", "Choose the device for recording or playback.")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            picker.addItems(withTitles: running.map(\.name))
            alert.accessoryView = picker
            alert.addButton(withTitle: text("继续", "Continue"))
            alert.addButton(withTitle: text("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { completion(false); return }
            target = running[picker.indexOfSelectedItem]
        }
        if players[target.id] == nil || players[target.id]?.transport.connectionEnded == true {
            openGame(target.id)
        }
        func waitForPlayer(_ remaining: Int) {
            guard let device = self.devices.first(where: { $0.id == target.id }), device.running else {
                self.showError(self.text("设备已停止。", "The device has stopped.")); completion(false); return
            }
            if let player = self.players[target.id], player.transport.linkState.isRunning {
                let transport = player.transport
                guard transport.syncRole != .follower else {
                    self.showError(self.text("跟随端同步中无法录制或回放，请在主控端操作。", "Followers cannot record or play scripts during sync. Use the leader device instead."))
                    completion(false); return
                }
                guard transport.scriptRecording == .idle && transport.scriptPlayback == .idle else {
                    self.showError(self.text("目标设备正在录制或回放。", "The selected device is already recording or playing."))
                    completion(false); return
                }
                switch action {
                case .record: transport.scriptRecordStart()
                case .play(let script, let options):
                    guard PlayerScriptPrompts.confirmCompatibility(script, transport: transport) else { completion(false); return }
                    transport.scriptPlayStart(id: script.id, options: options)
                }
                if let window = player.window {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                completion(true)
                return
            }
            guard remaining > 0 else {
                self.showError(self.text("无法连接目标设备。", "Could not connect to the selected device."))
                completion(false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForPlayer(remaining - 1) }
        }
        waitForPlayer(150)
    }

    func openAdvanced(_ id:String, name:String, root:Bool = false, section:Int? = nil,
                      relativeTo requestedOwner:NSWindow? = nil) {
        var owner = requestedOwner ?? NSApp.keyWindow
        if requestedOwner == nil {
            while let parent = owner?.parent { owner = parent }
            while let parent = owner?.sheetParent { owner = parent }
        }
        owner = owner ?? centerWindow
        NSApp.activate(ignoringOtherApps: true)
        if let existing = deviceToolPanels[id] {
            existing.present(relativeTo: owner, root: root, section: section)
        } else {
            let controller = DeviceToolsPanelController(model: self, id: id, name: name, root: root)
            controller.onClose = { [weak self] in self?.deviceToolPanels.removeValue(forKey: id) }
            deviceToolPanels[id] = controller
            controller.present(relativeTo: owner, root: root, section: section)
        }
    }
    func closeDeviceTools(_ id: String) { deviceToolPanels[id]?.close() }
    func reconnectAfterRestart(_ id:String) {
        guard let player = players[id], GameReconnectPolicy.permits(disconnected:player.transport.connectionEnded,
                editing:player.transport.mapping.editing,recording:player.transport.recording != .idle,
                recordingUnknown:player.transport.recordingStateUnknown) else { return }
        openGame(id)
    }
    func isPlayerOpen(_ id:String) -> Bool { players[id] != nil }
    func rememberThumbnail(_ frame: CGImage, device id: String) {
        let scale = min(128.0 / CGFloat(frame.width), 224.0 / CGFloat(frame.height), 1)
        let width = max(1, Int(CGFloat(frame.width) * scale))
        let height = max(1, Int(CGFloat(frame.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let thumbnail = context.makeImage() { deviceThumbnails[id] = thumbnail }
    }
    var hasPlayers: Bool { !players.isEmpty }
    var hasActiveRecording: Bool { players.values.contains { $0.transport.recording != .idle } }
    func closePlayers() {
        for (id, player) in Array(players) {
            player.stopDeviceOnClose = false
            player.window?.performClose(nil)
            if players[id] === player { player.stopDeviceOnClose = true }
        }
    }
    func closePlayerForStop(_ id:String) -> Bool {
        if recording.contains(id) || players[id]?.transport.recording != .idle && players[id] != nil {
            showError(text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first.")); return false
        }
        let player = players[id]
        player?.stopDeviceOnClose = false
        player?.window?.performClose(nil)
        if players[id] != nil { player?.stopDeviceOnClose = true }
        if players[id] != nil { showError(text("请先关闭游戏窗口。", "Close the game window first.")); return false }
        return true
    }
    func stop(_ id:String) {
        guard !busy.contains(id) else { return }
        if let player = players[id] { player.window?.performClose(nil) }
        else { operation("device.stop",id:id) }
    }
    func hibernate(_ id: String) {
        guard let device = devices.first(where: { $0.id == id }), device.running,
              !busy.contains(id), busyHolder(for: id) == nil, closePlayerForStop(id) else { return }
        operation("device.hibernate", id: id)
    }
    private func stopAfterWindowClose(_ id: String) {
        guard pendingWindowStops.insert(id).inserted else { return }
        players[id]?.transport.stoppingDevice = true
        if busy.contains(id) {
            cancelStartingDeviceIfPossible(id)
        } else {
            drainWindowStop(id)
        }
    }
    private func finishClosingPlayer(_ id: String) {
        guard let player = players[id] else { return }
        player.stopDeviceOnClose = false
        player.window?.performClose(nil)
        if players[id] != nil { player.stopDeviceOnClose = true }
    }
    private func cancelStartingDeviceIfPossible(_ id: String) {
        guard startingDevices.contains(id), pendingWindowStops.contains(id),
              let job = startJobs[id], startCancelRequested.insert(id).inserted else { return }
        call("jobs.cancel", ["job": job]) { [weak self] result in
            if case .failure(let error) = result { self?.showError(self?.readable(error) ?? error.localizedDescription) }
        }
    }
    @discardableResult private func drainWindowStop(_ id: String) -> Bool {
        guard pendingWindowStops.contains(id), !busy.contains(id) else { return false }
        operation("device.stop", id: id)
        return true
    }
    func start(_ id:String, coldBoot:Bool = false) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        guard !busy.contains(id) else { return }
        if device.running { openGame(id); return }
        busy.insert(id)
        startingDevices.insert(id)
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
            if let job {
                self.ownJobs.insert(job)
                self.startJobs[id] = job
                self.cancelStartingDeviceIfPossible(id)
            }
            let text = message.isEmpty ? self.text("正在启动设备…", "Starting the device…")
                                       : OperationMessages.progress(message, language: self.language)
            if !self.pendingWindowStops.contains(id) {
                self.applyLaunchState(.booting(progress: self.bootProgressFraction(for: id), message: text), to: id)
            }
        }) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            self.startingDevices.remove(id)
            self.startJobs.removeValue(forKey: id)
            self.startCancelRequested.remove(id)
            let stopPending = self.pendingWindowStops.contains(id)
            switch result {
            case .success:
                if !stopPending {
                    self.applyLaunchState(.running, to: id)
                    self.showToast(self.text("设备已启动。", "Device started."))
                }
            case .failure(let error):
                let reason: String
                if let failure = error as? CenterMessageError, failure.code == "resource_exhausted",
                   let data = failure.data, let refusal = try? self.decode(data, as: BudgetRefusal.self) {
                    reason = refusal.message(language: self.language)
                } else {
                    reason = self.readable(error)
                }
                if !stopPending { self.applyLaunchState(.stopped(reason: reason), to: id) }
                if !(stopPending && error.localizedDescription == "cancelled") { self.showError(reason) }
            }
            self.refresh(); self.refreshJobs()
            if self.selected == id { self.load(id) }
            self.drainWindowStop(id)
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
    func setRecordAudio(_ enabled: Bool) {
        call("center.prefs.set", ["record_audio": enabled]) { [weak self] result in
            switch result {
            case .success:
                self?.recordAudio = enabled
                self?.players.values.forEach { $0.transport.recordAudio = enabled }
            case .failure(let error):
                self?.showError(self?.readable(error) ?? error.localizedDescription)
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = text("miko 截图.png", "miko screenshot.png")
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = text("miko 录屏.mp4", "miko recording.mp4")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath:url.path) else { showError(text("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name.")); return }
        let includeAudio = recordAudio
        recording.insert(device); showToast(text("正在启动录屏…", "Starting recording…"))
        call("media.record",["device":device,"path":url.path,"audio":includeAudio]) { [weak self] result in
            guard let self else { return }; self.recording.remove(device)
            switch result {
            case .success(let value):
                if includeAudio, let result = value as? [String: Any], result["audio"] as? Bool == false {
                    self.showToast(self.text("录屏已保存，但设备音频不可用。", "Recording saved, but device audio was unavailable."))
                } else if includeAudio, let result = value as? [String: Any], result["audio_received"] as? Bool == false {
                    self.showToast(self.text("录屏已保存，但未收到设备音频。", "Recording saved, but no device audio was received."))
                } else {
                    self.showToast(self.text("录屏已保存", "Recording saved"))
                }
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
    func openSyncPanel(preselect devices: [String] = []) {
        syncPanel.present(model: self, preselect: devices)
    }

    func refreshSyncStatus() {
        call("sync.status", [:]) { [weak self] result in
            if case .success(let value) = result {
                self?.applySyncStateData(value)
            }
        }
    }

    private func applySyncStateData(_ value: Any?) {
        guard let value, !(value is NSNull) else {
            syncHub.applySession(nil)
            return
        }
        do {
            let decoded = try decode(value, as: SyncSessionModel.self)
            syncHub.clearError()
            syncHub.applySession(decoded)
        } catch {
            // Keep existing state if payload is malformed.
        }
    }

    func startSync(leader: String, followers: [String], options: SyncOptionsModel) {
        let params: [String: Any] = [
            "leader": leader,
            "followers": followers,
            "options": [
                "adaptation": options.adaptation.rawValue,
                "sync_keyboard": options.sync_keyboard,
                "sync_text": options.sync_text,
                "sync_tool_keys": options.sync_tool_keys,
                "lock_followers": options.lock_followers,
                "jitter_ms": options.jitter_ms,
            ],
        ]
        call("sync.start", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.applySyncStateData(value)
                // Ensure the leader has an open player window so input flows immediately.
                if self.players[leader] == nil {
                    self.openGame(leader)
                }
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func stopSync() {
        call("sync.stop", [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.syncHub.applySession(nil)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func setSyncLeader(_ device: String) {
        if let currentLeader = syncHub.session?.leader,
           currentLeader != device,
           let leaderTransport = players[currentLeader]?.transport,
           leaderTransport.scriptRecording != .idle || leaderTransport.scriptPlayback != .idle {
            showError(text("主控端正在录制或回放脚本，请先停止后再切换主控。", "Stop recording or playback on the leader before switching control."))
            return
        }
        call("sync.set_leader", ["device": device]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.applySyncStateData(value)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func setSyncOptions(_ options: SyncOptionsModel) {
        let params: [String: Any] = [
            "options": [
                "adaptation": options.adaptation.rawValue,
                "sync_keyboard": options.sync_keyboard,
                "sync_text": options.sync_text,
                "sync_tool_keys": options.sync_tool_keys,
                "lock_followers": options.lock_followers,
                "jitter_ms": options.jitter_ms,
            ],
        ]
        call("sync.set_options", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.applySyncStateData(value)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func addSyncFollower(_ device: String, completion: ((Bool) -> Void)? = nil) {
        call("sync.add_follower", ["device": device]) { [weak self] result in
            guard let self else { completion?(false); return }
            switch result {
            case .success(let value):
                self.applySyncStateData(value)
                completion?(true)
            case .failure(let error):
                self.showError(self.readable(error))
                completion?(false)
            }
        }
    }

    private func reportSyncDisplayIfNeeded(id: String, frameWidth: Int, frameHeight: Int, lcdWidth: Int, lcdHeight: Int) {
        guard let session = syncHub.session,
              frameWidth > 0, frameHeight > 0, lcdWidth > 0, lcdHeight > 0 else { return }
        let rotated = (frameWidth > frameHeight) != (lcdWidth > lcdHeight)
        let size = SyncDisplaySize(width: rotated ? lcdHeight : lcdWidth, height: rotated ? lcdWidth : lcdHeight)
        if session.leader == id {
            guard session.leader_display != size else { return }
        } else if let follower = session.followers.first(where: { $0.device == id }) {
            guard follower.display != size else { return }
        } else {
            return
        }
        call("sync.report", [
            "device": id,
            "display": ["width": size.width, "height": size.height],
        ]) { _ in }
    }

    func removeSyncFollower(_ device: String) {
        call("sync.remove_follower", ["device": device]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.applySyncStateData(value)
            case .failure(let error): self.showError(self.readable(error))
            }
        }
    }

    func estimateStorageMigration(to destination: String, completion: @escaping (Result<StorageEstimateInfo, Error>) -> Void) {
        call("center.storage.estimate", ["destination": destination]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                do {
                    completion(.success(try self.decode(value, as: StorageEstimateInfo.self)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func migrateStorage(to destination: String,
                        onProgress: @escaping (String, Double?) -> Void,
                        completion: @escaping (Result<StorageMigrationInfo, Error>) -> Void) {
        if hasActiveRecording || !recording.isEmpty || hasActiveJobs {
            completion(.failure(CenterMessageError(message: text("请先等待当前录屏和后台任务完成。", "Wait for active recordings and background jobs to finish first."))))
            return
        }
        guard !migratingStorage else {
            completion(.failure(CenterMessageError(message: text("正在迁移设备数据。", "Storage migration is already in progress."))))
            return
        }
        closePlayers()
        if hasPlayers {
            completion(.failure(CenterMessageError(message: text("请先关闭所有设备窗口。", "Close all device windows first."))))
            return
        }
        for controller in Array(deviceToolPanels.values) { controller.close() }
        deviceToolPanels.removeAll()
        syncPanel.close()

        migratingStorage = true
        stopHeartbeat()
        call("center.storage.migrate", ["destination": destination], onProgress: { [weak self] msg, _, progress in
            guard let self else { return }
            let translated = OperationMessages.progress(msg, language: self.language)
            onProgress(translated, progress)
        }) { [weak self] result in
            guard let self else { return }
            self.migratingStorage = false
            self.restartBridgeAfterMigration()
            switch result {
            case .success(let value):
                do {
                    let info = try self.decode(value, as: StorageMigrationInfo.self)
                    self.showToast(self.text("设备数据已迁移到新位置。", "Device data migrated to the new location."))
                    completion(.success(info))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func restartBridgeAfterMigration() {
        guard !stopping else { return }
        bridgeSession &+= 1
        reconnectAttempt = 0
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        failPendingRequests()
        if process.isRunning {
            try? input.fileHandleForWriting.close()
            process.terminate()
        }
        do {
            try startBridge()
            bootstrapBridge()
            connection = .online
            onlineSince = Date()
            startHeartbeat()
        } catch {
            scheduleReconnect()
        }
    }

    func close() {
        syncPanel.close()
        for controller in Array(deviceToolPanels.values) { controller.close() }
        deviceToolPanels.removeAll()
        panelCoordinator.shutdown()
        paletteWindow?.close(); paletteWindow = nil
        taskPanel?.close(); taskPanel = nil
        deviceSheetPanel?.dismissPanel(immediately: true); deviceSheetPanel = nil
        settingsWindow?.close(); settingsWindow = nil
        stopping = true
        for work in readDeadlines.values { work.cancel() }
        readDeadlines.removeAll()
        stopHeartbeat()
        jobsTimer?.invalidate(); jobsTimer = nil
        toastDismissWork?.cancel(); toastDismissWork = nil
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        try? input.fileHandleForWriting.close()
    }
}
