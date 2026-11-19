// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

enum MappingKey {
    private static let specialKeyCodes: [UInt16: String] = [
        36: "ENTER",
        48: "TAB",
        76: "ENTER",
        123: "LEFT",
        124: "RIGHT",
        125: "DOWN",
        126: "UP",
    ]
    private static let specialNames: Set<String> = [
        "SPACE", "TAB", "ENTER", "UP", "DOWN", "LEFT", "RIGHT",
    ]

    static func normalize(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String? {
        if let special = specialKeyCodes[keyCode] { return special }
        guard let raw = charactersIgnoringModifiers else { return nil }
        if raw == " " { return "SPACE" }
        guard raw.unicodeScalars.count == 1, let scalar = raw.unicodeScalars.first,
              (33...126).contains(scalar.value) else { return nil }
        return raw.uppercased()
    }

    static func isValid(_ key: String) -> Bool {
        if specialNames.contains(key) { return true }
        let bytes = Array(key.utf8)
        guard bytes.count == 1 else { return false }
        let b = bytes[0]
        return (33...126).contains(b) && !(97...122).contains(b)
    }

    static func displayLabel(_ key: String) -> String {
        switch key {
        case "SPACE": return "SPC"
        case "UP": return "↑"
        case "DOWN": return "↓"
        case "LEFT": return "←"
        case "RIGHT": return "→"
        case "ENTER": return "ENT"
        default: return key
        }
    }
}

enum JoystickDirection: String, CaseIterable {
    case up, down, left, right
}

enum JoystickPreset: Equatable {
    case wasd
    case arrows

    var keys: (up: String, down: String, left: String, right: String) {
        switch self {
        case .wasd: return ("W", "S", "A", "D")
        case .arrows: return ("UP", "DOWN", "LEFT", "RIGHT")
        }
    }
}

enum MappingPlacementMode: Equatable {
    case tap
    case joystick
}

enum KeyMappingFailure: Int, Equatable {
    case unreadable = 0
    case bindingRequired = 1
    case conflict = 2
    case invalidImportFile = 3
    case cannotEnterEdit = 4

    var englishMessage: String {
        switch self {
        case .unreadable:
            return "The key map could not be read. Check the original file; it was not overwritten."
        case .bindingRequired:
            return "Bind a key to the selected position first"
        case .conflict:
            return "The key map changed elsewhere. Cancel the edit and open it again."
        case .invalidImportFile:
            return "The selected key map file is invalid."
        case .cannotEnterEdit:
            return "Cannot enter key-mapping edit mode right now."
        }
    }

    var nsError: NSError {
        NSError(domain: "JidrMapping", code: rawValue, userInfo: [NSLocalizedDescriptionKey: englishMessage])
    }
}

enum MappingTemplate: CaseIterable {
    case moba
    case shooter
    case arcade

    func scheme(for rotation: Int) -> (bindings: [MappingBinding], joysticks: [JoystickBinding]) {
        switch self {
        case .moba:
            return (
                bindings: [
                    MappingBinding(key: "J", x: 0.87, y: 0.78, rotation: rotation),
                    MappingBinding(key: "K", x: 0.77, y: 0.74, rotation: rotation),
                    MappingBinding(key: "L", x: 0.81, y: 0.58, rotation: rotation),
                    MappingBinding(key: "U", x: 0.89, y: 0.52, rotation: rotation),
                ],
                joysticks: [
                    JoystickBinding(up: "W", down: "S", left: "A", right: "D", x: 0.18, y: 0.72, radius: 0.13, rotation: rotation),
                ]
            )
        case .shooter:
            return (
                bindings: [
                    MappingBinding(key: "SPACE", x: 0.88, y: 0.76, rotation: rotation),
                    MappingBinding(key: "R", x: 0.78, y: 0.55, rotation: rotation),
                    MappingBinding(key: "F", x: 0.70, y: 0.68, rotation: rotation),
                    MappingBinding(key: "1", x: 0.44, y: 0.88, rotation: rotation),
                    MappingBinding(key: "2", x: 0.56, y: 0.88, rotation: rotation),
                ],
                joysticks: [
                    JoystickBinding(up: "W", down: "S", left: "A", right: "D", x: 0.18, y: 0.70, radius: 0.13, rotation: rotation),
                ]
            )
        case .arcade:
            return (
                bindings: [
                    MappingBinding(key: "Z", x: 0.76, y: 0.78, rotation: rotation),
                    MappingBinding(key: "X", x: 0.85, y: 0.66, rotation: rotation),
                    MappingBinding(key: "SPACE", x: 0.88, y: 0.82, rotation: rotation),
                ],
                joysticks: [
                    JoystickBinding(up: "UP", down: "DOWN", left: "LEFT", right: "RIGHT", x: 0.18, y: 0.74, radius: 0.12, rotation: rotation),
                ]
            )
        }
    }
}

struct MappingBinding: Codable, Equatable {
    var key: String
    var x: Double
    var y: Double
    var rotation: Int
}

struct JoystickBinding: Codable, Equatable {
    var up: String = "W"
    var down: String = "S"
    var left: String = "A"
    var right: String = "D"
    var x: Double
    var y: Double
    var radius: Double = 0.12
    var rotation: Int

