// SPDX-License-Identifier: GPL-3.0-only
// Unit tests for Center/Shortcuts.swift: which key presses become center
// commands, and which are left to text fields and the responder chain.
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError("Shortcuts test failed: \(message)") }
}

func input(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false,
           control: Bool = false, context: ShortcutContext = .window, editing: Bool = false) -> ShortcutInput {
    ShortcutInput(key: key, command: command, shift: shift, option: option, control: control,
                  context: context, isEditingText: editing)
}

// Window shortcuts.
check(ShortcutResolver.resolve(input("k", command: true)) == .palette, "⌘K opens the palette")
check(ShortcutResolver.resolve(input("K", command: true)) == .palette, "⌘K is case insensitive")
check(ShortcutResolver.resolve(input("n", command: true)) == .newDevice, "⌘N creates a device")
check(ShortcutResolver.resolve(input(",", command: true)) == .settings, "⌘, opens settings")
check(ShortcutResolver.resolve(input("r", command: true)) == .refreshDevices, "⌘R refreshes devices")
check(ShortcutResolver.resolve(input("k", command: true, editing: true)) == .palette, "⌘K works while typing")
check(ShortcutResolver.resolve(input("k", command: true, shift: true)) == nil, "⇧⌘K is not the palette")
check(ShortcutResolver.resolve(input("k", command: true, option: true)) == nil, "⌥⌘K belongs to another window")
check(ShortcutResolver.resolve(input("k", command: true, control: true)) == nil, "⌃⌘K is not claimed")

// "/" focuses search only when no text is being edited.
check(ShortcutResolver.resolve(input("/")) == .focusSearch, "/ focuses search")
check(ShortcutResolver.resolve(input("/", editing: true)) == nil, "/ is typed into a text field")
check(ShortcutResolver.resolve(input("/", shift: true)) == nil, "? is typed, not a shortcut")
check(ShortcutResolver.resolve(input("/", command: true)) == nil, "⌘/ is not claimed")

// Esc closes overlays but is not stolen from editors.
check(ShortcutResolver.resolve(input("escape")) == .dismissOverlay, "Esc closes an overlay at the window level")
check(ShortcutResolver.resolve(input("escape", editing: true)) == nil, "Esc reaches a text field/editor")
check(ShortcutResolver.resolve(input("escape", context: .palette)) == .dismissOverlay, "Esc closes the palette even while typing")
check(ShortcutResolver.resolve(input("escape", context: .palette, editing: true)) == .dismissOverlay, "Esc in the palette ignores the field editor")

// Palette navigation.
check(ShortcutResolver.resolve(input("up", context: .palette)) == .paletteUp, "↑ moves up")
check(ShortcutResolver.resolve(input("down", context: .palette)) == .paletteDown, "↓ moves down")
check(ShortcutResolver.resolve(input("return", context: .palette)) == .paletteConfirm, "↵ runs the selection")
check(ShortcutResolver.resolve(input("return", shift: true, context: .palette)) == nil, "⇧↵ is left to the field")
check(ShortcutResolver.resolve(input("k", command: true, context: .palette)) == .palette, "⌘K toggles the palette")
check(ShortcutResolver.resolve(input("n", command: true, context: .palette)) == nil, "⌘N is not handled inside the palette")
check(ShortcutResolver.resolve(input("/", context: .palette)) == nil, "/ is typed into the palette search")
check(ShortcutResolver.resolve(input("x")) == nil, "ordinary keys are not claimed")

print("Shortcuts tests passed")
