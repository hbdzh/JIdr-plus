// SPDX-License-Identifier: GPL-3.0-only
// Device-center features built on top of CenterModel's connection: the command
// palette catalog, the background task rows, the device session summary and
// the APK signature-conflict reinstall. Kept apart from DeviceModel.swift so
// the connection/task mechanics stay readable.

import AppKit
import Foundation

extension CenterModel {
    // MARK: - Command palette

    /// Devices as the pure palette catalog needs them.
    var paletteDevices: [PaletteDevice] {
        devices.map { device in
            let holder = busyHolder(for: device.id)
            let state: PaletteDevice.State
            if holder != nil || busy.contains(device.id) {
                state = .busy
            } else if device.running {
                state = .running
            } else if device.stopped {
                state = .stopped
            } else {
                state = .starting
            }
            return PaletteDevice(id: device.id, name: device.name, state: state,
                                 android: device.androidVersion,
                                 status: holder ?? device.statusText(language: language))
        }
    }

    var paletteEntries: [PaletteEntry] {
        PaletteCatalog.items(devices: paletteDevices, sdkReady: !devices.isEmpty,
                             text: { [self] chinese, english in text(chinese, english) })
    }

    var paletteFiltered: [PaletteEntry] {
        PaletteCatalog.filter(paletteEntries, query: paletteQuery)
    }

    /// "Nothing matches “query”." — built through the bilingual helper because
    /// SwiftUI would look up the composed string as a .strings key otherwise.
    var paletteEmptyText: String {
        text("没有匹配“\(paletteQuery)”。", "Nothing matches “\(paletteQuery)”.")
    }

