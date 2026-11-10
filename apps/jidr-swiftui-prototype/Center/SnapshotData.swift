// SPDX-License-Identifier: GPL-3.0-only
// Snapshot wire types, sorting, formatting and the D29 refusal rules, split
// out of SnapshotDialogs.swift so they are testable without SwiftUI. The
// Slint reference is crates/jidr-ui/src/snapshots/mod.rs.
import Foundation

/// One row of `snapshot.list` (crates/jidr-widgets/src/snapshots.rs:270-295).
/// `name` is the label as typed; `folder` is the on-disk id.
struct SnapshotRow: Decodable, Identifiable, Equatable {
    let name: String
    let folder: String?
    let quick_boot: Bool
    let restorable: Bool
    let root_mode: String?
    let magisk_version: String?
    let created_at: String?
    let size_bytes: UInt64?
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case name, quick_boot, restorable, root_mode, magisk_version, created_at, size_bytes, thumbnail
        case folder = "id"
    }

    var id: String { folder ?? name }
}

struct SnapshotList: Decodable {
    let device_root_mode: String?
    let snapshots: [SnapshotRow]
}

/// Why a snapshot can't be restored (D29): another root mode, or files that
/// the daemon found incomplete (snapshot.list's `restorable`).
enum SnapshotRefusalKind: Equatable {
    case rootMode(snapshot: String, device: String, magisk: String?)
    case incomplete
}

struct SnapshotRefusal: Identifiable {
    let id = UUID()
    let kind: SnapshotRefusalKind
    let name: String
}

/// Snapshot formatting, sorting and validation shared by the two views.
enum Snapshots {
    /// Quick boot last, newest named snapshots first (snapshots/mod.rs:64-72).
    static func sorted(_ rows: [SnapshotRow]) -> [SnapshotRow] {
        rows.sorted { a, b in
            if a.quick_boot != b.quick_boot { return !a.quick_boot }
            return (created(a.created_at) ?? .distantPast) > (created(b.created_at) ?? .distantPast)
        }
    }

    static func created(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    static func size(_ bytes: UInt64?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func modeName(_ mode: String?, language: Int) -> String {
        let chinese: String
        let english: String
        switch mode {
        case "magisk": (chinese, english) = ("完整 Root", "Full root")
        case "adb": (chinese, english) = ("Shell root", "Shell root")
        case "none": (chinese, english) = ("无 Root", "Not rooted")
        default: (chinese, english) = ("未标记", "Not tagged")
        }
        return language == 0 ? english : chinese
    }

    /// "保存时模式：完整 Root · Magisk 30.7" (snapshots/mod.rs:98-106).
    static func rootTag(mode: String?, magisk: String?, language: Int) -> String {
        let name = modeName(mode, language: language)
        let version = mode == "magisk" ? magisk : nil
        if let version, !version.isEmpty {
            return language == 0 ? "Taken with: \(name) · Magisk \(version)" : "保存时模式：\(name) · Magisk \(version)"
        }
        return language == 0 ? "Taken with: \(name)" : "保存时模式：\(name)"
    }

    /// The time in the list: "11月11日 00:56" / "Nov 11, 00:56".
    static func when(_ raw: String?, language: Int) -> String {
        guard let date = created(raw) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == 0 ? "en_US_POSIX" : "zh_CN")
        formatter.dateFormat = language == 0 ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// The default name for a new snapshot, e.g. "Snapshot Nov 11, 00.56".
    static func defaultName(language: Int, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        if language == 0 {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d, HH.mm"
            return "Snapshot \(formatter.string(from: date))"
        }
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH.mm"
        return "快照 \(formatter.string(from: date))"
    }

    enum NameProblem: Equatable {
        case empty, tooLong, forbiddenCharacters, reserved
    }

    /// The daemon's rename rules (snapshots.rs:95-111), checked before the
    /// save so the dialog can explain instead of forwarding a `usage` error.
    static func nameProblem(_ raw: String) -> NameProblem? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.count > 100 { return .tooLong }
        if name.hasPrefix(".") || name.contains(where: { "/\\:".contains($0) })
            || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .forbiddenCharacters
        }
        if name == "default_boot" { return .reserved }
        return nil
    }

