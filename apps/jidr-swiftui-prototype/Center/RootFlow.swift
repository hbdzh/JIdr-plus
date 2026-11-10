// SPDX-License-Identifier: GPL-3.0-only
// Full-root setup sheet: the five-step timeline, the log tail, "Stop and
// revert" and the Play Store guided tap (ADR-0002), ported from
// crates/jidr-ui/src/root/root.slint + src/root/mod.rs. The state machine is
// RootSteps.swift; this file binds it to CenterModel and draws it.
import AppKit
import Combine
import SwiftUI

// MARK: - CenterModel helpers

/// Root-flow copy and the job lookups the tracker needs. Kept as an extension
/// so CenterModel.swift (a different work line) is untouched.
extension CenterModel {
    /// A root job message shown in the timeline's log tail. The bridge
    /// forwards raw daemon messages (English) and OperationMessages.progress
    /// output, so known English messages get a Chinese counterpart; anything
    /// else (URLs, licence notices, unknown diagnostics) is shown as it came.
    func rootLogText(_ raw: String) -> String {
        guard language != 0 else { return raw }
        if raw.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return raw }
        let exact: [(String, String)] = [
            ("Magisk will ask to grant root to Shell. Tap Grant in the device window.",
             "Magisk 将在设备窗口中请求为 Shell 授予 Root 权限。请在设备窗口中点按“允许”。"),
            ("root grant to Shell was denied or timed out; tap Grant and try again, or revert",
             "Shell 未获得 Root 授权（被拒绝或等待超时）；请点按“允许”后重试，或回退到无 Root。"),
            ("cancelled", "已取消"),
        ]
        for (english, chinese) in exact where raw == english { return chinese }
        let pairs: [(String, String)] = [
            ("Resolving the Magisk release", "正在准备 Magisk 安装包"),
            ("Downloading Magisk ", "正在下载 Magisk "),
            ("Patching the ramdisk for Magisk ", "正在修补 Magisk 启动镜像 "),
            ("Stopping before the cold boot", "正在安全停止设备，准备冷启动"),
            ("Cold booting", "正在冷启动设备"),
            ("Installing the Magisk app", "正在安装 Magisk 应用"),
            ("Setting up Magisk's environment", "正在配置 Magisk 环境"),
            ("Play Store: open the Magisk app", "请在设备中打开 Magisk 完成设置，然后为 Shell 授权"),
            ("Rebooting", "正在重启设备"),
            ("Granting the adb shell su access", "正在授予 shell root 权限"),
            ("Verifying root", "正在验证 Root 权限"),
            ("Magisk will ask to grant root to Shell", "Magisk 将在设备窗口中请求为 Shell 授予 Root 权限。请在设备窗口中点按“允许”。"),
        ]
        for (english, chinese) in pairs where raw.hasPrefix(english) {
            return chinese + raw.dropFirst(english.count)
        }
        return raw
    }

    /// The five step titles (root.slint:172-178), with the pinned release.
    func rootStepTitle(_ kind: RootStepKind, magisk: String) -> String {
        switch kind {
        case .download: return text("下载 Magisk \(magisk)", "Download Magisk \(magisk)")
        case .patch: return text("修补启动镜像", "Patch boot image")
        case .reboot: return text("重启", "Reboot")
        case .install: return text("安装 Magisk 应用", "Install Magisk app")
        case .verify: return text("验证", "Verify")
        }
    }

    /// The line under a step (root.slint:179-184).
    func rootStepSubtitle(_ kind: RootStepKind, state: RootStepState) -> String {
        switch kind {
        case .download: return ""
        case .patch: return text("原始镜像已保留，可回退", "Original kept for revert")
        case .reboot:
            switch state {
            case .current: return text("等待 Android 报告启动完成", "Waiting for Android to report boot complete")
            case .failed: return text("未收到启动完成报告", "Boot complete never reported")
            default: return ""
            }
        case .install: return ""
        case .verify: return "su -c id"
        }
    }

    /// The failure reason after "Root 失败：" (steps.rs failure.reason).
    func rootFailureReason(_ failure: RootFailure) -> String {
        switch failure.reason {
        case .stopped: return text("已停止", "stopped")
        case .unverified: return text("Shell 未被授予 Root 权限", "Shell wasn't granted root")
        case .bootTimedOut: return text("启动超时", "boot timed out")
        case .downloadFailed: return text("下载失败", "download failed")
        case .patchFailed: return text("修补启动镜像失败", "patch step failed")
        case .bootFailed: return text("启动失败", "boot failed")
        case .installFailed: return text("Magisk 应用安装失败", "Magisk app install failed")
        case .suNotRoot: return text("su 未以 Root 身份响应", "su didn't answer as root")
        case .verifyFailed: return text("验证失败", "verification failed")
        case .other(let message): return message
        }
    }

    /// The step clock, e.g. "0:18".
    func rootClock(_ seconds: Int) -> String { RootSteps.clock(seconds) }

    /// The running `root.set` job for a device, for "Stop and revert".
    /// The center protocol's job events carry the job id, but CenterModel
    /// keeps those internal, so ask `jobs.list` instead.
    func findRootJob(device: String, done: @escaping (String?) -> Void) {
        call("jobs.list", ["all": false]) { result in
            guard case .success(let value) = result,
                  let jobs = try? self.decode(value, as: [RootJobRef].self) else { done(nil); return }
            let match = jobs.first(where: { job in
                job.kind == "root.set" && job.device == device && ["pending", "running"].contains(job.state)
            })
            done(match?.id)
        }
    }
}

