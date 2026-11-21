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

struct DeviceDeletionTarget: Equatable {
    let id: String
    let name: String
}
