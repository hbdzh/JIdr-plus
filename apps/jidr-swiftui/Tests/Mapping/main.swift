// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jidr-mapping-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let path = dir.appendingPathComponent("device.json")
let store = KeyMappingStore()
store.load(path: path.path)
precondition(store.begin())
store.place(x: 0.3, y: 0.7, rotation: 0)
precondition(!store.assign("!"))
precondition(store.assign("A"))
try store.save()
let read = try JSONDecoder().decode(MappingScheme.self, from: Data(contentsOf:path))
precondition(read.bindings == [MappingBinding(key:"A", x:0.3, y:0.7, rotation:0)])
precondition(store.begin())
store.place(x: 0.1, y: 0.2, rotation: 1)
precondition(store.assign("A"))
try Data("external change".utf8).write(to:path)
do { try store.save(); fatalError("external change overwritten") } catch { }
let remaining = try Data(contentsOf:path)
precondition(remaining == Data("external change".utf8))
let broken = KeyMappingStore(); broken.load(path:path.path)
precondition(broken.error != nil && !broken.begin())
print("KeyMapping tests passed")
