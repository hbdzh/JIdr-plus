// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Player-window copy in both languages (mechanism b: the same t() helper the
/// center uses). The player window keeps its own strings in Swift because the
/// center's model is not reachable from a standalone player.
func t(_ chinese: String, _ english: String, _ language: Int) -> String {
    language == 0 ? english : chinese
}

// MARK: - Window state

/// What the player window is doing. The window owns booting/stopped/disconnected
/// presentation because this migration keeps standalone device windows instead
/// of a workbench device tab (docs/swiftui-parity.md, structural finding 1).
enum PlayerLinkState: Equatable {
    case connecting
    /// The device center opened the window before the device was running and
    /// reports the start progress (`device.start` job progress).
    case booting(progress: Double?, message: String)
    case running
    /// The bridge/daemon reports the device as not running (stopped/crashed).
    case stopped(reason: String)
    /// The frame stream or the daemon connection was lost unexpectedly.
    case disconnected(reason: String)

    var isRunning: Bool { self == .running }

    /// `GameReconnectPolicy` only permits reconnecting a lost session.
    var canReconnect: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

/// Launch state the device center can hand to a player window. `open(...)` keeps
/// `.running` as the default so the standalone player and old call sites behave
/// exactly as before.
enum PlayerLaunchState: Equatable {
    case running
    case booting(progress: Double?, message: String)
    case stopped(reason: String)
}

/// Classifies an unexpected bridge/daemon exit from its last diagnostic line.
/// `device.connect_info` answers `not_found: device is not running; start it first`
/// when the window is opened for a device that is not running.
enum PlayerExitClassifier {
    static func classify(diagnostic: String?) -> PlayerLinkState {
        let reason = (diagnostic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.contains("device is not running") || reason.contains("not_found") {
            return .stopped(reason: reason)
        }
        return .disconnected(reason: reason)
    }
}

/// Human-readable diagnosis for the window's state card. Known daemon/bridge
/// text is translated; unknown text (JSON-RPC errors, URLs) passes through.
enum PlayerDiagnosis {
    static func describe(_ raw: String, language: Int) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return t("连接已结束。", "The connection ended.", language)
        }
        if text.contains("device is not running") {
            return t("设备未运行；请先启动设备。", "The device is not running. Start it first.", language)
        }
        if text.contains("not_found") {
            return t("设备不存在或已被删除。", "The device no longer exists.", language)
        }
        if text.contains("Connection refused") || text.contains("No such file or directory") {
            return t("无法连接到 Jidr 守护进程。", "Cannot reach the Jidr daemon.", language)
        }
        return text
    }
}

/// Text shown for the bridge/daemon diagnostics that the player bubble renders
/// (the bridge still sends Chinese; M2 translates them here so English mode
/// never shows them verbatim, pending the code-based bridge contract).
enum PlayerStatusText {
    static func translate(_ text: String, language: Int) -> String {
        guard !text.isEmpty else { return text }
        if text == "UI preview: this operation requires a real device connection." {
            return t("界面预览无法执行此操作，请连接真实设备。", text, language)
        }
        // The existing en.lproj mechanism stays first (titlebar/save-panel copy).
        if language == 0,
           let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let translated = bundle.localizedString(forKey: text, value: text, table: nil)
            if translated != text { return translated }
        }
        guard language == 0 else { return text }
        for (chinese, english) in exact where text == chinese { return english }
        for (prefix, english) in prefixes where text.hasPrefix(prefix) {
            return english + String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("连接已结束（") {
            var suffix = String(text.dropFirst("连接已结束（".count))
            if suffix.hasSuffix("）") { suffix.removeLast(); suffix += ")" }
            return "Connection ended (" + suffix
        }
        return text
    }

    /// Bridge diagnostics that M1 currently emits in Chinese.
    private static let exact: [(String, String)] = [
        ("截图已保存", "Screenshot saved"),
        ("应用已安装", "App installed"),
        ("文件已发送到设备下载目录", "File sent to the device's Downloads folder"),
        ("正在录屏", "Recording"),
        ("录屏已保存", "Recording saved"),
        ("录屏路径无效或文件已存在", "Invalid recording path, or the file already exists"),
        ("请选择有效的本地文件路径", "Choose a valid local file path"),
        ("请选择本地文件，不支持文件夹", "Choose a file, not a folder"),
        ("安装失败：模拟器存储空间不足，请先释放空间。", "Install failed: the emulator is out of storage. Free some space first."),
        ("安装失败：应用签名不匹配，原应用及数据未删除。", "Install failed: the app signature does not match. The installed app and its data were not deleted."),
        ("原始像素大小超出当前屏幕", "The original size does not fit this display"),
        ("连接已结束，录屏状态未知；请在设备中心检查录屏。", "The connection ended and the recording state is unknown. Check it in the device center."),
        ("请先停止录屏并等待保存完成", "Stop recording and wait for it to finish saving first"),
        ("请先保存或取消键位编辑。", "Save or cancel the key-mapping edit first"),
        ("键位方案无法读取，请检查原文件；未进行覆盖。", "The key map could not be read. Check the original file; it was not overwritten."),
        ("请先为选中的位置绑定按键", "Bind a key to the selected position first"),
        ("键位方案已在其他位置修改，请取消编辑后重新打开。", "The key map changed elsewhere. Cancel the edit and open it again."),
        ("键位方案已保存", "Key mapping saved"),
        ("请按一个字母、数字或空格绑定", "Press a letter, digit or space to bind"),
        ("请使用字母、数字或空格", "Use a letter, digit or space"),
        ("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name."),
        ("正在启动录屏…", "Starting the recording…"),
        ("正在保存录屏…", "Saving the recording…"),
        ("Mac 剪贴板已变化，请重新复制", "The Mac clipboard changed. Copy again"),
        ("无法打开截图目录。", "Cannot open the screenshots folder."),
        ("日志连接已结束。", "The log connection ended."),
        ("日志量过大，部分内容未接收。", "The log volume is too high; some lines were dropped."),
        ("日志数据过大，连接已停止。", "Too much log data; the connection stopped."),
        ("桥接暂不支持该操作（等待 M1 桥接增量）。", "The bridge does not support this action yet (waiting for the M1 bridge increment)."),
    ]