    /// Runs a palette entry; the overlay is already dismissed by the caller.
    func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .newDevice: present(.newDevice)
        case .setupSDK: present(.setupSDK)
        case .settings: present(.settings)
        case .tasks: openTasks()
        case .toggleAppearance: setPreference("appearance", appearance == 2 ? 1 : 2)
        case .openDevice(let id):
            if devices.first(where: { $0.id == id })?.running == true { openGame(id) } else { start(id) }
        case .startDevice(let id): start(id)
        case .stopDevice(let id): stop(id)
        case .restartDevice(let id): restart(id)
        case .editDevice(let id): presentDeviceSheet(.edit, device: id)
        case .deleteDevice(let id): requestDeletion(id)
        case .deviceDetails(let id): presentDeviceSheet(.details, device: id)
        case .snapshots(let id): select(id); present(.snapshots)
        case .advancedTools(let id):
            if let name = devices.first(where: { $0.id == id })?.name { openAdvanced(id, name: name) }
        case .rootTools(let id):
            if let name = devices.first(where: { $0.id == id })?.name { openAdvanced(id, name: name, root: true) }
        case .installAPK(let id): chooseFile(device: id, apk: true)
        case .sendFile(let id): chooseFile(device: id, apk: false)
        case .screenshot(let id): screenshot(device: id)
        case .record(let id): toggleRecording(device: id)
        }
    }

    // MARK: - Device state details

    /// "Busy · in use by another client" when an active job holds the device
    /// and this center did not start it (mirrors the Slint launcher).
    func busyHolder(for device: String) -> String? {
        // Starting a device is the expected state while its window opens, not
        // an external holder (Slint excludes `device.start` the same way).
        let held = jobs.contains { job in
            job.device == device && job.isActive && job.kind != "device.start" && !ownJobs.contains(job.id)
        }
        return held ? self.text("忙碌 · 正被另一个客户端使用", "Busy · in use by another client") : nil
    }

    /// Uptime of a running device, or nil when it is not running.
    func sessionUptime(_ device: Device) -> String? {
        guard device.running, let started = device.runtime?.startedDate else { return nil }
        return Self.durationText(Int(Date().timeIntervalSince(started)), language: language)
    }

    /// Local "last started" stamp for the details window.
    func sessionStarted(_ device: Device) -> String? {
        guard let started = device.runtime?.startedDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == 0 ? "en" : "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: started)
    }

    /// "2 分 14 秒" / "2 m 14 s" (mechanism (c): the English branch is the
    /// non-Chinese branch, matching the rest of the center's number rules).
    static func durationText(_ seconds: Int) -> String {
        durationText(seconds, language: 1)
    }

    static func durationText(_ seconds: Int, language: Int) -> String {
        let total = max(0, seconds)
        if total < 60 { return language == 0 ? "\(total) s" : "\(total) 秒" }
        if total < 3600 {
            let minutes = total / 60, rest = total % 60
            return language == 0 ? "\(minutes) m \(rest) s" : "\(minutes) 分 \(rest) 秒"
        }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return language == 0 ? "\(hours) h \(minutes) m" : "\(hours) 小时 \(minutes) 分"
    }

    // MARK: - Background tasks

    /// Rows for the task list: active jobs first, then recent finished ones.
    var taskRows: [TaskRow] {
        TaskCatalog.sorted(jobs).map { job in
            let name = job.device.flatMap { id in devices.first(where: { $0.id == id })?.name }
            let step = OperationMessages.progress(job.message, language: language)
            return TaskRow(
                id: job.id,
                title: TaskCatalog.title(for: job, deviceName: name, message: step,
                                         text: { [self] chinese, english in text(chinese, english) }),
                detail: TaskCatalog.detail(for: job, step: step,
                                           text: { [self] chinese, english in text(chinese, english) }),
                progress: job.isActive ? job.progress : nil,
                tone: TaskCatalog.tone(for: job),
                cancellable: job.cancellable
            )
        }
    }

    // MARK: - APK signature conflict

    func promptReinstall(device id: String, apkPath: String) {
        let name = devices.first(where: { $0.id == id })?.name ?? id
        reinstallPrompt = ReinstallPrompt(device: id, deviceName: name, apkPath: apkPath)
    }

    /// "Uninstall and reinstall": the only way to replace an app that was
    /// signed with a different key. Uninstalling deletes its data, which the
    /// confirmation says explicitly (same flow and copy as the Slint player).
    func confirmSignatureConflictReinstall() {
        guard let prompt = reinstallPrompt else { return }
        reinstallPrompt = nil
        guard !busy.contains(prompt.device) else { return }
        busy.insert(prompt.device)
        showToast(text("正在重新安装…", "Reinstalling…"))
        func finish(_ error: Error?) {
            busy.remove(prompt.device)
            if let error {
                showError(readable(error))
            } else {
                showToast(text("已卸载并重新安装。", "Uninstalled and reinstalled."))
                refresh(); load(prompt.device); refreshJobs()
            }
        }
        call("app.inspect", ["apk": prompt.apkPath]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                finish(error)
            case .success(let value):
                guard let package = (value as? [String: Any])?["package"] as? String, !package.isEmpty else {
                    finish(CenterMessageError(message: self.text("无法读取 APK 的包名，未卸载任何应用。", "Could not read the APK package name; nothing was uninstalled.")))
                    return
                }
                self.call("app.uninstall", ["device": prompt.device, "package": package]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        finish(error)
                    case .success:
                        self.call("file.install", ["device": prompt.device, "apk": prompt.apkPath, "replace": true]) { result in
                            switch result {
                            case .failure(let error): finish(error)
                            case .success: finish(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    func cancelSignatureConflictReinstall() { reinstallPrompt = nil }
}

// MARK: - Player window launch states

extension CenterModel {
    /// The state a device window opens with: running streams immediately, a
    /// booting device shows progress, and a stopped/crashed one shows the
    /// reason plus its Start button (parity with the Slint device tab).
    func playerLaunchState(for device: Device) -> PlayerLaunchState {
        switch device.status.state {
        case "running":
            return .running
        case "starting", "booting":
            let message = progress(for: device.id) ?? text("正在启动设备…", "Starting the device…")
            return .booting(progress: bootProgressFraction(for: device.id), message: message)
        case "stopping":
            return .booting(progress: nil, message: text("正在停止设备…", "Stopping the device…"))
        case "crashed":
            return .stopped(reason: text("设备异常退出。点按启动可重新启动。", "The device crashed. Press Start to start it again."))
        case "hibernated":
            return .stopped(reason: text("设备已休眠。点按启动可唤醒。", "The device is hibernated. Press Start to wake it."))
        default:
            return .stopped(reason: text("设备已停止。点按启动可启动。", "The device is stopped. Press Start to boot it."))
        }
    }

    /// Hands a launch state to an open window once; windows already in that
    /// state are left alone so a refresh never restarts their status.
    func applyLaunchState(_ state: PlayerLaunchState, to id: String) {
        guard players[id] != nil else { return }
        guard appliedLaunch[id] != state else { return }
        appliedLaunch[id] = state
        players[id]?.transport.applyLaunchState(state)
    }

    /// Keeps open windows in sync when the device changes state elsewhere
    /// (a CLI start, a crash, a boot that finished on its own).
    func syncPlayerLaunchStates() {
        for id in players.keys {
            // A device operation the center itself started drives the window
            // directly; a stale list refresh must not override it.
            guard !busy.contains(id) else { continue }
            guard let device = devices.first(where: { $0.id == id }) else { continue }
            applyLaunchState(playerLaunchState(for: device), to: id)
        }
    }
}
