// SPDX-License-Identifier: GPL-3.0-only
// Full-root setup as the five steps of the Root sheet: the SwiftUI port of
// crates/jidr-ui/src/root/steps.rs. `root.set magisk` reports coarse job
// messages; this maps them onto the steps monotonically, classifies a
// failure and keeps the log tail. Pure logic (no SwiftUI) so it is testable.
import Foundation

/// The Root sheet's five steps, in order (crates/jidr-ui/src/root/steps.rs).
enum RootStepKind: Int, CaseIterable, Equatable {
    case download = 0
    case patch
    case reboot
    case install
    case verify

    static var count: Int { 5 }
}

/// Where a step stands (RootStepState in crates/jidr-ui/ui/root/root.slint).
enum RootStepState: Equatable {
    case done, current, waiting, failed, skipped
}

/// One row of the timeline.
struct RootStepRow: Equatable {
    let kind: RootStepKind
    let state: RootStepState
    /// Elapsed `m:ss` for the running or failed step; empty otherwise.
    let time: String
}

/// One `.logtail` line: what the job reported and when.
struct RootLogLine: Identifiable, Equatable {
    let id: UUID
    let at: Date
    let text: String
    let isError: Bool

    init(id: UUID = UUID(), at: Date, text: String, isError: Bool = false) {
        self.id = id
        self.at = at
        self.text = text
        self.isError = isError
    }
}

/// Which body the sheet shows (RootSheetState in root.slint).
enum RootSheetPhase: Equatable {
    case idle
    case progress
    /// Play Store guided tap (ADR-0002): Magisk asks to grant root to Shell.
    case grant
    case success
    case failed
    case unverified
    /// The user stopped it; the pair with a pending revert.
    case stopped
}

/// What a failed or stopped root job means (steps::Failure in the Slint UI).
struct RootFailure: Equatable {
    enum Reason: Equatable {
        case stopped
        case unverified
        case bootTimedOut(Int?)
        case downloadFailed
        case patchFailed
        case bootFailed
        case installFailed
        case verifyFailed
        case suNotRoot
        case other(String)
    }

    let reason: Reason
    let step: RootStepKind
    /// The daemon's message, for the log tail and the "details" line.
    let message: String

    var isUnverified: Bool { reason == .unverified }
    var isStopped: Bool { reason == .stopped }
}

/// How the sheet's job ended.
enum RootOutcome: Equatable {
    case rooted(version: String, seconds: Int?)
    case failed(RootFailure)
}

/// The message → step mapping, failure classification and timeline rows.
enum RootSteps {
    /// The step a `root.set magisk` job message belongs to. Unknown messages
    /// keep the current step, and steps never go back (steps.rs:18-46).
    static func step(for message: String, current: RootStepKind) -> RootStepKind {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped: RootStepKind
        if m.hasPrefix("Resolving the Magisk release")
            || m.hasPrefix("Downloading Magisk")
            || (m.hasPrefix("Magisk ") && m.contains("GPL"))
            || m.hasPrefix("正在准备 Magisk")
            || m.hasPrefix("正在下载 Magisk")
            || (m.hasPrefix("Magisk ") && m.contains("GPL")) {
            mapped = .download
        } else if m.hasPrefix("Patching the ramdisk") || m.hasPrefix("正在修补 Magisk 启动镜像") {
            mapped = .patch
        } else if m.hasPrefix("Stopping before the cold boot") || m.hasPrefix("Cold booting")
            || m.hasPrefix("正在安全停止设备，准备冷启动") || m.hasPrefix("正在冷启动设备") {
            // The first cold boot boots the patched ramdisk; the second one,
            // after the app and its environment, belongs to the install step.
            mapped = current.rawValue >= RootStepKind.install.rawValue ? .install : .reboot
        } else if m.hasPrefix("Installing the Magisk app")
            || m.hasPrefix("Setting up Magisk's environment")
            || m.hasPrefix("Play Store: open the Magisk app")
            || m.hasPrefix("正在安装 Magisk 应用")
            || m.hasPrefix("正在配置 Magisk 环境")
            || m.hasPrefix("请在设备中打开 Magisk 完成设置")
            || m == "Rebooting" || m == "正在重启设备" {
            mapped = .install
        } else if m.hasPrefix("Granting the adb shell su access")
            || isGrantPrompt(m)
            || m.hasPrefix("Verifying root")
            || m.hasPrefix("正在授予 shell root 权限")
            || m.hasPrefix("正在验证 Root 权限") {
            mapped = .verify
        } else {
            mapped = current
        }
        return mapped.rawValue > current.rawValue ? mapped : current
    }

