// SPDX-License-Identifier: GPL-3.0-only
// Command palette (⌘K): one entry per device action plus the center-wide
// actions, fuzzy-filtered and keyboard-navigable. The catalog and the matching
// are pure so they are unit-tested offline; PaletteView draws them.

import Foundation

/// Icon/grouping of an entry, mirroring the Slint palette's PaletteKind.
enum PaletteKind: Equatable {
    case device
    case action
    case setting
}

/// What running an entry does. Device ids are the daemon's device ids.
enum PaletteAction: Equatable {
    case openDevice(String)
    case startDevice(String)
    case stopDevice(String)
    case restartDevice(String)
    case editDevice(String)
    case deleteDevice(String)
    case snapshots(String)
    case advancedTools(String)
    /// Opens the advanced-tools window on its Root tab (modules, certificates,
    /// build props, auto-grant) — the center's root command surface.
    case rootTools(String)
    case installAPK(String)
    case sendFile(String)
    case screenshot(String)
    case record(String)
    case newDevice
    case setupSDK
    case settings
    case toggleAppearance
    case tasks
}

struct PaletteEntry: Identifiable, Equatable {
    /// Stable identity for SwiftUI lists: kind + action.
    let id: String
    let kind: PaletteKind
    let title: String
    let subtitle: String
    /// Slint shows the matching shortcut here (⌘N, ⌘,); informational only.
    let keyboard: String
    let action: PaletteAction
}

/// The subset of a device the palette needs, so the catalog stays pure.
struct PaletteDevice: Equatable {
    enum State: Equatable {
        case running
        /// Stopped, hibernated or crashed: safe to start, edit or delete.
        case stopped
        /// Starting, booting or stopping: only Stop is offered.
        case starting
        case busy
    }

    let id: String
    let name: String
    let state: State
    let android: String
    /// Displayed under a device entry ("Running", "Stopped", "Busy · in use by …").
    let status: String

    var isRunning: Bool { state == .running }
    var canStart: Bool { state == .stopped }
    var canStop: Bool { state == .running || state == .starting }
    var canConfigure: Bool { state == .stopped }
}

enum PaletteCatalog {
    /// Every entry for the current devices, in the Slint palette's order:
    /// devices first, then lifecycle/device actions, then settings.
    static func items(
        devices: [PaletteDevice],
        sdkReady: Bool,
        text: (String, String) -> String
    ) -> [PaletteEntry] {
        var entries: [PaletteEntry] = []
        func add(_ kind: PaletteKind, _ title: String, _ subtitle: String, _ keyboard: String, _ action: PaletteAction) {
            let key = "\(kind)-\(actionKey(action))"
            entries.append(PaletteEntry(id: key, kind: kind, title: title, subtitle: subtitle, keyboard: keyboard, action: action))
        }

        for device in devices {
            add(.device, text("打开 ", "Open ") + device.name, device.status, "", .openDevice(device.id))
        }
        if !sdkReady {
            add(.action, text("设置 Android SDK", "Set up Android SDK"),
                text("查找或安装模拟器和镜像", "Find or install the emulator and an image"), "", .setupSDK)
        }
        add(.action, text("新建设备", "New device"), text("根据配置创建设备", "Create a device from a profile"), "⌘N", .newDevice)
        for device in devices {
            if device.canStop {
                add(.action, text("停止 ", "Stop ") + device.name, text("保存快速启动快照", "Saves a quick-boot snapshot"), "", .stopDevice(device.id))
            }
            if device.canStart {
                add(.action, text("启动 ", "Start ") + device.name, device.android, "", .startDevice(device.id))
            }
            if device.isRunning {
                add(.action, text("重启 ", "Restart ") + device.name, text("停止并重新启动设备", "Stop and start the device"), "", .restartDevice(device.id))
            }
            if device.canConfigure {
                add(.action, text("编辑 ", "Edit ") + device.name, text("名称、内存、CPU、屏幕", "Name, RAM, CPU, screen"), "", .editDevice(device.id))
            }
            if device.canConfigure {
                add(.action, text("删除 ", "Delete ") + device.name, text("删除设备、应用和快照", "Deletes the device, apps and snapshots"), "", .deleteDevice(device.id))
            }
            add(.action, text("管理快照 ", "Manage snapshots ") + device.name, text("保存、恢复或删除快照", "Save, restore or delete snapshots"), "", .snapshots(device.id))
            add(.action, text("设备工具 ", "Device tools ") + device.name, text("电池、GPS、网络、传感器", "Battery, GPS, network, sensors"), "", .advancedTools(device.id))
                add(.action, text("Root 工具 ", "Root tools ") + device.name, text("模块、证书、系统属性、自动授权", "Modules, certificates, build props, auto-grant"), "", .rootTools(device.id))
            if device.isRunning {
                add(.action, text("安装 APK ", "Install APK ") + device.name, text("选择本机 APK 并安装", "Choose a local APK and install it"), "", .installAPK(device.id))
                add(.action, text("发送文件 ", "Send file ") + device.name, text("复制文件到设备下载目录", "Copy a file to the device's Download folder"), "", .sendFile(device.id))
                add(.action, text("截图 ", "Screenshot ") + device.name, text("保存当前设备画面", "Save the current device screen"), "", .screenshot(device.id))
                add(.action, text("录屏 ", "Record screen ") + device.name, text("开始或停止录屏", "Start or stop recording"), "", .record(device.id))
            }
        }
        add(.action, text("后台任务", "Background tasks"), text("查看进度或取消正在运行的任务", "See progress or cancel running tasks"), "", .tasks)
        add(.setting, text("设置", "Settings"), text("SDK、存储、智能体、关于", "SDK, storage, agents, about"), "⌘,", .settings)
        add(.setting, text("切换浅色和深色", "Toggle light and dark"), text("外观", "Appearance"), "", .toggleAppearance)
        return entries
    }

