// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct Device: Identifiable, Decodable {
    struct Status: Decodable { let state: String }
    struct ImageInfo: Decodable { let api: Int; let tag: String }
    struct Root: Decodable { let mode: String; let health: String? }
    struct Runtime: Decodable { let adb_serial: String? }
    let root: Root
    let runtime: Runtime?
    let profile: String
    let sdk_root: String
    struct Launch: Decodable { let audio: Bool?; let quick_boot: Bool?; let camera_back: String?; let camera_front: String? }
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
    var androidVersion: String {
        let known = [28:"9",29:"10",30:"11",31:"12",32:"12L",33:"13",34:"14",35:"15",36:"16"]
        return known[image.api].map { "Android \($0) · API \(image.api)" } ?? "Android API \(image.api)"
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
struct AppList: Decodable { let apps: [AndroidApp] }
struct RootPresentation: Identifiable { let id: String; let name: String }
enum FullRootState { case running, verified(String), failed(String) }

final class CenterModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var deviceListLoaded = false
    @Published var selected: String?
    @Published var details: Details?
    @Published var apps: [AndroidApp] = []
    @Published var appsLoading = false
    @Published var appsError: String?
    private let appListLoader = AppListLoader<AppList>()
    @Published var notice = "正在连接…"
    @Published var busy = Set<String>()
    @Published var recording = Set<String>()
    @Published private var requestProgress: [Int:String] = [:]
    @Published private var bootProgress: [String:Double] = [:]
    @Published var language = 1
    @Published var appearance = 0
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
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var callbacks: [Int:(Result<Any,Error>)->Void] = [:]
    private var progressCallbacks: [Int:(String,String?,Double?)->Void] = [:]
    private var requestDevices: [Int:String] = [:]
    private var mutations = Set<Int>()
    var hasMutations: Bool { !mutations.isEmpty }
    private var sequence = 0
    private var refreshGeneration = 0
    private var detailGeneration = 0
    private var players: [String:GameWindowController] = [:]
    private var advancedWindows: [String:AdvancedToolsWindowController] = [:]
    private var openingPlayers = Set<String>()
    let gameExecutable: String
    let bridgeExecutable: String
    let centerExecutable: String
    var onPlayersChanged: (() -> Void)?

    init(center: String, game: String, bridge: String) throws {
        gameExecutable = game; bridgeExecutable = bridge; centerExecutable = center
        process.executableURL = URL(fileURLWithPath:center)
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            guard let self else { return }
            let pending = Array(self.callbacks.values); self.callbacks.removeAll(); self.progressCallbacks.removeAll(); self.mutations.removeAll()
            self.requestDevices.removeAll(); self.requestProgress.removeAll(); self.bootProgress.removeAll()
            for done in pending { done(.failure(NSError(domain:"JidrCenter",code:3,userInfo:[NSLocalizedDescriptionKey:"后台连接已结束"]))) }
            self.notice = self.text("与后台的连接已结束；设备状态需要重新检查。", "The daemon connection ended; device state needs to be checked again.")
        } }
        try process.run()
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
    }
    func call(_ method: String, _ params: [String:Any] = [:], onProgress: ((String,String?,Double?)->Void)? = nil, done: @escaping (Result<Any,Error>) -> Void) {
        sequence += 1; let id = sequence
        guard process.isRunning, let data = try? JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params]) else {
            done(.failure(NSError(domain:"JidrCenter",code:1,userInfo:[NSLocalizedDescriptionKey:"后台未连接"]))); return
        }
        callbacks[id] = done
        progressCallbacks[id] = onProgress
        if let device = params["device"] as? String { requestDevices[id] = device }
        let readOnly = ["device.list", "device.details", "app.list", "image.list", "profile.list", "snapshot.list", "sdk.status", "settings.get", "cache.list", "center.about", "center.paths", "center.prefs.get", "center.quit", "center.migration.preflight", "battery.get", "gps.get", "network.get", "network.proxy.get", "sensor.get", "logcat.dump", "root.cacert.list", "device.props.get", "dev.get", "clipboard.get"]
        if !readOnly.contains(method) { mutations.insert(id) }
        do { try input.fileHandleForWriting.write(contentsOf:data + Data([10])) }
        catch { callbacks.removeValue(forKey:id); progressCallbacks.removeValue(forKey:id); mutations.remove(id); requestDevices.removeValue(forKey:id); done(.failure(error)) }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of:10) {
            let line = Data(buffer.prefix(upTo:end)); buffer.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with:line)) as? [String:Any], let kind = event["type"] as? String else { continue }
            if kind == "device_event" {
                if let event = event["event"] as? [String:Any], let topic = event["topic"] as? String,
                   let data = event["data"] as? [String:Any], let device = data["device"] as? String {
                    if topic == "device.boot", let progress = data["progress"] as? Double {
                        bootProgress[device] = min(1,max(0,progress))
                    } else if topic == "device.boot_failed" { bootProgress.removeValue(forKey:device) }
                }
                refresh(); continue
            }
            guard let id = event["id"] as? Int else { continue }
            if kind == "progress" {
                progressCallbacks[id]?(event["message"] as? String ?? "", event["job"] as? String, event["progress"] as? Double)
                if let message = event["message"] as? String, !message.isEmpty {
                    if requestDevices[id] != nil { requestProgress[id] = message }
                    else { notice = message }
                }
                continue
            }
            requestProgress.removeValue(forKey:id)
            progressCallbacks.removeValue(forKey:id)
            requestDevices.removeValue(forKey:id)
            mutations.remove(id)
            guard let completion = callbacks.removeValue(forKey:id) else { continue }
            if kind == "error" { completion(.failure(NSError(domain:"JidrCenter",code:2,userInfo:[NSLocalizedDescriptionKey:event["message"] as? String ?? "操作失败"]))) }
            else { completion(.success(event["result"] ?? NSNull())) }
        }
    }
    func decode<T:Decodable>(_ value:Any, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject:value, options:.fragmentsAllowed))
    }
    func text(_ chinese:String, _ english:String) -> String { language == 0 ? english : chinese }
    func startSDKInstall(_ plan: SDKInstallPlan) {
        guard !sdkInstalling else { return }
        sdkInstalling = true; sdkCancelPending = false; sdkInstallJob = nil; sdkInstallError = nil; sdkInstallFraction = nil; sdkInstallSucceeded = nil
        sdkInstallMessage = text("正在准备安装…", "Preparing installation…")
        call(plan.method,plan.parameters,onProgress:{ [weak self] message, job, fraction in
            guard let self else { return }
            if let job { self.sdkInstallJob = job }
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
                self.notice = self.sdkInstallMessage; self.refresh()
            case .failure(let error):
                self.sdkInstallSucceeded = false
                if SDKInstallPlan.wasCancelled(error.localizedDescription,requested:cancellationRequested) {
                    self.sdkInstallMessage = self.text("SDK 安装已取消。", "SDK installation cancelled.")
                } else {
                    self.sdkInstallError = OperationMessages.error(error.localizedDescription,language:self.language)
                    self.sdkInstallMessage = self.text("SDK 安装未完成。", "SDK installation did not finish.")
                }
                self.notice = self.sdkInstallMessage
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
    func progress(for device:String) -> String? {
        if let value = bootProgress[device], devices.first(where: { $0.id == device })?.running != true {
            return text("正在启动 \(Int(value * 100))%", "Starting \(Int(value * 100))%")
        }
        return requestDevices.filter { $0.value == device }.keys.sorted().reversed().compactMap { requestProgress[$0] }.first.map { OperationMessages.progress($0,language:language) }
    }
    func refresh() {
        refreshGeneration += 1; let generation = refreshGeneration
        call("device.list") { [weak self] result in
            guard let self, generation == self.refreshGeneration else { return }
            do {
                let list = try self.decode(result.get(), as:[Device].self)
                let previousID = self.selected
                let previousState = self.devices.first(where: { $0.id == previousID })?.status.state
                self.devices = list
                self.deviceListLoaded = true
                for device in list where device.running || device.stopped { self.bootProgress.removeValue(forKey:device.id) }
                if !list.contains(where:{ $0.id == self.selected }) { self.selected = list.first?.id }
                if self.notice == "正在连接…" { self.notice = "" }
                let nextState = list.first(where: { $0.id == self.selected })?.status.state
                if let id = self.selected, self.details == nil || previousID != id || previousState != nextState { self.load(id) }
            } catch { self.notice = error.localizedDescription }
        }
    }
    func select(_ id:String) { selected = id; details = nil; apps = []; load(id) }
    func load(_ id:String) {
        detailGeneration += 1; let generation = detailGeneration
        call("device.details", ["device":id]) { [weak self] result in
            guard let self, self.selected == id, self.detailGeneration == generation else { return }
            do { self.details = try self.decode(result.get(), as:Details.self) }
            catch { self.notice = error.localizedDescription }
        }
        appListLoader.cancel()
        appsError = nil
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
            case .success(let list): self.apps = list.apps; self.appsError = nil
            case .failure(let error):
                self.appsError = self.text("应用列表暂时无法读取，请点击刷新重试。", "Unable to load apps. Click Refresh to try again.") + "\n" + error.localizedDescription
            }
        })
    }
    func operation(_ method:String, id:String, params:[String:Any] = [:], then: (() -> Void)? = nil) {
        guard !busy.contains(id) else { return }
        busy.insert(id); var args = params; args["device"] = id
        call(method,args) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            switch result {
            case .success: self.notice = self.language == 0 ? "Completed" : "操作完成"; self.refresh(); if self.selected == id { self.load(id) }; then?()
            case .failure(let error):
                let message = error.localizedDescription
                if method == "file.install" && message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                    self.notice = self.language == 0 ? "Installation failed: the device is out of storage. Free some space or create a larger device." : "安装失败：设备空间不足。可释放空间，或新建更大容量的设备。"
                } else { self.notice = message }
                self.refresh()
            }
        }
    }
    func setupFullRoot(_ id:String, name:String) {
        guard !busy.contains(id) else { return }
        busy.insert(id); fullRoot[id] = .running
        rootPresentation = RootPresentation(id:id,name:name)
        call("root.set",["device":id,"mode":"magisk"]) { [weak self] result in
            guard let self else { return }
            self.busy.remove(id)
            switch result {
            case .success(let value):
                if let object = value as? [String:Any], let verification = object["verification"] as? [String:Any], verification["ok"] as? Bool == true {
                    self.fullRoot[id] = .verified(object["magisk_version"] as? String ?? "")
                    self.notice = self.text("完整 Root 验证成功。", "Full root verified.")
                } else {
                    self.fullRoot[id] = .failed(self.text("未收到成功的 Root 验证结果。", "Root verification did not report success."))
                }
            case .failure(let error): self.fullRoot[id] = .failed(error.localizedDescription)
            }
            self.refresh()
            if self.selected == id { self.load(id) }
        }
    }
    func openGame(_ id:String) {
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
        guard !hasExternalPlayer else { notice = text("请先关闭独立运行的旧版测试窗口。", "Close the standalone test window first."); return }
        guard openingPlayers.insert(id).inserted else { return }
        call("device.details", ["device":id]) { [weak self] result in
            guard let self else { return }
            self.openingPlayers.remove(id)
            do {
                let details = try self.decode(result.get(), as:Details.self)
                guard details.device.running,
                      let width = Int(details.config["hw.lcd.width"] ?? ""),
                      let height = Int(details.config["hw.lcd.height"] ?? "") else { self.notice = self.text("设备尚未就绪", "Device is not ready"); return }
                guard let dataDirectory = self.dataDirectory else { self.notice = self.text("无法读取数据目录", "Cannot read the data directory"); return }
                let quality = try WindowQualityStore(dataDirectory:dataDirectory,device:id).load()
                let player = GameWindowController()
                player.transport.language = self.language
                player.transport.onReconnect = { [weak self] in self?.openGame(id) }
                player.transport.onAdvanced = { [weak self] in self?.openAdvanced(id, name:details.device.name) }
                player.onWarning = { [weak self] message in self?.notice = message }
                player.onClose = { [weak self] in self?.players.removeValue(forKey:id); self?.onPlayersChanged?() }
                self.players[id] = player
                player.open(device:id,width:width,height:height,executable:self.bridgeExecutable,displayName:details.device.name,quality:quality,dataDirectory:dataDirectory)
                self.onPlayersChanged?()
            } catch { self.notice = error.localizedDescription }
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
    var hasExternalPlayer: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier:"local.jidr.swiftui.prototype").contains { !$0.isTerminated }
    }
    var hasActiveRecording: Bool { players.values.contains { $0.transport.recording != .idle } }
    func closePlayers() { for player in Array(players.values) { player.window?.performClose(nil) } }
    func closePlayerForStop(_ id:String) -> Bool {
        if hasExternalPlayer { notice = text("请先关闭独立运行的旧版测试窗口。", "Close the standalone test window first."); return false }
        if recording.contains(id) || players[id]?.transport.recording != .idle && players[id] != nil {
            notice = text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first."); return false
        }
        players[id]?.window?.performClose(nil)
        if players[id] != nil { notice = text("请先关闭游戏窗口。", "Close the game window first."); return false }
        return true
    }
    func stop(_ id:String) {
        guard closePlayerForStop(id) else { return }
        operation("device.stop",id:id)
    }
    func start(_ id:String, coldBoot:Bool = false) {
        guard !hasExternalPlayer else { notice = text("请先关闭独立运行的旧版测试窗口。", "Close the standalone test window first."); return }
        operation("device.start",id:id,params:coldBoot ? ["cold_boot":true] : [:]) { [weak self] in self?.openGame(id) }
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
            case .failure(let error): self?.notice = error.localizedDescription
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Jidr 截图.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation("media.screenshot",id:device,params:["path":url.path])
    }
    func openScreenshotFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Jidr",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            if !NSWorkspace.shared.open(folder) { notice = text("无法打开截图目录。", "Cannot open the screenshots folder.") }
        } catch { notice = error.localizedDescription }
    }
    func toggleRecording(device:String) {
        if recording.contains(device) {
            call("media.record_stop",["device":device]) { [weak self] result in
                switch result { case .success: self?.notice = self?.text("正在保存录屏…", "Saving recording…") ?? ""; case .failure(let error): self?.notice = error.localizedDescription }
            }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Jidr 录屏.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath:url.path) else { notice = text("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name."); return }
        recording.insert(device); notice = text("正在启动录屏…", "Starting recording…")
        call("media.record",["device":device,"path":url.path]) { [weak self] result in
            guard let self else { return }; self.recording.remove(device)
            switch result { case .success: self.notice = self.text("录屏已保存", "Recording saved"); case .failure(let error): self.notice = error.localizedDescription }
        }
    }
    func launch(_ app:AndroidApp, device:String) {
        openGame(device)
        call("app.launch", ["device":device,"package":app.package]) { [weak self] result in
            if case .failure(let error) = result { self?.notice = error.localizedDescription }
        }
    }
    func close() { try? input.fileHandleForWriting.close() }
}