    /// ADR-0002's guided tap: the job waits for the user to tap Grant in the
    /// Magisk prompt (steps.rs:50-53). The daemon message is English; the
    /// Chinese form is accepted for messages already translated elsewhere.
    static func isGrantPrompt(_ message: String) -> Bool {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.hasPrefix("Magisk will ask to grant root to Shell")
            || m.hasPrefix("Magisk 将在设备窗口中请求")
            || (m.hasPrefix("Magisk 将要求") && m.contains("Shell"))
    }

    /// A boot-progress line from CenterModel.progress(for:), not a job step.
    /// The boot events take over `DeviceModel.progress(for:)` while a device
    /// is not running, so the sheet treats them as the Reboot step.
    static func isBootStatus(_ message: String) -> Bool {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return (m.hasPrefix("正在启动 ") || m.hasPrefix("Starting ")) && m.hasSuffix("%")
    }

    /// `m:ss` for a number of seconds (steps.rs:108-110).
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// The last `count` log lines (steps.rs:123-125).
    static func logTail(_ lines: [RootLogLine], count: Int) -> [RootLogLine] {
        Array(lines.suffix(max(0, count)))
    }

    /// The step rows: done before `step`, running (or failed) at `step`,
    /// queued (or not run) after. A failed reboot folds Install and Verify
    /// into one row, and a success marks every row done (root/mod.rs:rows).
    static func rows(step: RootStepKind, failure: RootFailure?, verified: Bool, time: String) -> [RootStepRow] {
        if verified {
            return RootStepKind.allCases.map { RootStepRow(kind: $0, state: .done, time: "") }
        }
        var rows: [RootStepRow] = []
        for kind in RootStepKind.allCases {
            let state: RootStepState
            if kind.rawValue < step.rawValue {
                state = .done
            } else if kind == step {
                state = failure == nil ? .current : .failed
            } else {
                state = failure == nil ? .waiting : .skipped
            }
            if failure != nil && step == .reboot && kind == .verify { continue }
            rows.append(RootStepRow(kind: kind, state: state, time: kind == step ? time : ""))
        }
        return rows
    }

