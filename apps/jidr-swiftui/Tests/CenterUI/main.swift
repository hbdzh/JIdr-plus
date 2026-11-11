// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func pump(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func eventually(_ message: String, _ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !predicate(), Date() < end { pump(0.02) }
    require(predicate(), message)
}
func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
}
func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    pump()
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.orderOut(nil)
    return bitmap
}
func brightPixels(_ bitmap: NSBitmapImageRep) -> Int {
    var count = 0
    // Left half contains only the Light thumbnail. Check the actual output,
    // not the token name or source text: it must stay white in a dark parent.
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<(bitmap.pixelsWide / 2) {
            if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               c.redComponent > 0.9, c.greenComponent > 0.9, c.blueComponent > 0.9 { count += 1 }
        }
    }
    return count
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = try CenterModel(center: CommandLine.arguments[1], bridge: "/usr/bin/false")
eventually("fixture loads") { model.connection.isOnline && model.details != nil }
let originalDevices = model.devices
model.language = 0
model.appearance = 2
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 700),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = NSHostingView(rootView: CenterView(model: model))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump()
require(window.toolbar != nil, "center has a real native toolbar")
require(window.styleMask.contains(.fullSizeContentView), "content extends into the title-bar area")
require(window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none, "native toolbar blends with content without a separator")
require(window.titleVisibility == .hidden, "window title does not duplicate the content heading")

// Clear the actual native list selection, rather than only changing the model.
// A nil selection must clear the inspector and invalidate in-flight app/details
// replies; a later refresh must not silently choose a device again.
let originalID = model.selected!
let deviceTable = descendants(window.contentView!, NSTableView.self).first { $0.numberOfRows == model.devices.count }!
deviceTable.deselectAll(nil)
eventually("native deselection reaches the model") { model.selected == nil }
require(model.details == nil && model.apps.isEmpty && !model.appsLoading, "deselection clears stale inspector content")
model.refresh()
var selectionCheckpoint = false
model.call("device.list") { _ in selectionCheckpoint = true }
eventually("refresh replies have been processed") { selectionCheckpoint }
require(model.selected == nil, "refresh preserves deliberate deselection")
model.select(originalID)
model.setDeviceSelection(nil)
selectionCheckpoint = false
model.call("device.list") { _ in selectionCheckpoint = true }
eventually("old device replies have been processed") { selectionCheckpoint }
require(model.selected == nil && model.details == nil && model.apps.isEmpty, "old requests never restore a cleared selection")
model.select(originalID)
eventually("restore the fixture selection") { model.details?.device.id == originalID }

let searchItem = window.toolbar!.items.first { $0.itemIdentifier == CenterToolbarController.searchID } as! NSSearchToolbarItem
let background = searchItem.searchField
model.searchFocusRequest += 1
pump()
require(window.firstResponder === background.currentEditor(), "device search receives requested focus")

// Reproduce the audited sequence: settings -> close -> immediately Cmd+K.
model.present(.settings)
pump()
let settings = model.settingsWindow!
require(window.attachedSheet == nil && model.sheet == nil, "settings is nonmodal")
model.settingsCategory = 2
settings.close()
model.searchFocusRequest += 1 // A pending background request must lose.
model.openPalette()
let panel = model.paletteWindow!.window!
let palette = descendants(panel.contentView!, PaletteSearchField.Field.self).first!
let editor = palette.currentEditor() as! NSTextView
// Type the first character before queued hosting/focus callbacks run, as when
// a person starts typing immediately after Cmd+K. It must not be selected away.
editor.insertText("t", replacementRange: NSRange(location: NSNotFound, length: 0))
pump()
editor.insertText("asks", replacementRange: NSRange(location: NSNotFound, length: 0))
eventually("all characters survive the focus handoff") { model.paletteQuery == "tasks" }
require(panel.firstResponder === editor, "palette owns first responder")
require(model.deviceQuery.isEmpty && background.stringValue.isEmpty, "palette typing never filters background devices")
require(model.paletteFiltered.contains { $0.action == .tasks }, "typed task command is visible")
let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
require(model.handleShortcutEvent(escape), "Escape is handled")
pump()
require(!model.paletteOpen && model.deviceQuery.isEmpty, "Escape closes only the palette")
model.present(.settings)
require(model.settingsWindow === settings && model.settingsCategory == 2, "reopening preserves the same settings window and pane")
pump()
require(settings.window?.title.contains("Data & tools") == true, "native title reflects the selected pane")
require(settings.window?.toolbar?.items.count == 5, "settings has five native toolbar categories")
require(settings.window?.toolbar?.selectedItemIdentifier?.rawValue == "jidr.preferences.2", "toolbar selection follows the retained pane")
settings.close()

