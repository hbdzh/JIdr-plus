// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

private enum CenterManagedPanel: Equatable {
    case palette, tasks
    case device(CenterSheet)
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
    @Published var apps: [AndroidApp] = []
    @Published var appsLoading = false
    @Published var appsError: String?
    @Published var appsNote: String?
    private let appListLoader = AppListLoader<AppList>()
    @Published var notice = ""
    @Published var busy = Set<String>()
    private let lifecycle = CenterDeviceLifecycle()
    @Published var recording = Set<String>()
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
    private lazy var appSearch = DeviceAppSearch(request: { [weak self] id, completion in
        guard let self else { return }
        self.callImpl("app.list", ["device": id], onProgress: nil, readTimeout: 30) { [weak self] result in
            guard let self else { return }
            completion(result.flatMap { value in
                Result { try self.decode(value, as: AppList.self).apps.map { DeviceSearchApp(name: $0.name, package: $0.package) } }
            })
        }
    }, publish: { [weak self] matches in
        self?.appSearchMatches = matches
    })
    var filteredDevices: [Device] {
        devices.filter { deviceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(deviceQuery) || appSearchMatches[$0.id] != nil }
    }
    private func searchDeviceApps() {
        appSearch.scheduleUpdate(query: deviceQuery, running: devices.filter(\.running).map(\.id))
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
                                             "center.about"]

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
    private var pendingSnapshotWarnings: [String:String] = [:]
    private var failedStopSnapshots: [String: String] = [:]
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

    private lazy var bridge = CenterBridgeProcess(executable: centerExecutable,
        onEvent: { [weak self] event, session in self?.applyEvent(event, session: session) },
        onTermination: { [weak self] session in self?.bridgeTerminated(session: session) })
    private let decodeQueue = DispatchQueue(label: "local.miko.center.decode", qos: .userInitiated)
    private let requests = CenterRequestTracker()
    private var requestUpdates: AnyCancellable?
    /// Job ids started by this center, so a device held by our own job is not
    /// reported as "in use by another client".
    private(set) var ownJobs = Set<String>()
    var hasMutations: Bool { requests.hasMutations }
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshPending = false
    private var jobsGeneration = 0
    private var jobsInFlight = false
    private var jobsPending = false
    private var eventRefreshWork: DispatchWorkItem?
    private var detailGeneration = 0
    private var selectionCleared = false
    let windowRegistry = CenterWindowRegistry()
    var players: [String: GameWindowController] { windowRegistry.players }
    let bridgeExecutable: String
    let centerExecutable: String
    var onPlayersChanged: (() -> Void)?
    let syncHub = SyncHub()
    let syncPanel = SyncPanelCoordinator()

    init(center: String, bridge: String) throws {
        bridgeExecutable = bridge; centerExecutable = center
        requestUpdates = requests.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        try startBridge()
        configureSyncHub()
        bootstrapBridge()
    }

