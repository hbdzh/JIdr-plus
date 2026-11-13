// SPDX-License-Identifier: GPL-3.0-only
// Background tasks (daemon jobs) shown in the center's task list and used for
// the quit guard. Decoding, ordering and the row text are pure so they are
// unit-tested offline; CenterModel polls and cancels, TaskCenterView draws.

import Foundation

/// Daemon timestamps are RFC 3339 in UTC (chrono), with or without fractional
/// seconds. The center only needs them for ordering and "last started".
enum DaemonTime {
    static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

struct JobFailure: Decodable, Equatable {
    let message: String
}

struct JobBytesInfo: Decodable, Equatable {
    let done: UInt64
    let total: UInt64
}

/// One daemon job, matching `jidr_core::Job`'s JSON.
struct JobInfo: Decodable, Identifiable, Equatable {
    let id: String
    /// The command that started it, e.g. `device.start` or `image.install`.
    let kind: String
    let device: String?
    /// 0…1, or nil when the daemon reports no progress.
    let progress: Double?
    let message: String
    let bytes: JobBytesInfo?
    /// pending / running / succeeded / failed / cancelled.
    let state: String
    let error: JobFailure?
    let created_at: String

    var createdDate: Date? { DaemonTime.date(created_at) }
    var isActive: Bool { state == "pending" || state == "running" }
    var isTerminal: Bool { !isActive }
    var cancellable: Bool { isActive }
}

enum TaskTone: Equatable {
    case queued
    case running
    case done
    case failed
    case cancelled
}

/// One row of the task list; the model fills the localized strings.
struct TaskRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let progress: Double?
    let tone: TaskTone
    let cancellable: Bool
}

enum TaskCatalog {
    /// Active jobs first, newest first within each group (the Slint task list
    /// shows running work prominently; finished rows sit below).
    static func sorted(_ jobs: [JobInfo]) -> [JobInfo] {
        jobs.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = lhs.createdDate ?? .distantPast
            let right = rhs.createdDate ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    static func activeCount(_ jobs: [JobInfo]) -> Int {
        jobs.filter(\.isActive).count
    }

    /// Tone for a job row; unknown daemon states fall back to neutral/cancelled.
    static func tone(for job: JobInfo) -> TaskTone {
        switch job.state {
        case "pending": return .queued
        case "running": return .running
        case "succeeded": return .done
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return job.isActive ? .running : .cancelled
        }
    }

    /// "1.2 / 2.3 GB" for a download, else nil.
    static func byteDetail(_ bytes: JobBytesInfo?) -> String? {
        guard let bytes, bytes.total > 0 else { return nil }
        return String(format: "%.1f / %.1f GB", Double(bytes.done) / 1e9, Double(bytes.total) / 1e9)
    }

    /// Human title for a job kind; `deviceName` is appended when known.
    static func title(for job: JobInfo, deviceName: String?, message: String, text: (String, String) -> String) -> String {
        let base: String
        switch job.kind {
        case "audio.inject": base = text("麦克风音频注入", "Microphone playback")
        case "root.writable_system": base = text("设置系统分区写入", "Changing system write access")
        case "image.install", "sdk.install":
            base = message.isEmpty ? text("正在下载镜像", "Downloading") : text("下载镜像", "Downloading image")
        case "device.start":
            base = text("启动设备", "Starting device")
        case "device.stop":
            base = text("停止设备", "Stopping device")
        case "snapshot.save":
            base = text("保存快照", "Saving snapshot")
        case "snapshot.load":
            base = text("恢复快照", "Restoring snapshot")
        case "snapshot.delete":
            base = text("删除快照", "Deleting snapshot")
        case "file.install":
            base = text("安装应用", "Installing app")
        case "app.uninstall":
            base = text("卸载应用", "Uninstalling app")
        default:
            if job.kind.hasPrefix("root.") {
                base = text("设置 Root", "Setting up root")
            } else {
                base = job.kind
            }
        }
        guard let deviceName, !deviceName.isEmpty else { return base }
        return base + " · " + deviceName
    }

    /// Row detail: download bytes, the current step, or the terminal reason.
    static func detail(for job: JobInfo, step: String, text: (String, String) -> String) -> String {
        switch job.state {
        case "failed":
            return job.error?.message ?? step
        case "cancelled":
            return text("已取消", "Cancelled")
        case "succeeded":
            return text("已完成", "Done")
        case "pending":
            return text("排队中", "Queued")
        default:
            return byteDetail(job.bytes) ?? step
        }
    }
}