    /// Stable key for an action, without Swift reflection.
    static func actionKey(_ action: PaletteAction) -> String {
        switch action {
        case .openDevice(let id): return "open:\(id)"
        case .startDevice(let id): return "start:\(id)"
        case .stopDevice(let id): return "stop:\(id)"
        case .restartDevice(let id): return "restart:\(id)"
        case .editDevice(let id): return "edit:\(id)"
        case .deleteDevice(let id): return "delete:\(id)"
        case .snapshots(let id): return "snapshots:\(id)"
        case .advancedTools(let id): return "advanced:\(id)"
        case .rootTools(let id): return "root:\(id)"
        case .installAPK(let id): return "install:\(id)"
        case .sendFile(let id): return "send:\(id)"
        case .screenshot(let id): return "screenshot:\(id)"
        case .record(let id): return "record:\(id)"
        case .newDevice: return "new"
        case .setupSDK: return "setup"
        case .settings: return "settings"
        case .toggleAppearance: return "appearance"
        case .tasks: return "tasks"
        }
    }

    /// Letters of `query` appear in `text` in order, case-insensitively
    /// (same fuzzy rule as the Slint palette: "nd" matches "New device").
    static func matches(text: String, query: String) -> Bool {
        let queryCharacters = query.lowercased().filter { !$0.isWhitespace }
        guard !queryCharacters.isEmpty else { return true }
        var remaining = Substring(text.lowercased())
        for character in queryCharacters {
            guard let index = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }

    /// Entries matching `query`; contiguous title matches rank first, the rest
    /// keep the catalog order so devices stay grouped.
    static func filter(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.enumerated()
            .filter { matches(text: $0.element.title, query: trimmed) || matches(text: $0.element.subtitle, query: trimmed) }
            .sorted { lhs, rhs in
                let leftContiguous = lhs.element.title.lowercased().contains(trimmed)
                let rightContiguous = rhs.element.title.lowercased().contains(trimmed)
                if leftContiguous != rightContiguous { return leftContiguous }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Clamped selection after one arrow key; 0 for an empty list.
    static func move(selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selection + delta, 0), count - 1)
    }
}
