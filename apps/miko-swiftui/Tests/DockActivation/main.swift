// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func window() -> NSWindow {
    let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    result.isReleasedWhenClosed = false
    return result
}
let first = window()
let second = window()
let hidden = window()
let center = window()
first.orderFront(nil)
second.orderFront(nil)
center.orderFront(nil)
let ordered = [center, second, hidden, first]
let result = DockWindowActivation.visiblePlayers([first, second, hidden], orderedWindows: ordered)
precondition(result.count == 2 && result[0] === second && result[1] === first,
             "reopen must bring visible players forward in their existing order, excluding other and hidden windows")
precondition(DockWindowActivation.visiblePlayers([], orderedWindows: ordered).isEmpty)
second.orderOut(nil)
let remaining = DockWindowActivation.visiblePlayers([first, second], orderedWindows: ordered)
precondition(remaining.count == 1 && remaining[0] === first)
[first, second, hidden, center].forEach { $0.close() }
print("Dock window activation tests passed")
