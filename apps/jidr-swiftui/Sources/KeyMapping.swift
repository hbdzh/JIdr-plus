// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

struct MappingBinding: Codable, Equatable {
    var key: String
    var x: Double
    var y: Double
    var rotation: Int
}
struct MappingScheme: Codable, Equatable {
    var version: Int = 1
    var bindings: [MappingBinding] = []
    func validate() -> Bool {
        guard version == 1, bindings.count <= 64 else { return false }
        var seen = Set<String>()
        for b in bindings {
            let bytes = Array(b.key.utf8)
            let validKey = b.key == "SPACE" || (bytes.count == 1 && ((65...90).contains(bytes[0]) || (48...57).contains(bytes[0])))
            guard validKey, b.x.isFinite, b.y.isFinite, (0...1).contains(b.x), (0...1).contains(b.y), (0...3).contains(b.rotation), seen.insert("\(b.rotation):\(b.key)").inserted else { return false }
        }
        return true
    }
}

final class KeyMappingStore: ObservableObject {
    @Published private(set) var scheme = MappingScheme() { didSet { onChange?() } }
    @Published private(set) var draft = MappingScheme() { didSet { onChange?() } }
    @Published private(set) var editing = false { didSet { onChange?() } }
    @Published var enabled = false { didSet { onChange?() } }
    @Published var hints = true { didSet { onChange?() } }
    @Published private(set) var pending = false
    @Published private(set) var error: String?
    var onChange: (() -> Void)?
    private var location: URL?
    private var baseline: Data?
    private var point: (Double, Double, Int)?

    func load(path: String) {
        let url = URL(fileURLWithPath: path)
        location = url
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(MappingScheme.self, from: data)
            guard value.validate() else { throw CocoaError(.fileReadCorruptFile) }
            scheme = value; baseline = data; enabled = !value.bindings.isEmpty; error = nil
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            scheme = MappingScheme(); baseline = nil; enabled = false; error = nil
        } catch { self.error = "The key map could not be read. Check the original file; it was not overwritten." }
    }
    func begin() -> Bool {
        guard location != nil, error == nil else { return false }
        draft = scheme; point = nil; pending = false; editing = true; return true
    }
    func cancel() { point = nil; pending = false; editing = false }
    func place(x: Double, y: Double, rotation: Int) {
        guard editing, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), (0...3).contains(rotation) else { return }
        point = (x,y,rotation); pending = true; onChange?()
    }
    func assign(_ key: String) -> Bool {
        guard editing, let p = point else { return false }
        var copy = draft
        let binding = MappingBinding(key: key, x: p.0, y: p.1, rotation: p.2)
        if let i = copy.bindings.firstIndex(where: { $0.key == key && $0.rotation == p.2 }) { copy.bindings[i] = binding }
        else { copy.bindings.append(binding) }
        guard copy.validate() else { return false }
        draft = copy; point = nil; pending = false; return true
    }
    func clear() { guard editing else { return }; draft = MappingScheme(); point = nil; pending = false }
    func rotationChanged() { point = nil; pending = false; onChange?() }
    func save() throws {
        guard editing, !pending, draft.validate(), let location else { throw NSError(domain: "JidrMapping", code: 1, userInfo: [NSLocalizedDescriptionKey:"Bind a key to the selected position first"] ) }
        let current: Data?
        do { current = try Data(contentsOf: location) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { current = nil }
        guard current == baseline else { throw NSError(domain: "JidrMapping", code: 2, userInfo:[NSLocalizedDescriptionKey:"The key map changed elsewhere. Cancel the edit and open it again."] ) }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(draft)
        try bytes.write(to: location, options: .atomic)
        baseline = bytes; scheme = draft; enabled = !scheme.bindings.isEmpty; editing = false
    }
    var visibleBindings: [MappingBinding] { editing ? draft.bindings : (hints && enabled ? scheme.bindings : []) }
}
