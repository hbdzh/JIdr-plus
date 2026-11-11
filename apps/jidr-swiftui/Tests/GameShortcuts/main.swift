// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Binding validation mirrors game_shortcuts.rs::Binding::new.
precondition(ShortcutBinding.make(key: "s", command: true, control: false, shift: true, alt: false)?.key == "S")
precondition(ShortcutBinding.make(key: "S", command: true, control: false, shift: true, alt: false)?.display == "⇧⌘S")
precondition(ShortcutBinding.make(key: "AB", command: true, control: false, shift: false, alt: false) == nil)
precondition(ShortcutBinding.make(key: "!", command: true, control: false, shift: false, alt: false) == nil)
precondition(ShortcutBinding.make(key: "K", command: false, control: false, shift: false, alt: false) == nil)
// ⌘Q/⌘W/… stay with macOS.
precondition(ShortcutBinding.make(key: "Q", command: true, control: false, shift: false, alt: false) == nil)
precondition(ShortcutBinding.make(key: "Q", command: true, control: true, shift: false, alt: false) != nil)
precondition(ShortcutBinding.make(key: "K", command: true, control: false, shift: false, alt: false) != nil)

// The default file matches the Slint defaults: ⇧⌘S/F/J/I/T.
let standard = GameShortcuts.standard
precondition(standard.version == 1 && standard.bindings.count == 5)
precondition(standard.validate())
precondition(standard.bindings.map(\.key) == ["S", "F", "J", "I", "T"])
precondition(standard.bindings.allSatisfy { $0.command && $0.shift && !$0.control && !$0.alt })
var duplicate = standard
precondition(!duplicate.assign(0, standard.bindings[1]))
precondition(duplicate.bindings[0].key == "S")

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("jidr-shortcuts-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let device = UUID().uuidString.lowercased()
let path = root.appendingPathComponent("game-shortcuts/\(device).json")

// A missing file loads the Slint defaults without an error.
let store = GameShortcutsStore()
store.load(dataDirectory: root.path, device: device)
precondition(store.loaded && store.failure == nil)
precondition(store.shortcuts == .standard)

// Rebind action 0 and save atomically; a fresh store reads it back.
precondition(store.beginCapture(0))
precondition(store.assign(key: "k", command: true, control: false, shift: true, alt: false) == nil)
precondition(store.shortcuts.bindings[0].key == "K")
precondition(FileManager.default.fileExists(atPath: path.path))
let raw = try JSONDecoder().decode(GameShortcuts.self, from: Data(contentsOf: path))
precondition(raw.bindings[0].key == "K")
let reloaded = GameShortcutsStore()
reloaded.load(dataDirectory: root.path, device: device)
precondition(reloaded.shortcuts.bindings[0].key == "K")
precondition(reloaded.action(for: ShortcutBinding(key: "K", command: true, control: false, shift: true, alt: false)) == .screenshot)

// Conflicts, invalid chords and reserved chords are refused without touching
// the file.
let before = try Data(contentsOf: path)
precondition(reloaded.beginCapture(1))
precondition(reloaded.assign(key: "K", command: true, control: false, shift: true, alt: false) == .conflict)
precondition(reloaded.assign(key: "Q", command: true, control: false, shift: false, alt: false) == .invalidChord)
precondition(reloaded.assign(key: "f", command: true, control: false, shift: true, alt: false) == nil)
let afterAssign = try Data(contentsOf: path)
precondition(afterAssign != before)
let afterConflict = try Data(contentsOf: path)

// A corrupt file is refused and never overwritten.
let corrupt = root.appendingPathComponent("game-shortcuts/broken.json")
try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
let corruptBytes = Data("{ not json".utf8)
try corruptBytes.write(to: corrupt)
let broken = GameShortcutsStore()
broken.load(dataDirectory: root.path, device: "broken")
precondition(broken.failure == .invalidConfiguration)
precondition(!broken.loaded)
precondition(!broken.beginCapture(0))
let corruptAfter = try Data(contentsOf: corrupt)
precondition(corruptAfter == corruptBytes)

// A structurally invalid file (duplicate chords) is refused too.
var invalid = GameShortcuts.standard
invalid.bindings[1] = invalid.bindings[0]
let invalidURL = root.appendingPathComponent("game-shortcuts/invalid.json")
try JSONEncoder().encode(invalid).write(to: invalidURL)
let invalidStore = GameShortcutsStore()
invalidStore.load(dataDirectory: root.path, device: "invalid")
precondition(invalidStore.failure == .invalidConfiguration)

// Action labels and failure copy are bilingual.
precondition(GameShortcutsStore.actionLabel(.overlay, language: 0) == "Debug overlay")
precondition(GameShortcutsStore.actionLabel(.overlay, language: 1) == "调试浮层")
precondition(ShortcutFailure.describe(.conflict, language: 0) == "That shortcut is already in use.")
precondition(ShortcutFailure.describe(.conflict, language: 1) == "该快捷键已被占用。")
_ = afterConflict

print("Game shortcut tests passed")