    var keys: [String] { [up, down, left, right] }

    var preset: JoystickPreset? {
        if (up, down, left, right) == ("W", "S", "A", "D") { return .wasd }
        if (up, down, left, right) == ("UP", "DOWN", "LEFT", "RIGHT") { return .arrows }
        return nil
    }

    func direction(for key: String) -> JoystickDirection? {
        if key == up { return .up }
        if key == down { return .down }
        if key == left { return .left }
        if key == right { return .right }
        return nil
    }

    func target(for held: Set<JoystickDirection>, aspectWidthOverHeight aspect: Double) -> (x: Double, y: Double) {
        let dx = (held.contains(.right) ? 1.0 : 0.0) - (held.contains(.left) ? 1.0 : 0.0)
        let dy = (held.contains(.down) ? 1.0 : 0.0) - (held.contains(.up) ? 1.0 : 0.0)
        guard dx != 0 || dy != 0, aspect.isFinite, aspect > 0 else { return (x, y) }
        let length = hypot(dx, dy)
        let ux = dx / length
        let uy = dy / length
        let rx = aspect >= 1 ? radius / aspect : radius
        let ry = aspect >= 1 ? radius : radius * aspect
        return (min(1, max(0, x + ux * rx)), min(1, max(0, y + uy * ry)))
    }
}

struct MappingPoint: Equatable {
    var x: Double
    var y: Double
    var rotation: Int
}

struct MappingScheme: Codable, Equatable {
    var version: Int = 1
    var bindings: [MappingBinding] = []
    var joysticks: [JoystickBinding] = []

    enum CodingKeys: String, CodingKey {
        case version, bindings, joysticks
    }

    init(version: Int = 1, bindings: [MappingBinding] = [], joysticks: [JoystickBinding] = []) {
        self.version = version
        self.bindings = bindings
        self.joysticks = joysticks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        bindings = try container.decodeIfPresent([MappingBinding].self, forKey: .bindings) ?? []
        joysticks = try container.decodeIfPresent([JoystickBinding].self, forKey: .joysticks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(bindings, forKey: .bindings)
        if !joysticks.isEmpty {
            try container.encode(joysticks, forKey: .joysticks)
        }
    }

    var isEmpty: Bool { bindings.isEmpty && joysticks.isEmpty }

    func validate() -> Bool {
        guard version == 1, bindings.count <= 256, joysticks.count <= 16 else { return false }
        var seen = Set<String>()
        var bindingCounts: [Int: Int] = [:]
        var joystickCounts: [Int: Int] = [:]
        for b in bindings {
            guard MappingKey.isValid(b.key), b.x.isFinite, b.y.isFinite,
                  (0...1).contains(b.x), (0...1).contains(b.y), (0...3).contains(b.rotation),
                  seen.insert("\(b.rotation):\(b.key)").inserted else { return false }
            bindingCounts[b.rotation, default: 0] += 1
            guard bindingCounts[b.rotation, default: 0] <= 64 else { return false }
        }
        for j in joysticks {
            guard j.x.isFinite, j.y.isFinite, (0...1).contains(j.x), (0...1).contains(j.y),
                  j.radius.isFinite, (0.05...0.35).contains(j.radius), (0...3).contains(j.rotation) else { return false }
            joystickCounts[j.rotation, default: 0] += 1
            guard joystickCounts[j.rotation, default: 0] <= 4 else { return false }
            for key in j.keys {
                guard MappingKey.isValid(key), seen.insert("\(j.rotation):\(key)").inserted else { return false }
            }
        }
        return true
    }
}

final class KeyMappingStore: ObservableObject {
    static let defaultMarkerOpacity: Double = 0.85
    private static let markerOpacityKey = "jidr.keymap.markerOpacity"

