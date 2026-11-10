// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One user-rebindable game-window shortcut, in the same JSON shape as
/// `crates/jidr-ui/src/player/game_shortcuts.rs` (config compatibility).
struct ShortcutBinding: Codable, Equatable {
    var key: String
    var command: Bool
    var control: Bool
    var shift: Bool
    var alt: Bool

    /// Keeps editing/lifecycle chords available to macOS, like the Slint
    /// validator: ⌘Q/⌘W/⌘H/⌘A/⌘C/⌘V/⌘X/⌘Z/⌘Y are not bindable.
    private static let reserved: Set<String> = ["Q", "W", "H", "A", "C", "V", "X", "Z", "Y"]

    /// Returns `nil` for an invalid chord: a single ASCII letter/digit, at
    /// least one of ⌘/⌃/⌥, and not a reserved application chord.
    static func make(key: String, command: Bool, control: Bool, shift: Bool, alt: Bool) -> ShortcutBinding? {
        let normalized = key.uppercased()
        guard normalized.count == 1,
              let scalar = normalized.unicodeScalars.first,
              scalar.isASCII,
              CharacterSet.alphanumerics.contains(scalar),
              command || control || alt else { return nil }
        if command && !control && !alt && reserved.contains(normalized) { return nil }
        return ShortcutBinding(key: normalized, command: command, control: control, shift: shift, alt: alt)
    }

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if alt { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + key
    }
}

/// The five player-window actions, in the order the Slint shortcuts file uses.
/// Slots 3/4 were the performance and text panels there; the standalone window
/// maps them to the debug overlay and the advanced-tools window.
enum GameShortcutAction: Int, CaseIterable {
    case screenshot = 0
    case fullscreen = 1
    case sidebar = 2
    case overlay = 3
    case advanced = 4
}

/// Per-device shortcuts file: `game-shortcuts/<device>.json`, `version: 1`,
/// five bindings, no duplicates (validated like the Slint side).
struct GameShortcuts: Codable, Equatable {
    var version: Int
    var bindings: [ShortcutBinding]

    static let count = 5

    static var standard: GameShortcuts {
        let defaults = ["S", "F", "J", "I", "T"].compactMap {
            ShortcutBinding.make(key: $0, command: true, control: false, shift: true, alt: false)
        }
        return GameShortcuts(version: 1, bindings: defaults)
    }

    func validate() -> Bool {
        guard version == 1, bindings.count == Self.count else { return false }
        for (index, binding) in bindings.enumerated() {
            guard ShortcutBinding.make(key: binding.key, command: binding.command,
                                      control: binding.control, shift: binding.shift,
                                      alt: binding.alt) == binding else { return false }
            guard !bindings[..<index].contains(binding) else { return false }
        }
        return true
    }

    /// Replaces one binding. Returns `false` on an invalid action or when the
    /// chord is already used by another action.
    mutating func assign(_ index: Int, _ binding: ShortcutBinding) -> Bool {
        guard bindings.indices.contains(index) else { return false }
        guard !bindings.enumerated().contains(where: { $0.offset != index && $0.element == binding }) else {
            return false
        }
        bindings[index] = binding
        return true
    }

    func lookup(_ binding: ShortcutBinding) -> Int? {
        bindings.firstIndex(of: binding)
    }
}

/// Why the shortcuts editor cannot be used or cannot save. The view maps these
/// to both languages (no error text leaves this file).
enum ShortcutFailure: Equatable {
    case unreadable
    case invalidConfiguration
    case conflict
    case invalidChord
    case cannotSave
}

