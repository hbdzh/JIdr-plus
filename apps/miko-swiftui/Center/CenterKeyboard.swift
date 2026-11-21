// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension CenterModel {

    /// Handles a key-down from the local event monitor; false lets the event
    /// reach the responder chain (text editing and everything unclaimed).
    func handleShortcutEvent(_ event: NSEvent) -> Bool {
        // A sheet owns its keyboard while it is up (its own Esc/Return before
        // the center's globals); do not steal keys across windows.
        guard sheet == nil else { return false }
        if !paletteOpen, !tasksOpen, (listHasKeyboardFocus || Self.isDeviceListFocused(event.window)) {
            if event.keyCode == 48 { keyboardDevice = nil }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                let ids = filteredDevices.map(\.id)
                if event.keyCode == 125 || event.keyCode == 126, !ids.isEmpty {
                    moveKeyboardDevice(by: event.keyCode == 125 ? 1 : -1)
                    return true
                }
                if (event.keyCode == 36 || event.keyCode == 76), let id = keyboardDevice, ids.contains(id) {
                    focusOrOpenDeviceWindow(id)
                    return true
                }
            }
        }
        let input = ShortcutInput(
            key: Self.keyName(for: event),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            context: paletteOpen ? .palette : .window,
            isEditingText: Self.isEditingText(event.window)
        )
        guard let command = ShortcutResolver.resolve(input) else { return false }
        switch command {
        case .palette:
            togglePalette()
        case .newDevice:
            present(.newDevice)
        case .settings:
            present(.settings)
        case .refreshDevices:
            refresh(); refreshJobs()
        case .focusSearch:
            guard !paletteOpen else { return false }
            searchFocusRequest += 1
        case .dismissOverlay:
            guard paletteOpen || tasksOpen else { return false }
            closeOverlay()
        case .paletteUp:
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: -1, count: paletteResultCount)
        case .paletteDown:
            paletteSelection = PaletteCatalog.move(selection: paletteSelection, by: 1, count: paletteResultCount)
        case .paletteConfirm:
            let entries = paletteFiltered
            guard paletteSelection >= 0, paletteSelection < entries.count else { return false }
            let entry = entries[paletteSelection]
            closeOverlay()
            runPaletteAction(entry.action)
        }
        return true
    }

    func moveKeyboardDevice(by delta: Int) {
        let ids = filteredDevices.map(\.id)
        guard !ids.isEmpty else { return }
        let current = keyboardDevice.flatMap { ids.firstIndex(of: $0) }
        let index = current.map { max(0, min(ids.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : ids.count - 1)
        keyboardDevice = ids[index]
    }

    private static func isDeviceListFocused(_ window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current.identifier?.rawValue == "miko-device-list" { return true }
            view = current.superview
        }
        return false
    }

    private static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 53: return "escape"
        case 36, 76: return "return"
        case 126: return "up"
        case 125: return "down"
        default: return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }
    private static func isEditingText(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        // SwiftUI text fields are edited by an NSTextView field editor.
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

}
