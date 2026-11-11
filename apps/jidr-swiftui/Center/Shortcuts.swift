// SPDX-License-Identifier: GPL-3.0-only
// Global keyboard shortcuts for the device center. Resolution is pure so it
// is unit-tested offline; CenterModel feeds it NSEvents and AppKit state.
//
// The rules come from the Slint window's key handler (ui/app.slint): ⌘K opens
// the palette, ⌘N creates a device, ⌘, opens settings, Esc closes overlays.
// Keys that a text field needs are never swallowed: "/" only focuses the
// search field when no text is being edited, and Esc only closes an overlay.

import Foundation

/// Where the key press lands: the window, or one of the overlays it owns.
enum ShortcutContext: Equatable {
    case window
    case palette
}

/// What the center does for a key press.
enum CenterShortcut: Equatable {
    case palette            // ⌘K
    case newDevice          // ⌘N
    case settings           // ⌘,
    case refreshDevices     // ⌘R
    case focusSearch        // /
    case dismissOverlay     // Esc
    case paletteUp          // ↑ in the palette
    case paletteDown        // ↓ in the palette
    case paletteConfirm     // ↵ in the palette
}

/// One key press, as the AppKit layer sees it.
struct ShortcutInput: Equatable {
    /// Lowercase character, or "up" / "down" / "return" / "escape".
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false
    var context: ShortcutContext = .window
    /// A text field/editor has the keyboard focus (the responder is an
    /// NSTextView field editor). Plain "/" and Esc stay with it in that case.
    var isEditingText = false
}

enum ShortcutResolver {
    /// The command for `input`, or nil when the event must reach the responder
    /// chain (text editing, other apps' shortcuts, unclaimed keys).
    static func resolve(_ input: ShortcutInput) -> CenterShortcut? {
        let key = input.key.lowercased()

        if key == "escape" {
            switch input.context {
            case .palette: return .dismissOverlay
            // Esc must reach a text field/editor that is editing; only an
            // overlay makes the window consume it.
            case .window: return input.isEditingText ? nil : .dismissOverlay
            }
        }

        if input.context == .palette {
            // The palette's search field owns arrows and Return. Only the
            // global toggle (⌘K) and Esc are handled above the field.
            if input.command && !input.shift && !input.option && !input.control && key == "k" {
                return .palette
            }
            guard !input.command, !input.shift, !input.option, !input.control else { return nil }
            switch key {
            case "up": return .paletteUp
            case "down": return .paletteDown
            case "return": return .paletteConfirm
            default: return nil
            }
        }

        // ⌘ shortcuts work while a text field is focused (AppKit processes key
        // equivalents before text insertion), but other modifier chords belong
        // to the player window or the system.
        if input.command && !input.shift && !input.option && !input.control {
            switch key {
            case "k": return .palette
            case "n": return .newDevice
            case ",": return .settings
            case "r": return .refreshDevices
            default: return nil
            }
        }

        // Plain keys: only "/" while nothing is being edited.
        if !input.command && !input.shift && !input.option && !input.control, !input.isEditingText, key == "/" {
            return .focusSearch
        }
        return nil
    }
}