    @Published private(set) var scheme = MappingScheme() { didSet { onChange?() } }
    @Published private(set) var draft = MappingScheme() { didSet { onChange?() } }
    @Published private(set) var editing = false { didSet { onChange?() } }
    @Published var enabled = false { didSet { onChange?() } }
    @Published var hints = true { didSet { onChange?() } }
    @Published var markerOpacity: Double {
        didSet {
            let clamped = min(1.0, max(0.15, markerOpacity))
            if clamped != markerOpacity {
                markerOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.markerOpacityKey)
            onChange?()
        }
    }
    @Published var placementMode: MappingPlacementMode = .tap { didSet { if placementMode == .joystick { pendingPoint = nil } } }
    @Published private(set) var pendingPoint: MappingPoint? { didSet { onChange?() } }
    @Published private(set) var selectedKey: String? { didSet { onChange?() } }
    @Published private(set) var selectedJoystickIndex: Int? { didSet { onChange?() } }
    @Published private(set) var currentRotation = 0
    @Published private(set) var profiles: [String] = []
    @Published private(set) var activeProfileName: String?
    @Published private(set) var failure: KeyMappingFailure?
    var error: String? { failure?.englishMessage }
    var currentFileURL: URL? { location }
    var pending: Bool { pendingPoint != nil }
    var hasUnsavedChanges: Bool { editing && (draft != scheme || resettingCorrupted) }
    var onChange: (() -> Void)?
    private var baseLocation: URL?
    private var location: URL?
    private var baseline: Data?
    private var resettingCorrupted = false

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.markerOpacityKey) != nil {
            markerOpacity = min(1.0, max(0.15, defaults.double(forKey: Self.markerOpacityKey)))
        } else {
            markerOpacity = Self.defaultMarkerOpacity
        }
    }