    private func configureSyncHub() {
        syncHub.ensureBridge = { [weak self] id in
            guard let self, self.players[id] == nil else { return }
            self.windowRegistry.markBackground(id)
            self.openGame(id, hidden: true)
        }
        syncHub.releaseBackgroundBridge = { [weak self] id in
            guard let self else { return }
            self.windowRegistry.clearBackground(id)
            self.windowRegistry.consumeVisible(id)
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

    /// Starts a fresh bridge session and resets pending refresh tracking.
    private func startBridge() throws {
        bridgeSession += 1
        resetRefreshTracking()
        try bridge.start(session: bridgeSession)
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
        if !deviceQuery.isEmpty { searchDeviceApps() }
    }

    private func bridgeTerminated(session: Int) {
        guard session == bridgeSession else { return }
        bridge.stopReading()
        bridge.stopWriting()
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
        appSearch.reset()
        resetRefreshTracking()
        bootProgress.removeAll()
        requests.failAll(connectionEndedError())
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
        bridge.stopWriting()
        failPendingRequests()
        noteSessionEnded()
        scheduleReconnect()
        bridge.terminate()
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
        callImpl(method, params, onProgress: onProgress, readTimeout: nil, done: done)
    }

    private func callImpl(_ method: String, _ params: [String:Any], onProgress: ((String,String?,Double?)->Void)?, readTimeout: TimeInterval?, done: @escaping (Result<Any,Error>) -> Void) {
        let id = requests.nextID()
        guard bridge.isRunning, bridge.canWrite, let data = try? JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params]) else {
            done(.failure(CenterMessageError(message: text("后台未连接", "The background service is not connected")))); return
        }
        let readOnly = ["host.budget", "device.list", "device.details", "app.list", "app.inspect", "image.list", "image.inventory", "profile.list", "snapshot.list", "sdk.status", "sdk.license_details", "settings.get", "cache.list", "center.about", "center.paths", "center.prefs.get", "center.quit", "center.storage.estimate", "battery.get", "gps.get", "network.get", "network.proxy.get", "network.shaping.get", "identity.get", "file.sync.list", "input.gamepad.list", "input.gamepad.get", "sensor.get", "logcat.dump", "root.cacert.list", "device.props.get", "dev.get", "clipboard.get", "jobs.list", "jobs.get", "daemon.status"]
        requests.register(id: id, method: method, device: params["device"] as? String,
                          mutation: !readOnly.contains(method), progress: onProgress, completion: done)
        if method == "device.details" || method == "host.budget" || readTimeout != nil {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let finished = self.requests.finish(id: id) else { return }
                self.bridge.cancel(id: id)
                let message: String
                if method == "host.budget" { message = self.text("读取内存预算超时，请重试。", "Loading the memory budget timed out. Try again.") }
                else if method == "device.details" { message = self.text("读取设备详情超时，请重试。", "Loading device details timed out. Try again.") }
                else { message = self.text("读取应用列表超时，请重试。", "Loading the app list timed out. Try again.") }
                finished.completion(.failure(CenterMessageError(message: message)))
            }
            requests.setDeadline(timeout, for: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + (readTimeout ?? detailsReadTimeout), execute: timeout)
        }
        let session = bridgeSession
        let accepted = bridge.send(id: id, data: data + Data([10])) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.bridgeSession == session else { return }
                self.connectionLost()
            }
        }
        if !accepted {
            if let finished = requests.finish(id: id) {
                finished.completion(.failure(CenterMessageError(message: text("后台请求队列已满，请稍后重试。", "The background request queue is full. Try again."))))
            }
        }
    }
    private func applyEvent(_ event: [String:Any], session: Int) {
        guard session == bridgeSession else { return }
        guard let kind = event["type"] as? String else { return }
        if kind == "device_event" {
            bridgeAnswered()
            var immediateRefresh = false
            if let event = event["event"] as? [String:Any], let topic = event["topic"] as? String {
                if topic == "device.snapshot_warning", let data = event["data"] as? [String:Any] {
                    let reason = data["reason"] as? String ?? ""
                    if reason == "low_resources" {
                        if data["low_disk"] as? Bool == true { showError(text("磁盘可用空间不足，快速启动快照可能保存失败。", "Low disk space may prevent saving the quick-boot snapshot.")) }
                        else if data["low_memory"] as? Bool == true { showError(text("可用内存较少，保存快照可能需要更长时间。", "Low available memory may make saving the snapshot slower.")) }
                    } else if let device = data["device"] as? String, reason == "stop_save_failed" {
                        let warning = data["cold_boot_persisted"] as? Bool == false
                            ? text("设备已停止，但快照和启动设置均未能保存；下次请手动选择冷启动。", "Device stopped, but the snapshot and startup setting could not be saved. Select cold boot next time.")
                            : text("设备已停止，但快速启动快照保存失败，下次将冷启动。", "Device stopped, but the quick-boot snapshot could not be saved. The next start will be a cold boot.")
                        failedStopSnapshots[device] = warning
                        showError(warning)
                    } else if let device = data["device"] as? String, reason == "unclean_exit" {
                        pendingSnapshotWarnings[device] = text("设备上次未正常停止，之前的运行状态可能未完整保存。", "The device did not stop normally; its previous session may not have been fully saved.")
                    } else if let device = data["device"] as? String, reason == "incomplete_snapshot" {
                        pendingSnapshotWarnings[device] = text("上次的快速启动快照不完整，设备可能需要冷启动。", "The previous quick-boot snapshot is incomplete; the device may cold boot.")
                    }
                    return
                }
                if topic == "sync.state" {
                    let data = event["data"] as? [String:Any]
                    CenterSyncSession.apply(data?["session"], to: syncHub)
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
                    if !lifecycle.pendingWindowStops.contains(device), !lifecycle.stoppingDevices.contains(device),
                       lifecycle.startingDevices.contains(device) || devices.first(where: { $0.id == device })?.status.state == "booting"
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
        if kind == "progress" {
            bridgeAnswered()
            let message = event["message"] as? String ?? ""
            let progress = requests.updateProgress(id: id, message: message,
                                                   job: event["job"] as? String, fraction: event["progress"] as? Double)
            if !message.isEmpty, !progress.hasDevice, !progress.hasHandler {
                notice = OperationMessages.progress(message, language: language)
            }
            return
        }
        guard let finished = requests.finish(id: id) else { return }
        let method: String? = finished.method
        let requestDevice = finished.device
        let completion = finished.completion
        if kind == "error" {
            let message = event["message"] as? String ?? "操作失败"
            completion(.failure(CenterMessageError(message: message, code: event["code"] as? String, data: event["data"] as? [String: Any])))
            if let method, !localMethods.contains(method) { bridgeAnswered() }
            if !migratingStorage, ConnectionHealth.looksDisconnected(message) { connectionLost() }
        } else {
            if let device = requestDevice, method == "file.install" || method == "app.uninstall" {
                appSearch.invalidate(device)
            }
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
            guard !self.stopping, self.bridge.isRunning else { return }
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
        let methods = requests.mutationMethods
        return Self.canLeaveStopsRunning(
            stopping: lifecycle.stoppingDevices,
            deviceStates: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.status.state) }),
            mutationMethods: methods,
            mutationCount: requests.mutationCount,
            hasOtherWork: hasActiveRecording || !recording.isEmpty || hasPlayers || hasActiveJobs || !lifecycle.pendingWindowStops.isEmpty
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
        if bridge.isRunning { startHeartbeat() } else { scheduleReconnect() }
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
        guard !stopping, !migratingStorage, bridge.isRunning else { return }
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
        if lifecycle.stoppingDevices.contains(device) {
            return text("正在安全停止设备，保存状态可能需要几分钟。", "Stopping safely; saving state may take a few minutes.")
        }
        if let value = bootProgress[device], devices.first(where: { $0.id == device })?.running != true {
            return text("正在启动 \(Int(value * 100))%", "Starting \(Int(value * 100))%")
        }
        return requests.latestMessage(for: device).map { OperationMessages.progress($0,language:language) }
    }
    func refresh() {
        guard bridge.isRunning, !migratingStorage else { return }
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
            // Track stops even while the search field is empty, so a restarted
            // device cannot reuse the previous session's app cache.
            searchDeviceApps()
        }
        if !deviceListLoaded { deviceListLoaded = true }
        for device in list where device.running || (device.stopped && !lifecycle.startingDevices.contains(device.id)) { bootProgress.removeValue(forKey: device.id) }
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
        if method == "device.stop" { failedStopSnapshots.removeValue(forKey: id); lifecycle.beginStop(id) }
        busy.insert(id); var args = params; args["device"] = id
        call(method,args,onProgress:{ [weak self] _, job, _ in
            if let job { self?.ownJobs.insert(job) }
        }) { [weak self] result in
            guard let self else { return }
            if method == "device.stop" { self.lifecycle.finishStop(id) }
            if method == "device.delete", case .success = result {
                self.verifyDeletion(id, then: then)
                return
            }
            self.busy.remove(id)
            let stopPending = self.lifecycle.pendingWindowStops.contains(id)
            switch result {
            case .success:
                if method == "device.stop", stopPending {
                    self.lifecycle.finishWindowStop(id)
                    self.finishClosingPlayer(id)
                }
                if method == "device.stop", let warning = self.failedStopSnapshots.removeValue(forKey: id) {
                    self.showError(warning)
                } else {
                    self.showToast(self.text("操作完成", "Completed"))
                }
                self.refresh(); self.refreshJobs()
                if self.selected == id { self.load(id) }
                if !stopPending { then?() }
            case .failure(let error):
                if method == "device.stop", stopPending {
                    self.lifecycle.finishWindowStop(id)
                    self.players[id]?.transport.stoppingDevice = false
                }
                let message = error.localizedDescription
                if method == "file.install", message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                    self.showError(self.text("安装失败：设备空间不足。可释放空间，或新建更大容量的设备。", "Installation failed: the device is out of storage. Free some space or create a larger device."))
                } else if method == "file.install", let apk = args["apk"] as? String, Self.isSignatureMismatch(message) {
                    self.promptReinstall(device:id, apkPath:apk)
                } else if (error as? CenterMessageError)?.isQuickBootSaveFailure == true {
                    self.showError(self.quickBootFailureMessage(error))
                } else {
                    self.showError(self.readable(error))
                }
                self.refresh(); self.refreshJobs()
            }
            self.drainWindowStop(id)
        }
    }
    func quickBootFailureMessage(_ error: Error) -> String {
        if error.localizedDescription.contains("UNSUPPORTED_VK_APP") {
            return text("当前 Vulkan 应用无法保存快速启动快照。设备仍在运行，请在安卓中退出该应用后重试。", "The Vulkan app cannot be saved in a quick-boot snapshot. The device is still running; close the app in Android and try again.")
        }
        let data = (error as? CenterMessageError)?.data
        if data?["low_disk"] as? Bool == true {
            return text("保存快照失败，磁盘可用空间不足。设备仍在运行，请释放空间后重试。", "Could not save the snapshot because disk space is low. The device is still running; free space and try again.")
        }
        if data?["low_memory"] as? Bool == true {
            return text("保存快照失败，可用内存较少。设备仍在运行，请释放内存后重试。", "Could not save the snapshot with low available memory. The device is still running; free memory and try again.")
        }
        return text("保存快照失败，设备仍在运行。请检查磁盘空间后重试。", "Could not save the snapshot. The device is still running; check disk space and try again.")
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
        guard !lifecycle.pendingWindowStops.contains(id), !lifecycle.stoppingDevices.contains(id) else {
            if hidden { windowRegistry.clearBackground(id) }
            return
        }
        if !hidden {
            windowRegistry.requestVisible(id)
            windowRegistry.clearBackground(id)
        }
        if let existing = players[id], let window = existing.window {
            windowRegistry.consumeVisible(id)
            if GameReconnectPolicy.permits(disconnected:existing.transport.connectionEnded,
                                           editing:existing.transport.mapping.editing,
                                           recording:existing.transport.recording != .idle,
                                           recordingUnknown:existing.transport.recordingStateUnknown) {
                existing.stopDeviceOnClose = false
                window.performClose(nil)
                if players[id] != nil { existing.stopDeviceOnClose = true }
                guard players[id] == nil else { return }
            } else if !hidden {
                windowRegistry.clearBackground(id)
                syncHub.markWindowVisible(for: id)
                existing.transport.setDisplayVisible(true)
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); return
            } else {
                return
            }
        }
        guard windowRegistry.beginOpening(id) else { return }
        call("device.details", ["device":id]) { [weak self] result in
            guard let self else { return }
            self.windowRegistry.endOpening(id)
            let becameVisible = self.windowRegistry.consumeVisible(id)
            let effectiveHidden = hidden && !becameVisible
            guard !self.lifecycle.pendingWindowStops.contains(id), !self.lifecycle.stoppingDevices.contains(id) else {
                if effectiveHidden { self.windowRegistry.clearBackground(id) }
                return
            }
            if effectiveHidden && !self.windowRegistry.isBackground(id) {
                return
            }
            do {
                let details = try self.decode(result.get(), as:Details.self)
                guard let width = Int(details.config["hw.lcd.width"] ?? ""),
                      let height = Int(details.config["hw.lcd.height"] ?? "") else {
                    if effectiveHidden { self.windowRegistry.clearBackground(id) }
                    self.showError(self.text("设备尚未就绪", "Device is not ready")); return
                }
                guard let dataDirectory = self.dataDirectory else {
                    if effectiveHidden { self.windowRegistry.clearBackground(id) }
                    self.showError(self.text("无法读取数据目录", "Cannot read the data directory")); return
                }
                let quality: UInt8
                do { quality = try WindowQualityStore(dataDirectory:dataDirectory,device:id).load() }
                catch {
                    if effectiveHidden { self.windowRegistry.clearBackground(id) }
                    self.showError(self.readable(error)); return
                }
                let launchState = self.lifecycle.startingDevices.contains(id)
                    ? PlayerLaunchState.booting(progress: self.bootProgressFraction(for: id),
                                                message: self.progress(for: id) ?? self.text("正在启动设备…", "Starting the device…"))
                    : (launch ?? self.playerLaunchState(for: details.device))
                self.windowRegistry.setInitialLaunchState(launchState, for: id)
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
                    self?.windowRegistry.clearBackground(id)
                    self?.windowRegistry.removePlayer(id)
                    self?.onPlayersChanged?()
                }
                self.windowRegistry.setPlayer(player, for: id)
                player.open(device:id,width:width,height:height,executable:self.bridgeExecutable,displayName:details.device.name,quality:quality,dataDirectory:dataDirectory,
                            launch: launchState, hidden: effectiveHidden,
                            onStartDevice: { [weak self] in self?.start(id) })
                self.syncHub.registerBridge(player.transport, for: id, background: effectiveHidden)
                self.onPlayersChanged?()
            } catch {
                if effectiveHidden { self.windowRegistry.clearBackground(id) }
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
        if let existing = windowRegistry.tool(id) {
            existing.present(relativeTo: owner, root: root, section: section)
        } else {
            let controller = DeviceToolsPanelController(model: self, id: id, name: name, root: root)
            controller.onClose = { [weak self] in self?.windowRegistry.removeTool(id) }
            windowRegistry.setTool(controller, for: id)
            controller.present(relativeTo: owner, root: root, section: section)
        }
    }
    func closeDeviceTools(_ id: String) { windowRegistry.tool(id)?.close() }
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
        guard lifecycle.requestWindowStop(id) else { return }
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
        guard let job = lifecycle.jobToCancel(for: id) else { return }
        call("jobs.cancel", ["job": job]) { [weak self] result in
            if case .failure(let error) = result { self?.showError(self?.readable(error) ?? error.localizedDescription) }
        }
    }
    @discardableResult private func drainWindowStop(_ id: String) -> Bool {
        guard lifecycle.pendingWindowStops.contains(id), !busy.contains(id) else { return false }
        operation("device.stop", id: id)
        return true
    }
    func start(_ id:String, coldBoot:Bool = false) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        guard !busy.contains(id) else { return }
        if device.running { openGame(id); return }
        busy.insert(id)
        lifecycle.beginStart(id)
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
                self.lifecycle.recordStartJob(job, for: id)
                self.cancelStartingDeviceIfPossible(id)
            }
            let text = message.isEmpty ? self.text("正在启动设备…", "Starting the device…")
                                       : OperationMessages.progress(message, language: self.language)
            if !self.lifecycle.pendingWindowStops.contains(id) {
                self.applyLaunchState(.booting(progress: self.bootProgressFraction(for: id), message: text), to: id)
            }
        }) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            self.lifecycle.finishStart(id)
            let stopPending = self.lifecycle.pendingWindowStops.contains(id)
            switch result {
            case .success:
                if !stopPending {
                    self.applyLaunchState(.running, to: id)
                    if let warning = self.pendingSnapshotWarnings.removeValue(forKey: id) {
                        self.showError(warning)
                    } else {
                        self.showToast(self.text("设备已启动。", "Device started."))
                    }
                }
            case .failure(let error):
                self.pendingSnapshotWarnings.removeValue(forKey: id)
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
        windowRegistry.closeAllTools()
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
        bridge.stopWriting()
        bridge.terminate()
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
        windowRegistry.closeAllTools()
        panelCoordinator.shutdown()
        paletteWindow?.close(); paletteWindow = nil
        taskPanel?.close(); taskPanel = nil
        deviceSheetPanel?.dismissPanel(immediately: true); deviceSheetPanel = nil
        settingsWindow?.close(); settingsWindow = nil
        stopping = true
        requests.cancelDeadlines()
        stopHeartbeat()
        jobsTimer?.invalidate(); jobsTimer = nil
        toastDismissWork?.cancel(); toastDismissWork = nil
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        appSearch.reset()
        bridge.stopWriting()
    }
}