let tools = AdvancedToolsWindowController(model: model, id: model.selected!, name: "Test", root: false)
tools.showWindow(nil)
pump()
require(tools.window?.appearance?.name == .darkAqua, "new tools window follows forced Dark")
model.appearance = 1
pump()
require(tools.window?.appearance?.name == .aqua, "open tools window switches to Light")
require(settings.window?.appearance?.name == .aqua, "settings switches with the same preference")
model.appearance = 0
pump()
require(tools.window?.appearance == nil && settings.window?.appearance == nil, "System releases the window appearance override")

// Tasks use a lightweight native panel with the same surface as command search.
model.openTasks()
pump()
let taskOwner = model.taskPanel!
require(window.attachedSheet == nil && taskOwner.window is LightweightPanel, "tasks opens a lightweight panel")
require(taskOwner.window?.styleMask.contains(.resizable) == false && taskOwner.window?.styleMask.contains(.closable) == false, "tasks has no standalone window controls")
require(taskOwner.window?.standardWindowButton(.closeButton)?.isHidden != false, "task panel has no traffic lights")
let outsideClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 3, y: 3), modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
app.sendEvent(outsideClick)
pump()
require(!model.tasksOpen && taskOwner.window?.isVisible == false, "clicking outside dismisses the task panel")
model.openTasks()
window.makeKeyAndOrderFront(nil)
model.openPalette()
pump()
require(!model.tasksOpen && taskOwner.window?.isVisible == false, "only one lightweight panel is displayed at a time")
require(taskOwner.window?.styleMask == model.paletteWindow?.window?.styleMask, "search and tasks share native frame styling")
require(taskOwner.window?.hasShadow == true && model.paletteWindow?.window?.hasShadow == true, "both panels use one native shadow")
let reusedPanel = model.paletteWindow!.window!
let reusedField = descendants(reusedPanel.contentView!, PaletteSearchField.Field.self).first!
require(reusedPanel.firstResponder === reusedField.currentEditor(), "reopening restores search focus")