    /// Classifies the error a root job ended with, on the step it reached
    /// (steps.rs:69-105). The center bridge only forwards the daemon's
    /// message text, so the classification is by message content.
    static func failure(_ message: String, step: RootStepKind, grantSeen: Bool) -> RootFailure {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if m == "cancelled" || m == "操作已取消" || m.localizedCaseInsensitiveContains("cancelled") {
            return RootFailure(reason: .stopped, step: step, message: m)
        }
        if m.localizedCaseInsensitiveContains("grant to Shell was denied or timed out")
            || m.localizedCaseInsensitiveContains("awaiting_user_grant")
            || (grantSeen && (m.localizedCaseInsensitiveContains("grant") || m.contains("授权"))) {
            return RootFailure(reason: .unverified, step: .verify, message: m)
        }
        if let waited = bootTimedOut(m) {
            return RootFailure(reason: .bootTimedOut(waited), step: .reboot, message: m)
        }
        if m.contains("su -c id") || m.localizedCaseInsensitiveContains("su didn't answer as root") {
            return RootFailure(reason: .suNotRoot, step: .verify, message: m)
        }
        // The center bridge only forwards message text, and a failed root job
        // can end on an earlier step than the one that actually failed: a
        // ramdisk patch error arrives while the job still reports "download".
        // Classify the message content before falling back to the reached step.
        let patchSignals = ["parsing ramdisk", "ramdisk.img", "ramdisk", "unknown compression",
                            "boot image", "patch", "修补", "启动镜像"]
        if patchSignals.contains(where: { m.localizedCaseInsensitiveContains($0) }) {
            return RootFailure(reason: .patchFailed, step: .patch, message: m)
        }
        let downloadSignals = ["download", "http", "https", "network", "fetch", "socket",
                               "connection", "下载", "网络", "连接"]
        if downloadSignals.contains(where: { m.localizedCaseInsensitiveContains($0) }) {
            return RootFailure(reason: .downloadFailed, step: .download, message: m)
        }
        switch step {
        case .download:
            return RootFailure(reason: .downloadFailed, step: step, message: m)
        case .patch:
            return RootFailure(reason: .patchFailed, step: step, message: m)
        case .reboot:
            return RootFailure(reason: .bootFailed, step: step, message: m)
        case .install:
            return RootFailure(reason: .installFailed, step: step, message: m)
        case .verify:
            return RootFailure(reason: .verifyFailed, step: step, message: m)
        }
    }

    /// The seconds a boot timeout reports ("did not boot within 120 s"), if
    /// the message names one.
    static func bootTimedOut(_ message: String) -> Int? {
        guard message.localizedCaseInsensitiveContains("did not boot")
            || message.localizedCaseInsensitiveContains("boot_timeout")
            || message.contains("未完成启动") else { return nil }
        guard let range = message.range(of: "within ") ?? message.range(of: "等待 ") else { return 0 }
        let digits = message[range.upperBound...].prefix(while: { $0.isNumber })
        return max(0, Int(digits) ?? 0)
    }

    /// The failed step's explanation (root/mod.rs:455-468 plus the boot
    /// timeout detail from root/mod.rs:355-371). `device` is the display
    /// name and `magisk` the pinned release when known.
    static func detail(failure: RootFailure, device: String, magisk: String, language: Int) -> String {
        func t(_ zh: String, _ en: String) -> String { language == 0 ? en : zh }
        switch failure.reason {
        case .stopped:
            return t("已停止 Root 配置。", "Root setup stopped.")
        case .unverified:
            return t("Shell 未获得 Root 授权，因此无法确认 \(device) 已 Root。请重试并在设备窗口中点按“允许”，或回退到无 Root。数据未受影响。",
                     "Shell wasn't granted root, so Jidr can't say \(device) is rooted. Try again and tap Grant, or revert to unrooted. Your data is intact.")
        case .bootTimedOut(let waited):
            if let waited, waited > 0 {
                return t("\(device) 在重启后未在 \(waited) 秒内完成启动。数据未受影响，原始启动镜像已保留，因此可以回退。",
                         "\(device) didn't finish booting after the reboot (waited \(waited) s). Your data is intact and the original boot image is kept, so you can revert.")
            }
            return t("\(device) 在重启后未完成启动。数据未受影响，原始启动镜像已保留，因此可以回退。",
                     "\(device) didn't finish booting after the reboot. Your data is intact and the original boot image is kept, so you can revert.")
        case .downloadFailed:
            return t("无法下载 Magisk \(magisk)。\(device) 未发生任何更改；请检查网络后重试。",
                     "Couldn't download Magisk \(magisk). Nothing on \(device) changed; check the connection and try again.")
        case .patchFailed:
            return t("无法修补启动镜像。\(device) 未发生更改。", "Couldn't patch the boot image. \(device) is unchanged.")
        case .bootFailed:
            return t("\(device) 在重启后未能启动。你的数据完好，原始启动镜像已保留，因此可以回退。",
                     "\(device) didn't finish booting after the reboot. Your data is intact and the original boot image is kept, so you can revert.")
        case .installFailed:
            return t("无法在 \(device) 上安装 Magisk 应用。你的数据完好，原始启动镜像已保留，因此可以回退。",
                     "Couldn't install the Magisk app on \(device). Your data is intact and the original boot image is kept, so you can revert.")
        case .suNotRoot:
            return t("\(device) 上的 su 未以 Root 身份响应。你的数据完好，原始启动镜像已保留，因此可以回退。",
                     "su didn't answer as root on \(device). Your data is intact and the original boot image is kept, so you can revert.")
        case .verifyFailed:
            return t("root 验证未通过。你的数据完好，原始启动镜像已保留，因此可以回退。",
                     "Root verification failed. Your data is intact and the original boot image is kept, so you can revert.")
        case .other(let message):
            return message
        }
    }
}

