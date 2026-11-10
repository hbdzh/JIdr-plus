// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Bridge exit classification: a device that is not running is "stopped", a
// lost daemon/stream is "disconnected".
precondition(PlayerExitClassifier.classify(diagnostic: nil) == .disconnected(reason: ""))
precondition(PlayerExitClassifier.classify(diagnostic: "not_found: device is not running; start it first")
    == .stopped(reason: "not_found: device is not running; start it first"))
precondition(PlayerExitClassifier.classify(diagnostic: "Error: not_found: device is not running") ==
    .stopped(reason: "Error: not_found: device is not running"))
precondition(PlayerExitClassifier.classify(diagnostic: "Connection refused") == .disconnected(reason: "Connection refused"))

// Diagnosis copy: known daemon text is translated, unknown text passes through.
precondition(!PlayerDiagnosis.describe("", language: 1).isEmpty)
precondition(PlayerDiagnosis.describe("", language: 0) == "The connection ended.")
precondition(PlayerDiagnosis.describe("not_found: device is not running; start it first", language: 0)
    == "The device is not running. Start it first.")
precondition(PlayerDiagnosis.describe("not_found: device is not running; start it first", language: 1).contains("设备未运行"))
precondition(PlayerDiagnosis.describe("some raw error", language: 0) == "some raw error")

// Bridge diagnostics the English UI used to show in Chinese.
precondition(PlayerStatusText.translate("截图已保存", language: 0) == "Screenshot saved")
precondition(PlayerStatusText.translate("录屏失败：daemon unavailable", language: 0)
    == "Recording failed: daemon unavailable")
precondition(PlayerStatusText.translate("连接已结束（1）", language: 0) == "Connection ended (1)")
precondition(PlayerStatusText.translate("截图已保存", language: 1) == "截图已保存")
precondition(PlayerStatusText.translate("", language: 0) == "")

// Link state → reconnect policy (center semantics stay unchanged).
precondition(PlayerLinkState.disconnected(reason: "x").canReconnect)
precondition(!PlayerLinkState.stopped(reason: "x").canReconnect)
precondition(!PlayerLinkState.running.canReconnect)

// Frame stats: fps over the rolling window and the touch→frame latency.
var stats = PlayerFrameStats()
precondition(stats.snapshot(at: 2).receivedFPS == 0)
stats.recordFrame(width: 360, height: 640, rotation: 0, at: 0)
stats.recordFrame(width: 360, height: 640, rotation: 0, at: 0.5)
stats.recordFrame(width: 360, height: 640, rotation: 0, at: 1.0)
stats.recordFrame(width: 360, height: 640, rotation: 0, at: 1.5)
let settled = stats.snapshot(at: 2.0)
precondition(abs(settled.receivedFPS - 2) < 0.001, "fps \(settled.receivedFPS)")
precondition(settled.width == 360 && settled.height == 640 && settled.rotation == 0)
stats.recordInput(at: 10)
let latency = stats.recordFrame(width: 360, height: 640, rotation: 1, at: 10.05)
precondition(latency != nil && abs((latency ?? 0) - 50) < 1e-6)
precondition(abs((stats.snapshot(at: 11).latencyMilliseconds ?? 0) - 50) < 1e-6)
precondition(PlayerFrameStats.median([3, 1, 2]) == 2)
precondition(PlayerFrameStats.median([1, 2, 3, 4]) == 2.5)
precondition(PlayerFrameStats.median([]) == nil)

// Recording clock pill.
precondition(PlayerRecordingClock.text(elapsed: 0) == "0:00")
precondition(PlayerRecordingClock.text(elapsed: 7) == "0:07")
precondition(PlayerRecordingClock.text(elapsed: 61) == "1:01")
precondition(PlayerRecordingClock.text(elapsed: 3661) == "1:01:01")
precondition(PlayerRecordingClock.text(elapsed: -4) == "0:00")

// Drop classification: APKs install, everything else is copied.
let apk = PlayerDrop.classify(URL(fileURLWithPath: "/tmp/shop-debug.APK"))
precondition(apk == .installAPK(fileName: "shop-debug.APK"))
precondition(PlayerDrop.classify(URL(fileURLWithPath: "/tmp/notes.txt")) == .push(fileName: "notes.txt"))
let installLabel = PlayerDrop.label(for: apk, device: "Pixel", language: 0)
precondition(installLabel.title == "Release to install shop-debug.APK")
precondition(installLabel.body.contains("adb install -r"))
let copyLabel = PlayerDrop.label(for: .push(fileName: "m.zip"), device: "Pixel", language: 1)
precondition(copyLabel.title == "释放以复制 m.zip")
precondition(copyLabel.body.contains("/sdcard/Download"))

// Bilingual helper itself.
precondition(t("中文", "English", 0) == "English")
precondition(t("中文", "English", 1) == "中文")

print("Player session tests passed")