    private static let prefixes: [(String, String)] = [
        ("已绑定 ", "Bound "),
        ("无法启动桥接：", "Unable to start the connection: "),
        ("录屏失败：", "Recording failed: "),
        ("停止录屏失败：", "Could not stop recording: "),
    ]
}

// MARK: - Diagnostics overlay

/// Frame pacing/latency samples for the ⌥⌘I debug overlay. The overlay is view
/// state only: it never changes the stream. Samples are recorded on the main
/// queue by `PlayerTransport`, which is why this type needs no locking.
struct PlayerFrameStats {
    struct Snapshot: Equatable {
        var receivedFPS: Double
        var width: Int
        var height: Int
        var rotation: Int
        var latencyMilliseconds: Double?
    }

    private let window: TimeInterval = 2
    private var frameTimes: [TimeInterval] = []
    private var latencies: [Double] = []
    private var inputAt: TimeInterval?
    private var width = 0
    private var height = 0
    private var rotation = 0

    mutating func recordInput(at now: TimeInterval) {
        inputAt = now
    }

    /// Returns the touch→frame latency of this frame, if an input preceded it.
    @discardableResult
    mutating func recordFrame(width: Int, height: Int, rotation: Int, at now: TimeInterval) -> Double? {
        self.width = width
        self.height = height
        self.rotation = rotation
        frameTimes.append(now)
        if frameTimes.count > 1, let first = frameTimes.first, now - first > 4 * window {
            frameTimes.removeAll { $0 < now - 4 * window }
        }
        guard let input = inputAt else { return nil }
        inputAt = nil
        let value = max(0, (now - input) * 1000)
        latencies.append(value)
        if latencies.count > 20 { latencies.removeFirst(latencies.count - 20) }
        return value
    }

    func snapshot(at now: TimeInterval) -> Snapshot {
        let recent = frameTimes.filter { $0 >= now - window }
        let first = frameTimes.first ?? now
        let elapsed = max(0.05, min(window, now - first))
        let fps = recent.isEmpty ? 0 : Double(recent.count) / elapsed
        return Snapshot(receivedFPS: fps, width: width, height: height,
                        rotation: rotation, latencyMilliseconds: Self.median(latencies))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - Recording clock

/// Formats the recording clock pill ("0:07"); the bridge's job message does not
/// carry a tick, so the player counts from its own start time.
enum PlayerRecordingClock {
    static func text(elapsed: TimeInterval) -> String {
        let seconds = Int(max(0, elapsed.isFinite ? elapsed : 0).rounded(.down))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - Drag and drop

/// What a file dropped on the player window does. The player bridge installs
/// APKs and copies everything else; ZIPs are never treated as root modules here
/// (crates/jidr-ui/src/player/drop.rs, `classify_game`).
enum PlayerDrop {
    enum Action: Equatable {
        case installAPK(fileName: String)
        case push(fileName: String)
    }

    struct Label: Equatable {
        let title: String
        let body: String
    }

    static func classify(_ url: URL) -> Action {
        let name = url.lastPathComponent
        if url.pathExtension.lowercased() == "apk" { return .installAPK(fileName: name) }
        return .push(fileName: name)
    }

    static func label(for action: Action, device: String, language: Int) -> Label {
        switch action {
        case .installAPK(let name):
            return Label(
                title: t("释放以安装 \(name)", "Release to install \(name)", language),
                body: t(
                    "将在 \(device) 上执行 adb install -r：替换已安装版本并保留数据。",
                    "adb install -r on \(device). Replaces the installed version and keeps its data.",
                    language))
        case .push(let name):
            return Label(
                title: t("释放以复制 \(name)", "Release to copy \(name)", language),
                body: t(
                    "文件将复制到 \(device) 的 /sdcard/Download。",
                    "Goes to /sdcard/Download on \(device).",
                    language))
        }
    }
}

/// Pending APK reinstall prompt for `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
struct PlayerReinstallPrompt: Equatable {
    let apkPath: String
    let fileName: String
    let signatureMismatch: Bool
}