/// The Root sheet's job, from the first progress message to the result
/// (the Sheet struct in root/mod.rs, minus the UI handles). Pure: the store
/// feeds it `CenterModel` samples and renders it.
struct RootFlowEngine: Equatable {
    var started: Date
    var step: RootStepKind = .download
    var stepStarted: Date
    var log: [RootLogLine] = []
    var lastMessage = ""
    /// The latest boot-progress line (not a step of the job itself).
    var bootStatus = ""
    /// ADR-0002: the guided tap started at.
    var grantSince: Date?
    /// The user pressed "Stop and revert".
    var stopRequested = false
    var outcome: RootOutcome?

    init(now: Date) {
        started = now
        stepStarted = now
    }

    /// Seeds the engine from an already-finished `CenterModel.fullRoot` state
    /// (the sheet can be reopened from the device card).
    mutating func seed(verifiedVersion: String?, failureMessage: String?, at now: Date) {
        if let version = verifiedVersion {
            outcome = .rooted(version: version, seconds: nil)
        } else if let message = failureMessage {
            outcome = .failed(RootSteps.failure(message, step: step, grantSeen: grantSince != nil))
        }
    }

    /// One `CenterModel.progress(for:)` sample.
    mutating func observe(_ raw: String, at now: Date) {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message != lastMessage else { return }
        lastMessage = message
        if RootSteps.isBootStatus(message) {
            bootStatus = message
            if step.rawValue < RootStepKind.reboot.rawValue {
                step = .reboot
                stepStarted = now
            }
            return
        }
        bootStatus = ""
        let next = RootSteps.step(for: message, current: step)
        if next != step {
            step = next
            stepStarted = now
        }
        if RootSteps.isGrantPrompt(message), grantSince == nil {
            grantSince = now
        }
        log.append(RootLogLine(at: now, text: message))
    }

    /// The job finished successfully.
    mutating func rooted(version: String, at now: Date) {
        guard outcome == nil else { return }
        outcome = .rooted(version: version, seconds: Int(now.timeIntervalSince(started)))
    }

    /// The job failed or was cancelled. Cancelling the guided tap reads as
    /// "unverified", not "failed" (root/mod.rs:296-300).
    mutating func failed(_ message: String, at now: Date) {
        guard outcome == nil else { return }
        var failure = RootSteps.failure(message, step: step, grantSeen: grantSince != nil)
        if failure.isStopped && grantSince != nil {
            failure = RootFailure(reason: .unverified, step: .verify, message: failure.message)
        }
        log.append(RootLogLine(at: now, text: failure.message, isError: true))
        outcome = .failed(failure)
    }

    /// The elapsed seconds of the running (or failed) step.
    func stepSeconds(at now: Date) -> Int {
        Int(now.timeIntervalSince(stepStarted))
    }

    /// The guided tap's remaining seconds (ADR-0002: 60 s).
    func grantSecondsLeft(at now: Date) -> Int {
        guard let since = grantSince else { return 60 }
        return max(0, 60 - Int(now.timeIntervalSince(since)))
    }
}