/// A `jobs.list` row (jidr_core::model::Job, only the fields the sheet needs).
struct RootJobRef: Decodable {
    let id: String
    let kind: String
    let device: String?
    let state: String
}

// MARK: - Tracker

/// The Root sheet's job, fed from CenterModel's published state. One store per
/// sheet; the model can also be reattached after "Continue in background".
final class RootFlowStore: ObservableObject {
    private let model: CenterModel
    private let id: String
    private let name: String
    private var engine: RootFlowEngine
    @Published private(set) var presentation = RootFlowPresentation()
    @Published private(set) var closeRequested = false
    private var timer: Timer?
    private var modelObserver: AnyCancellable?
    private var revertAfterStop = false

    init(model: CenterModel, target: RootPresentation) {
        self.model = model
        self.id = target.id
        self.name = target.name
        engine = RootFlowEngine(now: Date())
        switch model.fullRoot[id] {
        case .verified(let version): engine.seed(verifiedVersion: version, failureMessage: nil, at: Date())
        case .failed(let message): engine.seed(verifiedVersion: nil, failureMessage: message, at: Date())
        case .running, nil: break
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        modelObserver?.cancel()
    }

    /// Starts following CenterModel while the sheet is visible: every model
    /// change (each progress message is one) is sampled immediately, and a
    /// one-second timer keeps the step clocks and the grant countdown fresh.
    func attach() {
        guard timer == nil else { return }
        sample()
        modelObserver = model.objectWillChange.sink { [weak self] _ in
            // Published values change after objectWillChange fires.
            DispatchQueue.main.async { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        modelObserver?.cancel()
        modelObserver = nil
    }

    private func tick() {
        sample()
        refresh()
    }

    /// Reads the job's latest message and its outcome from the model.
    private func sample() {
        let now = Date()
        if let state = model.fullRoot[id], engine.outcome == nil {
            switch state {
            case .verified(let version): engine.rooted(version: version, at: now)
            case .failed(let message): engine.failed(message, at: now)
            case .running: break
            }
        }
        if engine.outcome == nil, let message = model.progress(for: id) {
            engine.observe(message, at: now)
        }
        if case .failed(let failure) = engine.outcome, failure.isStopped, revertAfterStop {
            revertAfterStop = false
            revertToUnrooted()
            closeRequested = true
        }
    }

    // MARK: actions

    /// "Stop and revert": cancel the job, then set the root mode back to none.
    func stopAndRevert() {
        guard engine.outcome == nil, !engine.stopRequested else { return }
        engine.stopRequested = true
        revertAfterStop = true
        model.findRootJob(device: id) { [weak self] job in
            guard let self else { return }
            guard let job else {
                self.model.notice = self.model.text("没有找到正在进行的 Root 任务；请稍后在设备详情中回退。",
                                                    "Couldn't find the running root job; revert from the device details.")
                self.revertAfterStop = false
                return
            }
            self.model.call("jobs.cancel", ["job": job]) { [weak self] result in
                if case .failure(let error) = result {
                    self?.model.notice = OperationMessages.error(error.localizedDescription, language: self?.model.language ?? 1)
                }
            }
        }
    }

    /// The guided tap's Cancel: stop the wait without reverting; the sheet
    /// then shows the unverified state (ADR-0002).
    func cancelGrant() {
        guard engine.outcome == nil else { return }
        engine.stopRequested = true
        model.findRootJob(device: id) { [weak self] job in
            guard let self, let job else { return }
            self.model.call("jobs.cancel", ["job": job]) { [weak self] result in
                if case .failure(let error) = result {
                    self?.model.notice = OperationMessages.error(error.localizedDescription, language: self?.model.language ?? 1)
                }
            }
        }
    }

    /// "Try again": run the whole setup again.
    func retry() {
        guard !model.busy.contains(id) else { return }
        engine = RootFlowEngine(now: Date())
        closeRequested = false
        revertAfterStop = false
        model.setupFullRoot(id, name: name)
        sample()
        refresh()
    }

    /// "Revert to unrooted" from the failed/unverified body.
    func revertToUnrooted() {
        model.operation("root.set", id: id, params: ["mode": "none"])
    }

    /// The log tail, ready for the pasteboard.
    func copyLog() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines = engine.log.map { "\(formatter.string(from: $0.at))  jidr  \($0.text)" }
        if case .failed(let failure) = engine.outcome {
            lines.append("\(model.text("Root 失败", "Root failed")): \(model.rootFailureReason(failure))")
        }
        return lines.joined(separator: "\n")
    }

    /// Called after a successful snapshot save from the success footer.
    func snapshotSaved() {
        model.refresh()
        model.notice = model.text("快照已保存。", "Snapshot saved.")
    }

    // MARK: presentation

    private func refresh() {
        let now = Date()
        var p = RootFlowPresentation()
        let device = model.devices.first(where: { $0.id == id })
        p.deviceName = name
        p.serial = device?.runtime?.adb_serial ?? ""
        p.playStore = device?.image.tag.contains("playstore") ?? false
        p.canOpenPlayer = device?.running == true
        p.magisk = "30.7"
        p.stepCount = RootStepKind.count
        switch engine.outcome {
        case .rooted(let version, let seconds):
            p.phase = .success
            if !version.isEmpty { p.magisk = version }
            p.steps = RootSteps.rows(step: .verify, failure: nil, verified: true, time: "")
            p.stepIndex = p.stepCount
            p.took = seconds.map { model.rootClock($0) } ?? "—"
            p.suOutput = "uid=0(root) gid=0(root)"
        case .failed(let failure):
            p.reason = model.rootFailureReason(failure)
            p.detail = RootSteps.detail(failure: failure, device: name, magisk: p.magisk, language: model.language)
            p.stepIndex = failure.step.rawValue + 1
            p.steps = RootSteps.rows(step: failure.step, failure: failure, verified: false,
                                     time: model.rootClock(engine.stepSeconds(at: now)))
            p.log = RootSteps.logTail(engine.log, count: 4)
            p.phase = failure.isUnverified ? .unverified : failure.isStopped ? .stopped : .failed
        case nil:
            p.log = RootSteps.logTail(engine.log, count: 4)
            if engine.grantSince != nil {
                p.phase = .grant
                p.steps = RootSteps.rows(step: .verify, failure: nil, verified: false,
                                         time: model.rootClock(engine.stepSeconds(at: now)))
                p.grantLeft = "\(engine.grantSecondsLeft(at: now)) s"
            } else {
                p.phase = .progress
                p.steps = RootSteps.rows(step: engine.step, failure: nil, verified: false,
                                         time: model.rootClock(engine.stepSeconds(at: now)))
                p.stepIndex = engine.step.rawValue + 1
                p.elapsed = model.rootClock(Int(now.timeIntervalSince(engine.started)))
                p.currentText = engine.bootStatus.isEmpty
                    ? model.rootLogText(engine.lastMessage)
                    : engine.bootStatus
            }
        }
        if p != presentation { presentation = p }
    }
}

/// Everything the sheet shows, computed once a second.
struct RootFlowPresentation: Equatable {
    var phase: RootSheetPhase = .idle
    var deviceName = ""
    var serial = ""
    var playStore = false
    var magisk = "30.7"
    var steps: [RootStepRow] = []
    var log: [RootLogLine] = []
    var stepIndex = 1
    var stepCount = 5
    var reason = ""
    var detail = ""
    var suOutput = ""
    var took = ""
    var grantLeft = ""
    var currentText = ""
    var elapsed = ""
    var canOpenPlayer = false
}

// MARK: - The sheet

struct FullRootView: View {
    @ObservedObject var model: CenterModel
    let target: RootPresentation
    @StateObject private var store: RootFlowStore
    @Environment(\.dismiss) private var dismiss
    @State private var showSteps = false
    @State private var confirmRevert = false
    @State private var showSnapshotSave = false

    init(model: CenterModel, target: RootPresentation) {
        self.model = model
        self.target = target
        _store = StateObject(wrappedValue: RootFlowStore(model: model, target: target))
    }

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }
    private var snapshotDevice: Device? { model.devices.first(where: { $0.id == target.id }) }

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.zero) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: WbSpace.lg) {
                    hero
                    if presentation.phase == .success {
                        if showSteps { stepsBlock }
                    } else if presentation.phase != .idle, !presentation.steps.isEmpty {
                        stepsBlock
                    }
                    if presentation.phase == .success { proofBlock; integrityBanner }
                    if presentation.phase == .progress {
                        progressBlock
                        if !presentation.log.isEmpty {
                            logTailBlock(RootSteps.logTail(presentation.log, count: 3),
                                         title: t("最近步骤", "Recent steps"))
                        }
                    }
                    if presentation.phase == .grant { grantBlock }
                    if presentation.phase == .failed || presentation.phase == .unverified { failureBlocks }
                    if presentation.phase == .idle {
                        Label(t("没有正在进行的 Root 配置。", "No root setup is running."), systemImage: WbIcon.info)
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }.padding(WbSpace.xl)
            }.frame(minHeight: 260, idealHeight: 520, maxHeight: 580)
            Divider()
            footer
        }
        .frame(width: 600)
        .tint(WbColor.accent)
        .onAppear { store.attach() }
        .onDisappear { store.detach() }
        .onChange(of: store.closeRequested) { _, close in if close { dismiss() } }
        .alert(t("回退到无 Root？", "Revert to unrooted?"), isPresented: $confirmRevert) {
            Button(t("取消", "Cancel"), role: .cancel) { }
            Button(t("回退", "Revert"), role: .destructive) { store.revertToUnrooted(); dismiss() }
        } message: {
            Text(t("将移除 Magisk 并冷启动设备，可能需要一些时间。游戏数据不受影响，但请先保存进度。",
                   "Magisk is removed and the device cold-boots, which can take a while. Your game data is kept, but save your progress first."))
        }
        .sheet(isPresented: $showSnapshotSave) {
            if let device = snapshotDevice {
                SnapshotSaveDialog(model: model, device: device, magiskVersion: presentation.magisk) { _ in
                    showSnapshotSave = false
                    store.snapshotSaved()
                }
                .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
            }
        }
    }

    private var presentation: RootFlowPresentation { store.presentation }

    // MARK: header

    private var header: some View {
        HStack(spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: WbSpace.xxs) {
                Text(t("完整 Root · \(presentation.deviceName)", "Full root · \(presentation.deviceName)"))
                    .wbFont(WbType.title)
                if !presentation.serial.isEmpty {
                    Text(presentation.serial).wbFont(WbType.code)
                        .foregroundStyle(WbColor.textSecondary)
                }
            }
            Spacer()
            if presentation.playStore {
                Text(t("Beta · Play 商店镜像", "Beta · Play Store image"))
                    .wbFont(WbType.caption.weighted(.medium)).foregroundStyle(WbColor.warning)
                    .padding(.horizontal, WbSpace.sm).padding(.vertical, WbSpace.xs)
                    .background(WbStatus.warning.container, in: Capsule())
            }
            Button(t("关闭", "Close")) { dismiss() }
        }.padding(WbSpace.lg)
    }

    // MARK: hero

    private var seal: some View {
        let (symbol, status): (String, WbStatusColor) = {
            switch presentation.phase {
            case .success: return (WbIcon.rootVerified, WbStatus.positive)
            case .failed: return (WbIcon.errorCircle, WbStatus.negative)
            case .unverified: return (WbIcon.rootUnverified, WbStatus.warning)
            case .stopped: return (WbIcon.stopped, WbStatus.neutral)
            case .grant: return (WbIcon.rootKey, WbStatus.warning)
            default: return (WbIcon.rootKey, WbStatus.transition)
            }
        }()
        return Image(systemName: symbol).font(.system(size: WbType.hero.size, weight: WbType.hero.weight))
            .foregroundStyle(status.onContainer)
            .frame(width: 72, height: 72)
            .background(status.container, in: RoundedRectangle(cornerRadius: WbRadius.xl))
    }

    private var headline: String {
        switch presentation.phase {
        case .progress: return t("正在配置 Root…", "Setting up root…")
        case .grant: return t("请在设备窗口中点按“允许”", "Tap Grant on the device")
        case .success: return t("Root 已就绪", "Rooted")
        case .failed: return t("Root 配置失败", "Root failed")
        case .unverified: return t("Root 未验证", "Root unverified")
        case .stopped: return t("已停止", "Stopped")
        case .idle: return t("Root 配置", "Root setup")
        }
    }

    private var badge: String {
        switch presentation.phase {
        case .progress: return t("正在配置 Root… · 第 \(presentation.stepIndex) / \(presentation.stepCount) 步",
                                 "Setting up root… · step \(presentation.stepIndex) of \(presentation.stepCount)")
        case .grant: return t("正在配置 Root… · 第 5 / 5 步", "Setting up root… · step 5 of 5")
        case .success: return t("Root 已就绪 · Magisk \(presentation.magisk)", "Rooted · Magisk \(presentation.magisk)")
        case .failed: return t("Root 失败：\(presentation.reason)", "Root failed: \(presentation.reason)")
        case .unverified: return t("Shell 未被授予 Root 权限", "Shell wasn't granted root")
        case .stopped: return t("已停止 Root 配置", "Root setup stopped")
        case .idle: return ""
        }
    }

    private var explanation: String {
        switch presentation.phase {
        case .progress:
            return t("重启设备完成 Root 配置（约 40 秒）。请保持运行；也可以关闭本面板，配置会继续。",
                     "Reboots the device to finish root setup (about 40 s). Leave it running; you can close this sheet.")
        case .grant:
            return t("Magisk 将要求为 Shell 授予 Root 权限。请在设备窗口中点按“允许”。Jidr 还会等待 \(presentation.grantLeft)；“永久允许”由你决定。",
                     "Magisk will ask to grant root to Shell. Tap Grant in the device window. Jidr waits \(presentation.grantLeft) more; \"Forever\" is up to you.")
        case .success:
            return t("Jidr 已确认 su 确实以 Root 身份响应，因此才显示“已就绪”。",
                     "Jidr checked that su really answers as root before saying so.")
        case .failed, .unverified, .idle:
            return presentation.detail
        case .stopped:
            return t("正在停止并回退到无 Root…", "Stopping and reverting to unrooted…")
        }
    }

    private var hero: some View {
        VStack(spacing: WbSpace.md) {
            HStack { Spacer(); seal; Spacer() }
            Text(headline).wbFont(WbType.headline)
            if !badge.isEmpty {
                Text(badge).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if !explanation.isEmpty {
                Text(explanation).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity)
    }

    // MARK: steps

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.zero) {
            ForEach(Array(presentation.steps.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, WbSpace.xxxl) }
                stepRow(row)
            }
        }
        .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderDefault, lineWidth: WbBorder.hairline))
    }

    private func stepRow(_ row: RootStepRow) -> some View {
        HStack(spacing: WbSpace.md) {
            stepIcon(row)
            VStack(alignment: .leading, spacing: WbSpace.xxs) {
                Text(model.rootStepTitle(row.kind, magisk: presentation.magisk))
                    .wbFont(WbType.body.weighted(row.state == .current || row.state == .failed ? .semibold : .regular))
                    .foregroundStyle(row.state == .waiting || row.state == .skipped ? WbColor.textSecondary : WbColor.textPrimary)
                let subtitle = model.rootStepSubtitle(row.kind, state: row.state)
                if !subtitle.isEmpty {
                    Text(subtitle).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                }
            }
            Spacer()
            if !row.time.isEmpty {
                Text(row.time).wbFont(WbType.code)
                    .foregroundStyle(row.state == .failed ? WbColor.negative : WbColor.textSecondary)
            }
            switch row.state {
            case .done: Text(t("已完成", "Done")).wbFont(WbType.caption).foregroundStyle(WbStatus.jobDone.onContainer)
            case .current: Text(t("进行中", "Running")).wbFont(WbType.caption).foregroundStyle(WbStatus.jobRunning.onContainer)
            case .waiting: Text(t("排队中", "Queued")).wbFont(WbType.caption).foregroundStyle(WbStatus.jobQueued.onContainer)
            case .failed: Text(t("失败", "Failed")).wbFont(WbType.caption).foregroundStyle(WbStatus.jobFailed.onContainer)
            case .skipped: Text(t("未执行", "Not run")).wbFont(WbType.caption).foregroundStyle(WbStatus.jobCancelled.onContainer)
            }
        }.padding(.horizontal, WbSpace.lg).padding(.vertical, row.state == .current || row.state == .failed ? 10 : 8)
            .background(row.state == .current ? WbStatus.transition.container
                        : row.state == .failed ? WbStatus.negative.container : Color.clear)
    }

    @ViewBuilder
    private func stepIcon(_ row: RootStepRow) -> some View {
        switch row.state {
        case .done: Image(systemName: WbIcon.checkCircleFill).foregroundStyle(WbColor.positive)
        case .current: ProgressView().controlSize(.small).frame(width: 18, height: 18)
        case .waiting: Image(systemName: WbIcon.progressRing).foregroundStyle(WbColor.textSecondary)
        case .failed: Image(systemName: WbIcon.errorCircle).foregroundStyle(WbColor.negative)
        case .skipped: Image(systemName: WbIcon.minusCircle).foregroundStyle(WbColor.textSecondary)
        }
    }

    // MARK: state blocks

    private var progressBlock: some View {
        HStack(spacing: WbSpace.sm) {
            ProgressView().controlSize(.small)
            Text(presentation.currentText.isEmpty ? t("正在准备…", "Preparing…") : presentation.currentText)
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).lineLimit(2)
            Spacer()
            Text(presentation.elapsed).wbFont(WbType.code).foregroundStyle(WbColor.textSecondary)
        }
        .padding(WbSpace.md)
        .background(WbColor.sunken, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private var grantBlock: some View {
        HStack(spacing: WbSpace.md) {
            Image(systemName: WbIcon.tap).foregroundStyle(WbColor.warning)
            Text(t("等待你点按“允许”：还剩 \(presentation.grantLeft)", "Waiting for your tap: \(presentation.grantLeft) left"))
                .wbFont(WbType.body.weighted(.medium))
            Spacer()
        }
        .padding(WbSpace.md)
        .background(WbStatus.warning.container, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private var proofBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            proofRow(t("检查", "Check"), "su -c id → \(presentation.suOutput)")
            proofRow(t("Magisk", "Magisk"), t("\(presentation.magisk) · 应用已安装", "\(presentation.magisk) · app installed"))
            proofRow(t("启动镜像", "Boot image"), t("已修补 · 原始镜像已保留", "patched · original kept"))
            proofRow(t("耗时", "Took"), t("\(presentation.took) · 5 / 5 步", "\(presentation.took) · 5 of 5 steps"))
        }
        .padding(WbSpace.md)
        .background(WbColor.sunken, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private func proofRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).frame(width: 80, alignment: .leading)
            Text(value).wbFont(WbType.code).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var integrityBanner: some View {
        HStack(alignment: .top, spacing: WbSpace.sm) {
            Image(systemName: WbIcon.integrity).foregroundStyle(WbColor.warning)
            Text(presentation.playStore
                 ? t("已 Root 的模拟器无法通过 Play Integrity。一旦 Root，Play 商店里的银行应用和部分游戏会拒绝运行。",
                     "Rooted emulators can't pass Play Integrity. Banking apps and some games from the Play Store will refuse to run once it is rooted.")
                 : t("已 Root 的模拟器无法通过 Play Integrity。会检查该状态的应用将拒绝运行。",
                     "Rooted emulators can't pass Play Integrity. Apps that check it will refuse to run."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.warning)
        }
        .padding(WbSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WbStatus.warning.container, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private func logTailBlock(_ lines: [RootLogLine], title: String) -> some View {
        VStack(alignment: .leading, spacing: WbSpace.xxs) {
            Text(title).wbFont(WbType.label.weighted(.semibold)).foregroundStyle(WbColor.textSecondary)
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: WbSpace.sm) {
                    Text(Self.logTime.string(from: line.at))
                        .wbFont(WbType.code).foregroundStyle(WbColor.textSecondary)
                    Text(model.rootLogText(line.text))
                        .wbFont(WbType.code)
                        .foregroundStyle(line.isError ? WbColor.negative : WbColor.textPrimary)
                        .lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(WbSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WbColor.sunken, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private var failureBlocks: some View {
        VStack(alignment: .leading, spacing: WbSpace.md) {
            if !presentation.log.isEmpty {
                logTailBlock(presentation.log, title: t("日志尾", "Log tail"))
            }
            if presentation.phase == .failed, !presentation.steps.isEmpty {
                Text(t("在第 \(presentation.stepIndex) / \(presentation.stepCount) 步停止。数据未受影响，可以重试或回退到无 Root。",
                       "Stopped at step \(presentation.stepIndex) of \(presentation.stepCount). Your data is intact; try again or revert to unrooted."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            }
        }
    }

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: WbSpace.sm) {
            switch presentation.phase {
            case .progress:
                Button(t("停止并回退", "Stop and revert"), role: .destructive) { store.stopAndRevert() }
                Spacer()
                Button(t("在后台继续", "Continue in background")) { dismiss() }
            case .grant:
                Button(t("取消", "Cancel"), role: .destructive) { store.cancelGrant() }
                Spacer()
                Button(t("在后台继续", "Continue in background")) { dismiss() }
            case .success:
                Button(showSteps ? t("隐藏步骤", "Hide steps") : t("显示步骤", "Show steps")) { showSteps.toggle() }
                if presentation.canOpenPlayer {
                    Button(t("打开设备窗口", "Open device window")) { model.openGame(target.id) }
                }
                Spacer()
                if snapshotDevice != nil {
                    Button(t("保存快照…", "Save snapshot…")) { showSnapshotSave = true }
                }
                Button(t("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button(t("复制日志", "Copy log")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(store.copyLog(), forType: .string)
                    model.notice = t("已复制 Root 配置日志。", "Copied the root setup log.")
                }
                Spacer()
                Button(t("回退到无 Root", "Revert to unrooted"), role: .destructive) { confirmRevert = true }
                Button(t("重试", "Try again")) { store.retry() }.keyboardShortcut(.defaultAction)
            case .unverified:
                Spacer()
                Button(t("回退到无 Root", "Revert to unrooted"), role: .destructive) { confirmRevert = true }
                Button(t("重试", "Try again")) { store.retry() }.keyboardShortcut(.defaultAction)
            case .stopped:
                Spacer()
                ProgressView().controlSize(.small)
                Text(t("正在回退…", "Reverting…")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            case .idle:
                Spacer()
                Button(t("关闭", "Close")) { dismiss() }
            }
        }
        .padding(WbSpace.lg)
        .background(WbColor.chrome)
    }
}