    func load(path: String) {
        let base = URL(fileURLWithPath: path)
        baseLocation = base
        refreshProfiles()
        if let stored = readActiveProfileName(),
           let profileURL = profileURL(for: stored),
           FileManager.default.fileExists(atPath: profileURL.path) {
            activeProfileName = stored
            loadFile(at: profileURL)
        } else {
            activeProfileName = nil
            loadFile(at: base)
        }
    }
    func selectProfile(_ name: String?) -> Bool {
        guard !hasUnsavedChanges, let baseLocation else { return false }
        let wasEditing = editing
        let targetURL: URL
        if let name {
            guard let url = profileURL(for: name),
                  FileManager.default.fileExists(atPath: url.path) else { return false }
            targetURL = url
        } else {
            targetURL = baseLocation
        }
        persistActiveProfileName(name)
        activeProfileName = name
        loadFile(at: targetURL)
        if wasEditing {
            if failure == nil {
                draft = scheme
                placementMode = .tap
                pendingPoint = nil
                selectedKey = nil
                selectedJoystickIndex = nil
            } else {
                editing = false
            }
        }
        return true
    }
    func createProfile(named rawName: String, duplicateCurrent: Bool) -> Bool {
        guard !hasUnsavedChanges, let name = Self.sanitizedProfileName(rawName),
              let url = profileURL(for: name),
              !FileManager.default.fileExists(atPath: url.path) else { return false }
        let wasEditing = editing
        let content = duplicateCurrent ? (wasEditing ? draft : scheme) : MappingScheme()
        guard (try? writeScheme(content, to: url)) != nil else { return false }
        persistActiveProfileName(name)
        activeProfileName = name
        refreshProfiles()
        loadFile(at: url)
        if wasEditing {
            draft = scheme
            placementMode = .tap
            pendingPoint = nil
            selectedKey = nil
            selectedJoystickIndex = nil
        }
        return true
    }
    func saveAsProfile(named rawName: String) -> Bool {
        guard editing, !pending, draft.validate(),
              let name = Self.sanitizedProfileName(rawName),
              let url = profileURL(for: name),
              !FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let bytes = try? writeScheme(draft, to: url) else { return false }
        persistActiveProfileName(name)
        activeProfileName = name
        location = url
        baseline = bytes
        scheme = draft
        enabled = !scheme.isEmpty
        placementMode = .tap
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
        resettingCorrupted = false
        editing = false
        failure = nil
        refreshProfiles()
        return true
    }
    func renameProfile(from oldName: String, to rawNewName: String) -> Bool {
        guard let newName = Self.sanitizedProfileName(rawNewName),
              oldName != newName,
              let src = profileURL(for: oldName),
              let dst = profileURL(for: newName),
              FileManager.default.fileExists(atPath: src.path),
              !FileManager.default.fileExists(atPath: dst.path) else { return false }
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            return false
        }
        if activeProfileName == oldName {
            activeProfileName = newName
            location = dst
            persistActiveProfileName(newName)
        }
        refreshProfiles()
        return true
    }
    func deleteProfile(named name: String) -> Bool {
        if activeProfileName == name && hasUnsavedChanges { return false }
        guard let url = profileURL(for: name),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return false
        }
        refreshProfiles()
        if activeProfileName == name {
            _ = selectProfile(nil)
        }
        return true
    }
    func applyTemplate(_ template: MappingTemplate, rotation: Int) {
        guard editing, (0...3).contains(rotation) else { return }
        var copy = draft
        copy.bindings.removeAll { $0.rotation == rotation }
        copy.joysticks.removeAll { $0.rotation == rotation }
        let preset = template.scheme(for: rotation)
        copy.bindings.append(contentsOf: preset.bindings)
        copy.joysticks.append(contentsOf: preset.joysticks)
        guard copy.validate() else { return }
        placementMode = .tap
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
        currentRotation = rotation
        draft = copy
    }
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(editing ? draft : scheme)
    }
    func importScheme(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(MappingScheme.self, from: data)
        guard value.validate() else { throw KeyMappingFailure.invalidImportFile.nsError }
        if !editing, !begin() { throw KeyMappingFailure.cannotEnterEdit.nsError }
        placementMode = .tap
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
        draft = value
    }
    func reloadCurrent() {
        guard !editing, let location else { return }
        loadFile(at: location)
    }
    func resetCorruptedForEditing() -> Bool {
        guard !editing, let location, failure == .unreadable else { return false }
        baseline = try? Data(contentsOf: location)
        scheme = MappingScheme()
        draft = MappingScheme()
        failure = nil
        enabled = false
        resettingCorrupted = true
        placementMode = .tap
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
        editing = true
        return true
    }
    func begin() -> Bool {
        guard location != nil, failure == nil else { return false }
        resettingCorrupted = false
        draft = scheme; placementMode = .tap; pendingPoint = nil; selectedKey = nil; selectedJoystickIndex = nil; editing = true; return true
    }
    func cancel() {
        let restoreCorrupted = resettingCorrupted
        resettingCorrupted = false
        placementMode = .tap; pendingPoint = nil; selectedKey = nil; selectedJoystickIndex = nil; editing = false
        if restoreCorrupted, let location { loadFile(at: location) }
    }
    func place(x: Double, y: Double, rotation: Int) {
        guard editing, Self.isValidPoint(x: x, y: y, rotation: rotation) else { return }
        selectedKey = nil
        selectedJoystickIndex = nil
        currentRotation = rotation
        pendingPoint = MappingPoint(x: x, y: y, rotation: rotation)
    }
    func select(key: String, rotation: Int) -> Bool {
        guard editing, draft.bindings.contains(where: { $0.key == key && $0.rotation == rotation }) else { return false }
        pendingPoint = nil
        selectedJoystickIndex = nil
        currentRotation = rotation
        selectedKey = key
        return true
    }
    func selectJoystick(at index: Int) -> Bool {
        guard editing, draft.joysticks.indices.contains(index) else { return false }
        pendingPoint = nil
        selectedKey = nil
        currentRotation = draft.joysticks[index].rotation
        selectedJoystickIndex = index
        return true
    }
    func clearSelection() {
        guard editing else { return }
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
    }
    func move(key: String, rotation: Int, x: Double, y: Double) -> Bool {
        guard editing, Self.isValidPoint(x: x, y: y, rotation: rotation),
              let index = draft.bindings.firstIndex(where: { $0.key == key && $0.rotation == rotation }) else { return false }
        var copy = draft
        copy.bindings[index].x = x
        copy.bindings[index].y = y
        guard copy.validate() else { return false }
        pendingPoint = nil
        selectedJoystickIndex = nil
        selectedKey = key
        currentRotation = rotation
        draft = copy
        return true
    }
    func moveJoystick(at index: Int, x: Double, y: Double) -> Bool {
        guard editing, draft.joysticks.indices.contains(index) else { return false }
        let rotation = draft.joysticks[index].rotation
        guard Self.isValidPoint(x: x, y: y, rotation: rotation) else { return false }
        var copy = draft
        copy.joysticks[index].x = x
        copy.joysticks[index].y = y
        guard copy.validate() else { return false }
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = index
        currentRotation = rotation
        draft = copy
        return true
    }
    func resizeJoystick(at index: Int, radius: Double) -> Bool {
        guard editing, draft.joysticks.indices.contains(index) else { return false }
        var copy = draft
        copy.joysticks[index].radius = min(0.35, max(0.05, radius))
        guard copy.validate() else { return false }
        draft = copy
        return true
    }
    func setJoystickPreset(at index: Int, preset: JoystickPreset) -> Bool {
        guard editing, draft.joysticks.indices.contains(index) else { return false }
        var copy = draft
        let keys = preset.keys
        copy.joysticks[index].up = keys.up
        copy.joysticks[index].down = keys.down
        copy.joysticks[index].left = keys.left
        copy.joysticks[index].right = keys.right
        guard copy.validate() else { return false }
        draft = copy
        return true
    }
    func addJoystick(x: Double, y: Double, rotation: Int, preset: JoystickPreset = .wasd) -> Bool {
        guard editing, Self.isValidPoint(x: x, y: y, rotation: rotation) else { return false }
        var copy = draft
        let keys = preset.keys
        copy.joysticks.append(JoystickBinding(up: keys.up, down: keys.down, left: keys.left, right: keys.right, x: x, y: y, rotation: rotation))
        guard copy.validate() else { return false }
        pendingPoint = nil
        selectedKey = nil
        currentRotation = rotation
        selectedJoystickIndex = copy.joysticks.count - 1
        draft = copy
        return true
    }
    func remove(key: String, rotation: Int) -> Bool {
        guard editing else { return false }
        var copy = draft
        let countBefore = copy.bindings.count
        copy.bindings.removeAll { $0.key == key && $0.rotation == rotation }
        guard copy.bindings.count != countBefore else { return false }
        if selectedKey == key { selectedKey = nil }
        draft = copy
        return true
    }
    func removeJoystick(at index: Int) -> Bool {
        guard editing, draft.joysticks.indices.contains(index) else { return false }
        var copy = draft
        copy.joysticks.remove(at: index)
        if let selected = selectedJoystickIndex {
            if selected == index { selectedJoystickIndex = nil }
            else if selected > index { selectedJoystickIndex = selected - 1 }
        }
        draft = copy
        return true
    }
    func assign(_ key: String) -> Bool {
        guard editing else { return false }
        var copy = draft
        if let point = pendingPoint {
            let binding = MappingBinding(key: key, x: point.x, y: point.y, rotation: point.rotation)
            if let i = copy.bindings.firstIndex(where: { $0.key == key && $0.rotation == point.rotation }) {
                copy.bindings[i] = binding
            } else {
                copy.bindings.append(binding)
            }
            guard copy.validate() else { return false }
            draft = copy; pendingPoint = nil; selectedKey = nil; return true
        }
        if let existingKey = selectedKey,
           let existing = copy.bindings.first(where: { $0.key == existingKey && $0.rotation == currentRotation }) {
            copy.bindings.removeAll { ($0.key == existingKey || $0.key == key) && $0.rotation == existing.rotation }
            copy.bindings.append(MappingBinding(key: key, x: existing.x, y: existing.y, rotation: existing.rotation))
            guard copy.validate() else { return false }
            draft = copy; selectedKey = key; return true
        }
        return false
    }
    func clear(rotation: Int? = nil) {
        guard editing else { return }
        if let rotation {
            var copy = draft
            copy.bindings.removeAll { $0.rotation == rotation }
            copy.joysticks.removeAll { $0.rotation == rotation }
            draft = copy
        } else {
            draft = MappingScheme()
        }
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
    }
    func hasOtherRotationBindings(for rotation: Int) -> Bool {
        draft.bindings.contains { $0.rotation != rotation } || draft.joysticks.contains { $0.rotation != rotation }
    }
    func hasBindings(for rotation: Int) -> Bool {
        draft.bindings.contains { $0.rotation == rotation } || draft.joysticks.contains { $0.rotation == rotation }
    }
    func rotationChanged(to next: Int? = nil) {
        if let next, (0...3).contains(next) { currentRotation = next }
        pendingPoint = nil
        selectedKey = nil
        selectedJoystickIndex = nil
        onChange?()
    }
    func save() throws {
        guard editing, !pending, draft.validate(), let location else { throw KeyMappingFailure.bindingRequired.nsError }
        let current: Data?
        do { current = try Data(contentsOf: location) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { current = nil }
        guard current == baseline else { throw KeyMappingFailure.conflict.nsError }
        let bytes = try writeScheme(draft, to: location)
        resettingCorrupted = false
        baseline = bytes; scheme = draft; enabled = !scheme.isEmpty; placementMode = .tap; pendingPoint = nil; selectedKey = nil; selectedJoystickIndex = nil; editing = false
    }
    var visibleBindings: [MappingBinding] { editing ? draft.bindings : (hints && enabled ? scheme.bindings : []) }
    var visibleJoysticks: [JoystickBinding] { editing ? draft.joysticks : (hints && enabled ? scheme.joysticks : []) }

    private func loadFile(at url: URL) {
        location = url
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(MappingScheme.self, from: data)
            guard value.validate() else { throw CocoaError(.fileReadCorruptFile) }
            scheme = value; baseline = data; enabled = !value.isEmpty; failure = nil
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            scheme = MappingScheme(); baseline = nil; enabled = false; failure = nil
        } catch {
            failure = .unreadable
        }
    }

    private func writeScheme(_ value: MappingScheme, to url: URL) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
        try bytes.write(to: url, options: .atomic)
        return bytes
    }

    private var profilesDirectory: URL? {
        guard let baseLocation else { return nil }
        let stem = baseLocation.deletingPathExtension().lastPathComponent
        return baseLocation.deletingLastPathComponent().appendingPathComponent(stem, isDirectory: true)
    }

    private var activeStateURL: URL? {
        baseLocation?.deletingPathExtension().appendingPathExtension("active")
    }

    private func profileURL(for name: String) -> URL? {
        profilesDirectory?.appendingPathComponent("\(name).json")
    }

    private func readActiveProfileName() -> String? {
        guard let activeStateURL,
              let raw = try? String(contentsOf: activeStateURL, encoding: .utf8) else { return nil }
        return Self.sanitizedProfileName(raw)
    }

    private func persistActiveProfileName(_ name: String?) {
        guard let activeStateURL else { return }
        if let name {
            try? FileManager.default.createDirectory(at: activeStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? name.write(to: activeStateURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: activeStateURL)
        }
    }

    private func refreshProfiles() {
        guard let dir = profilesDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            profiles = []
            return
        }
        profiles = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { Self.sanitizedProfileName($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func sanitizedProfileName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.hasPrefix(".") else { return nil }
        let forbidden = CharacterSet(charactersIn: "/\\:\0")
        guard name.rangeOfCharacter(from: forbidden) == nil else { return nil }
        let lower = name.lowercased()
        if lower == "default" || name == "默认" || name == "默认方案" { return nil }
        return name
    }

    private static func isValidPoint(x: Double, y: Double, rotation: Int) -> Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) && (0...3).contains(rotation)
    }
}