    static func nameProblemText(_ problem: NameProblem, language: Int) -> String {
        switch problem {
        case .empty: return language == 0 ? "Enter a name." : "请输入名称。"
        case .tooLong: return language == 0 ? "The name must be at most 100 characters." : "名称最多 100 个字符。"
        case .reserved: return language == 0 ? "default_boot is the quick-boot snapshot; pick another name." : "default_boot 是快速启动快照，请换一个名称。"
        case .forbiddenCharacters:
            return language == 0 ? "The name can't contain /, \\ or :, or start with a dot." : "名称不能包含 /、\\ 或 :，也不能以点开头。"
        }
    }

    /// The other named snapshots of this device, for the save dialog's hint
    /// (snapshots/mod.rs:324-358): "Its other snapshot is 2.1 GB."
    static func sizesHint(_ rows: [SnapshotRow], language: Int) -> String {
        let sizes = rows.filter { !$0.quick_boot }.compactMap { $0.size_bytes }.filter { $0 > 0 }.map { size($0) }
        switch sizes.count {
        case 0:
            return language == 0
                ? "Snapshots take about as much disk as the device's data."
                : "快照约占与设备数据同样大的磁盘空间。"
        case 1:
            return language == 0 ? "Its other snapshot is \(sizes[0])." : "该设备的其他快照占用 \(sizes[0])。"
        default:
            let head = sizes.dropLast().joined(separator: language == 0 ? ", " : "、")
            return language == 0
                ? "Its other snapshots are \(head) and \(sizes[sizes.count - 1])."
                : "该设备的其他快照占用 \(head) 和 \(sizes[sizes.count - 1])。"
        }
    }

    /// The banner above the list (snapshots/mod.rs:126-178). Returns the text
    /// and whether it is a warning.
    static func banner(_ rows: [SnapshotRow], deviceMode: String?, language: Int) -> (String, Bool) {
        let named = rows.filter { !$0.quick_boot }
        if let refused = named.first(where: { !$0.restorable }), let snapshotMode = refused.root_mode,
           snapshotMode != deviceMode {
            let current = modeName(deviceMode, language: language)
            let other = modeName(snapshotMode, language: language)
            return (language == 0
                    ? "Snapshots remember the root mode they were taken with. \(other) snapshots can't be restored until \(other) is set up again (the device is \(current) now)."
                    : "快照记录了保存时的 Root 模式。设备当前为\(current)，需重新设置\(other)后才能恢复该模式下的快照。",
                    true)
        }
        guard !named.isEmpty else { return ("", false) }
        let total = named.compactMap { $0.size_bytes }.reduce(0, +)
        let current = modeName(deviceMode, language: language)
        return (language == 0
                ? "Every snapshot remembers the root mode it was taken with. The device is \(current) now, so all \(named.count) can be restored. \(size(total)) in total."
                : "每个快照都记录了保存时的 Root 模式。设备当前为\(current)，\(named.count) 个快照可恢复，共占用 \(size(total))。",
                false)
    }

    /// Why a refused snapshot can't be restored, or nil when the block is a
    /// pending restore instead (snapshots/mod.rs:242-276).
    static func refusal(_ row: SnapshotRow, deviceMode: String?, language: Int) -> SnapshotRefusal? {
        guard !row.restorable else { return nil }
        if let snapshotMode = row.root_mode, snapshotMode != deviceMode {
            return SnapshotRefusal(kind: .rootMode(snapshot: snapshotMode, device: deviceMode ?? "none", magisk: row.magisk_version), name: row.name)
        }
        return SnapshotRefusal(kind: .incomplete, name: row.name)
    }
}