extension ShortcutFailure {
    static func describe(_ failure: ShortcutFailure, language: Int) -> String {
        switch failure {
        case .unreadable:
            return t("无法读取快捷键配置，原文件未覆盖。", "Could not read the shortcut configuration; the original file was not overwritten.", language)
        case .invalidConfiguration:
            return t("快捷键配置无效，原文件已保留。", "The shortcut configuration is invalid; the original file was preserved.", language)
        case .conflict:
            return t("该快捷键已被占用。", "That shortcut is already in use.", language)
        case .invalidChord:
            return t("请使用带 ⌘、⌃ 或 ⌥ 的字母/数字组合键。", "Use a letter or digit with ⌘, ⌃ or ⌥.", language)
        case .cannotSave:
            return t("无法保存快捷键。", "Could not save the shortcuts.", language)
        }
    }
}

/// Loads, validates and atomically saves one device's shortcuts. A corrupt file
/// is never overwritten: editing is refused until the file is fixed or removed,
/// matching `game_shortcuts.rs`.
final class GameShortcutsStore: ObservableObject {
    @Published private(set) var shortcuts = GameShortcuts.standard
    @Published private(set) var failure: ShortcutFailure?
    @Published private(set) var capture: Int?
    @Published private(set) var loaded = false
    private var location: URL?

    func load(dataDirectory: String, device: String) {
        let id = UUID(uuidString: device)?.uuidString.lowercased() ?? device
        location = URL(fileURLWithPath: dataDirectory, isDirectory: true)
            .appendingPathComponent("game-shortcuts", isDirectory: true)
            .appendingPathComponent("\(id).json")
        reload()
    }

    private func reload() {
        guard let location else { loaded = false; failure = .unreadable; return }
        let data: Data
        do { data = try Data(contentsOf: location) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            shortcuts = .standard; failure = nil; loaded = true; return
        } catch {
            shortcuts = .standard; failure = .unreadable; loaded = false; return
        }
        do {
            let value = try JSONDecoder().decode(GameShortcuts.self, from: data)
            guard value.validate() else { shortcuts = .standard; failure = .invalidConfiguration; loaded = false; return }
            shortcuts = value; failure = nil; loaded = true
        } catch {
            shortcuts = .standard; failure = .invalidConfiguration; loaded = false
        }
    }

    func beginCapture(_ index: Int) -> Bool {
        guard loaded, failure == nil, shortcuts.bindings.indices.contains(index) else { return false }
        capture = index
        return true
    }

    func cancelCapture() { capture = nil }

    /// Captures the next chord for the selected action. Returns a failure for an
    /// unusable chord or a conflict; on success the file is saved immediately.
    @discardableResult
    func assign(key: String, command: Bool, control: Bool, shift: Bool, alt: Bool) -> ShortcutFailure? {
        guard let index = capture else { return nil }
        guard let binding = ShortcutBinding.make(key: key, command: command, control: control,
                                                shift: shift, alt: alt) else { return .invalidChord }
        var updated = shortcuts
        guard updated.assign(index, binding) else { return .conflict }
        guard save(updated) else { return .cannotSave }
        shortcuts = updated
        capture = nil
        return nil
    }

    private func save(_ value: GameShortcuts) -> Bool {
        guard loaded, failure == nil, let location else { return false }
        guard value.validate() else { return false }
        do {
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: location, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func binding(for action: GameShortcutAction) -> ShortcutBinding? {
        guard shortcuts.bindings.indices.contains(action.rawValue) else { return nil }
        return shortcuts.bindings[action.rawValue]
    }

    /// The action bound to a chord, if any.
    func action(for binding: ShortcutBinding) -> GameShortcutAction? {
        guard let index = shortcuts.lookup(binding) else { return nil }
        return GameShortcutAction(rawValue: index)
    }

    static func actionLabel(_ action: GameShortcutAction, language: Int) -> String {
        switch action {
        case .screenshot: return t("截图", "Screenshot", language)
        case .fullscreen: return t("全屏", "Fullscreen", language)
        case .sidebar: return t("侧边栏", "Sidebar", language)
        case .overlay: return t("调试浮层", "Debug overlay", language)
        case .advanced: return t("高级工具", "Advanced tools", language)
        }
    }
}
