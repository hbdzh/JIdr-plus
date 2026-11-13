// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// AppKit's popup supplies explicit control labels and standard menu behavior.
struct DeviceToolPopUp: NSViewRepresentable {
    let label: String
    let identifier: String
    let options: [(String, String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(label)
        control.setAccessibilityIdentifier(identifier)
        if control.itemArray.map(\.title) != options.map({ $0.1 }) {
            control.removeAllItems()
            for (value, title) in options {
                control.addItem(withTitle: title)
                control.lastItem?.representedObject = value
            }
        }
        if let index = options.firstIndex(where: { $0.0 == selection }) { control.selectItem(at: index) }
    }
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            if let value = sender.selectedItem?.representedObject as? String { selection.wrappedValue = value }
        }
    }
}