final class Presenter: CenterWindowPresenting {
    let centerWindow: NSWindow?
    init(_ window: NSWindow) { centerWindow = window }
    func showCenterWindow() { centerWindow?.makeKeyAndOrderFront(nil) }
}
let presenter = Presenter(window)
let menu = CenterMenuController(model: model, presenter: presenter)
menu.install()
let editMenu = app.mainMenu!.items.compactMap(\.submenu).first { $0.title == "Edit" }!
let selectAllItem = editMenu.items.first { $0.action == #selector(NSText.selectAll(_:)) }!
require(selectAllItem.target == nil, "Select All uses the current first responder, not the menu controller")
let closeItem = app.windowsMenu!.items.first { $0.action == #selector(NSWindow.performClose(_:)) }!
require(closeItem.target == nil, "Close Window uses the key window's responder chain")
let searchEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: reusedPanel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
app.sendEvent(searchEscape)
pump()
require(!model.paletteOpen && !model.tasksOpen, "Escape dismisses the active lightweight panel")
taskOwner.close()
pump()
require(!model.tasksOpen, "panel dismissal synchronizes the task state")
model.openTasks()
require(model.taskPanel === taskOwner, "task window reuses one instance")
model.taskPanel?.close()
model.openPalette()
pump()
NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
require(!model.paletteOpen && model.paletteWindow?.window?.isVisible == false, "application deactivation clears the transient search state")

let packed = ActionFlowLayout.arrange([112, 108, 124, 104, 112, 152].map { CGSize(width: $0, height: 28) }, width: 272, spacing: 8)
require(packed.frames.count == 6, "all six actions stay visible")
require(packed.frames.allSatisfy { $0.maxX <= 272 }, "long English labels wrap without clipping")
require(packed.size.height >= 3 * 28 + 2 * 8, "narrow width uses multiple rows")
for pair in zip(packed.frames, packed.frames.dropFirst()) {
    require(!pair.0.intersects(pair.1), "wrapped controls never overlap")
}

let preview = SettingsView.AppearancePreviewCard(model: model)
let light = render(preview.environment(\.colorScheme, .light), width: 450, height: 150)
let dark = render(preview.environment(\.colorScheme, .dark), width: 450, height: 150)
require(brightPixels(dark) > 10000, "Light thumbnail remains white inside a Dark parent")
require(abs(brightPixels(light) - brightPixels(dark)) < 3000, "Light thumbnail is independent of surrounding appearance")

// The split remains side by side at the supported minimum, without an outer
// vertical scroll view containing the device list.
window.setContentSize(NSSize(width: 800, height: 550))
pump()
let splits = descendants(window.contentView!, NSSplitView.self)
require(splits.contains { $0.isVertical && $0.arrangedSubviews.count == 2 }, "minimum window retains a resizable master/detail split")
require(window.contentView!.bounds.width <= 801, "layout does not force the window beyond its minimum width")

// Deletion must be verified against device.list, including a server that lies
// about success. The script configures device 2 as a deliberate no-op.
let deletedID = "00000000-0000-4000-8000-000000000003"
let retainedID = "00000000-0000-4000-8000-000000000002"
model.select(deletedID)
eventually("select deletion candidate") { model.details?.device.id == deletedID }
var deletionCallbacks = 0
model.operation("device.delete", id: deletedID) { deletionCallbacks += 1 }
eventually("delete finishes after the authoritative list reply") { !model.busy.contains(deletedID) }
require(!model.devices.contains { $0.id == deletedID }, "successful deletion removes the device row")
require(model.selected != deletedID && model.details?.device.id != deletedID, "deleted device cannot remain in the inspector")
require(model.toast?.text == "Device deleted" && deletionCallbacks == 1, "success is shown only after read-back verification")
model.operation("device.delete", id: retainedID) { deletionCallbacks += 1 }
eventually("false success is checked") { !model.busy.contains(retainedID) }
require(model.devices.contains { $0.id == retainedID }, "failed deletion preserves the authoritative row")
require(model.toast?.text.contains("did not take effect") == true && model.toast?.tone == .negative && deletionCallbacks == 1, "a no-op response reports failure and never calls success")
model.operation("device.delete", id: originalID)
eventually("delete another fixture device") { !model.busy.contains(originalID) }
require(model.devices.map(\.id) == [retainedID], "only undeleted records remain")
var unsupported = false
model.call("device.restart", ["device": retainedID]) { result in
    if case .failure = result { unsupported = true }
}
eventually("unimplemented preview operations fail explicitly") { unsupported }
model.operation("device.delete", id: retainedID)
eventually("delete last device on retry") { !model.busy.contains(retainedID) }
require(model.devices.isEmpty && model.selected == nil && model.details == nil && model.apps.isEmpty,
        "deleting the last device clears both row and stale inspector content")
pump()
require(model.isEmptyDeviceLibrary, "the confirmed empty library enters onboarding")
require(!descendants(window.contentView!, NSSplitView.self).contains { $0.isVertical && $0.arrangedSubviews.count == 2 },
        "an empty library has no redundant device/details/app split")
let emptyToolbar = window.toolbar!.items.map(\.itemIdentifier.rawValue)
require(emptyToolbar == [NSToolbarItem.Identifier.flexibleSpace.rawValue, "jidr.tasks", "jidr.settings"],
        "empty-library chrome keeps only background tasks and settings")
require(!background.isEnabled, "a hidden device search cannot take keyboard focus")
model.searchFocusRequest += 1
pump()
require(window.firstResponder !== background.currentEditor() || background.currentEditor() == nil,
        "search shortcuts never focus a field removed from the toolbar")
// A new device restores the workspace and its toolbar; filtering a nonempty
// library down to zero results must keep that workspace rather than onboarding.
model.devices = originalDevices
pump()
require(!model.isEmptyDeviceLibrary, "adding a device leaves onboarding")
require(window.toolbar!.items.contains { $0.itemIdentifier == CenterToolbarController.searchID }, "search returns with the device workspace")
require(descendants(window.contentView!, NSSplitView.self).contains { $0.isVertical && $0.arrangedSubviews.count == 2 },
        "the inspector split returns when devices exist")
model.deviceQuery = "no-matching-device-name"
pump()
require(!model.isEmptyDeviceLibrary && background.isEnabled, "zero search results retain usable search and the workspace")
model.devices = []
pump()
require(model.isEmptyDeviceLibrary && window.toolbar!.items.count == 3 && model.deviceQuery.isEmpty,
        "the empty-library transition is repeatable and clears filters before a new device is created")
tools.close()
window.orderOut(nil)
model.close()
print("Center UI regressions passed: palette focus/input/Escape, native toolbar/preferences, native list deselection/stale replies, unified title bar, lightweight task/search panels, menu responder routing, full-label action wrapping, appearance propagation, rendered Light preview, minimum-size split")
