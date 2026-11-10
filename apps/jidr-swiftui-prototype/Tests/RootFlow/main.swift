// SPDX-License-Identifier: GPL-3.0-only
// Offline checks for the Root sheet's state machine (Center/RootSteps.swift),
// mirroring crates/jidr-ui/src/root/steps.rs's tests. No SwiftUI, no daemon.
import Foundation

let t0 = Date(timeIntervalSince1970: 1_760_000_000)

// The messages `root.set magisk` reports on a google_apis image, in order.
let googleApis: [(String, RootStepKind)] = [
    ("Resolving the Magisk release", .download),
    ("Magisk 30.7 is GPL-3.0-only; source: https://github.com/topjohnwu/Magisk.", .download),
    ("Downloading Magisk 30.7", .download),
    ("Patching the ramdisk for Magisk 30.7", .patch),
    ("Stopping before the cold boot", .reboot),
    ("Cold booting", .reboot),
    ("Installing the Magisk app", .install),
    ("Setting up Magisk's environment", .install),
    ("Rebooting", .install),
    ("Stopping before the cold boot", .install),
    ("Cold booting", .install),
    ("Granting the adb shell su access", .verify),
    ("Verifying root", .verify),
]
var step = RootStepKind.download
for (message, want) in googleApis {
    let next = RootSteps.step(for: message, current: step)
    assert(next == want, "\(message): got \(next), want \(want)")
    step = next
}

// The center bridge forwards OperationMessages.progress output in Chinese.
let chinese: [(String, RootStepKind)] = [
    ("正在准备 Magisk 安装包", .download),
    ("正在下载 Magisk 30.7", .download),
    ("正在修补 Magisk 启动镜像 30.7", .patch),
    ("正在安全停止设备，准备冷启动", .reboot),
    ("正在冷启动设备", .reboot),
    ("正在安装 Magisk 应用", .install),
    ("正在配置 Magisk 环境", .install),
    ("正在重启设备", .install),
    ("正在授予 shell root 权限", .verify),
    ("正在验证 Root 权限", .verify),
]
step = .download
for (message, want) in chinese {
    let next = RootSteps.step(for: message, current: step)
    assert(next == want, "\(message): got \(next), want \(want)")
    step = next
}

// Steps never go back, and a cached patch skips straight to the cold boot.
assert(RootSteps.step(for: "Downloading Magisk 30.7", current: .install) == .install)
assert(RootSteps.step(for: "something new", current: .reboot) == .reboot)
assert(RootSteps.step(for: "Cold booting", current: .download) == .reboot)

// The Play Store guided tap (ADR-0002).
assert(RootSteps.isGrantPrompt("Magisk will ask to grant root to Shell. Tap Grant in the device window."))
assert(!RootSteps.isGrantPrompt("Verifying root"))
assert(RootSteps.step(for: "Magisk will ask to grant root to Shell. Tap Grant in the device window.", current: .install) == .verify)

// Boot-progress lines are status, not job steps.
assert(RootSteps.isBootStatus("正在启动 62%"))
assert(RootSteps.isBootStatus("Starting 62%"))
assert(!RootSteps.isBootStatus("Cold booting"))

// Rows: done before the step, running at it, queued after.
let running = RootSteps.rows(step: .reboot, failure: nil, verified: false, time: "0:18")
assert(running.map(\.state) == [.done, .done, .current, .waiting, .waiting])
assert(running[2].time == "0:18" && running[1].time.isEmpty)
let verified = RootSteps.rows(step: .verify, failure: nil, verified: true, time: "")
assert(verified.allSatisfy { $0.state == .done })

// A failed reboot folds Install and Verify into one row (root/mod.rs:rows).
let boot = RootSteps.failure("jidr-pixel did not boot within 120 s (boot); see log", step: .reboot, grantSeen: false)
assert(boot.reason == .bootTimedOut(120))
assert(!boot.isUnverified && !boot.isStopped)
let failedRows = RootSteps.rows(step: .reboot, failure: boot, verified: false, time: "2:00")
assert(failedRows.count == 4)
assert(failedRows[2].state == .failed)
assert(failedRows[3] == RootStepRow(kind: .install, state: .skipped, time: ""))

// Classification of the other endings.
let grant = RootSteps.failure("root grant to Shell was denied or timed out; tap Grant and try again, or revert", step: .verify, grantSeen: true)
assert(grant.isUnverified && grant.step == .verify)
let stopped = RootSteps.failure("cancelled", step: .patch, grantSeen: false)
assert(stopped.isStopped)
let su = RootSteps.failure("dev: `su -c id` reported uid 2000, expected 0 (root)", step: .verify, grantSeen: false)
assert(su.reason == .suNotRoot)
let download = RootSteps.failure("connection reset", step: .download, grantSeen: false)
assert(download.reason == .downloadFailed)
let other = RootSteps.failure("something odd", step: .install, grantSeen: false)
assert(other.reason == .installFailed)

// Clock and log tail.
assert(RootSteps.clock(18) == "0:18")
assert(RootSteps.clock(120) == "2:00")
let lines = (0..<3).map { RootLogLine(at: t0, text: "line \($0)") }
assert(RootSteps.logTail(lines, count: 2).map(\.text) == ["line 1", "line 2"])
assert(RootSteps.logTail(lines, count: 9).count == 3)

// The engine: monotonic steps, grant countdown, log tail and outcomes.
var engine = RootFlowEngine(now: t0)
engine.observe("Resolving the Magisk release", at: t0)
engine.observe("Patching the ramdisk for Magisk 30.7", at: t0 + 5)
engine.observe("正在启动 40%", at: t0 + 10)
assert(engine.step == .reboot)
assert(engine.bootStatus == "正在启动 40%")
// The boot line moved the clock to the Reboot step; the later job message
// does not move it again.
assert(engine.stepSeconds(at: t0 + 10) == 0)
engine.observe("Cold booting", at: t0 + 12)
assert(engine.step == .reboot && engine.stepSeconds(at: t0 + 12) == 2)
engine.observe("Magisk will ask to grant root to Shell. Tap Grant in the device window.", at: t0 + 90)
assert(engine.step == .verify)
assert(engine.grantSecondsLeft(at: t0 + 100) == 50)
assert(engine.log.count == 4)
engine.rooted(version: "30.7", at: t0 + 120)
assert(engine.outcome == .rooted(version: "30.7", seconds: 120))

var cancelled = RootFlowEngine(now: t0)
cancelled.observe("Patching the ramdisk for Magisk 30.7", at: t0)
cancelled.failed("cancelled", at: t0 + 3)
guard case .failed(let failure) = cancelled.outcome else { fatalError("expected a failure") }
assert(failure.isStopped && failure.step == .patch)
assert(cancelled.log.last?.isError == true)

// Cancelling the guided tap reads as "unverified", not "failed" (root/mod.rs:296-300).
var grantCancel = RootFlowEngine(now: t0)
grantCancel.observe("Magisk will ask to grant root to Shell. Tap Grant in the device window.", at: t0)
grantCancel.failed("cancelled", at: t0 + 10)
guard case .failed(let grantFailure) = grantCancel.outcome else { fatalError("expected a failure") }
assert(grantFailure.isUnverified)

// A reopened sheet is seeded from CenterModel.fullRoot.
var seeded = RootFlowEngine(now: t0)
seeded.seed(verifiedVersion: nil, failureMessage: "cancelled", at: t0)
assert(seeded.outcome != nil)

print("Root flow tests passed")
