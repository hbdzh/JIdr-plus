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
let stoppedDevice = model.devices.first { $0.stopped }!
let moreButton = DeviceMoreButton(model: model, device: stoppedDevice, showApps: {})
let menuCoordinator = moreButton.makeCoordinator()
let deleteItem = menuCoordinator.menu().items.first { $0.tag == 13 }!
for device in model.devices {
    let menu = DeviceMoreButton(model: model, device: device, showApps: {}).makeCoordinator().menu()
    require(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil },
            "every available device menu action has a system icon")
    require(!menu.items.contains { $0.tag == 11 }, "stop is available on the device row, not in the more menu")
    if device.running { require(menu.items.contains { $0.tag == 12 && $0.isEnabled }, "running devices retain restart") }
}
let redTitle = deleteItem.attributedTitle!
require((redTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == .systemRed,
        "enabled device deletion uses the native red menu text")
menuCoordinator.performAction(deleteItem)
require(model.deleteTarget?.id == stoppedDevice.id, "red menu action opens confirmation for the correct device")
model.deleteTarget = nil
let originalDevices = model.devices
let thumbnailContext = CGContext(data: nil, width: 320, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
thumbnailContext.setFillColor(NSColor.systemGreen.cgColor)
thumbnailContext.fill(CGRect(x: 0, y: 0, width: 320, height: 640))
model.rememberThumbnail(thumbnailContext.makeImage()!, device: originalDevices[0].id)
require(model.deviceThumbnails[originalDevices[0].id]?.height == 224 && model.deviceThumbnails[originalDevices[1].id] == nil,
        "last frame is reduced and retained only for its own device")
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
let centerToolbarIDs = window.toolbar!.items.map(\.itemIdentifier.rawValue)
require(centerToolbarIDs.contains("jidr.new") && centerToolbarIDs.contains("jidr.view") && centerToolbarIDs.contains("jidr.settings"),
        "toolbar exposes creation, view switching and settings")
require(!centerToolbarIDs.contains("jidr.refresh"), "manual refresh is absent from the default toolbar")
let viewSwitch = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "jidr.view" }!.view as! NSSegmentedControl
viewSwitch.selectedSegment = 0
NSApp.sendAction(viewSwitch.action!, to: viewSwitch.target, from: viewSwitch)
pump()
require(model.gridView, "grid segment switches the device workspace")
viewSwitch.selectedSegment = 1
NSApp.sendAction(viewSwitch.action!, to: viewSwitch.target, from: viewSwitch)
pump()
require(!model.gridView, "list segment restores the device list")
let compactSearch = window.toolbar!.items.first { $0.itemIdentifier == CenterToolbarController.searchID } as! NSSearchToolbarItem
require(compactSearch.preferredWidthForSearchField == 200, "device search uses the intended compact width")
require(compactSearch.searchField.placeholderString == "Search devices", "search placeholder describes devices")

// Clearing the detail-loading target must invalidate in-flight replies; it is
// independent of the native list, which no longer selects a device on click.
let originalID = model.selected!
eventually("device list is attached") { descendants(window.contentView!, NSScrollView.self).contains { $0.identifier?.rawValue == "jidr-device-list" } }
model.listHasKeyboardFocus = true
let deviceDown = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
                                  charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
require(model.handleShortcutEvent(deviceDown) && model.keyboardDevice == model.filteredDevices.first?.id,
        "Down focuses the first visible device without changing the detail target")
require(model.handleShortcutEvent(deviceDown) && model.keyboardDevice == model.filteredDevices[1].id,
        "Down advances keyboard focus to the next device")
require(model.selected == originalID, "keyboard focus is independent of the detail-loading target")
model.keyboardDevice = nil
model.listHasKeyboardFocus = false
model.setDeviceSelection(nil)
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

// Filtering must invalidate selection and in-flight inspector data.
model.deviceQuery = "audit-no-matching-device"
require(model.filteredDevices.isEmpty && model.selected == nil && model.details == nil && model.apps.isEmpty,
        "search cannot leave an actionable hidden device in the inspector")
model.refresh()
pump()
require(model.selected == nil, "a refresh cannot select a device excluded by search")
model.deviceQuery = ""
model.select(originalID)
eventually("restore after search") { model.details?.device.id == originalID }
model.deviceQuery = "示例应用"
eventually("app search finds its running device") { model.filteredDevices.count == 1 && model.filteredDevices.first?.id == originalID }
require(model.appSearchMatches[originalID] == "示例应用", "the matching app is identified for its device")
model.deviceQuery = ""
model.select(originalID)
eventually("restore after app search") { model.details?.device.id == originalID }

// Failures and unanswered reads leave a recoverable state, never a spinner.
let testHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JIDR_HOME"]!)
let failedDetails = testHome.appendingPathComponent("fail-details")
try Data().write(to: failedDetails)
model.load(originalID)
eventually("detail failure is surfaced") { model.detailsError != nil && !model.detailsLoading }
require(model.details == nil, "failed reads cannot leave stale editable details")
try FileManager.default.removeItem(at: failedDetails)
model.retryDetails()
eventually("detail retry clears the error") { model.details != nil && model.detailsError == nil }
let droppedDetails = testHome.appendingPathComponent("drop-details")
try Data().write(to: droppedDetails)
model.detailsReadTimeout = 0.12
model.load(originalID)
eventually("unanswered detail reads time out") { model.detailsError?.contains("timed out") == true && !model.detailsLoading }
try FileManager.default.removeItem(at: droppedDetails)
model.detailsReadTimeout = 8
model.retryDetails()
eventually("retry after timeout succeeds") { model.details != nil && model.detailsError == nil }

// A failed request for one device must not open its pending sheet for another.
try Data().write(to: failedDetails)
model.presentDeviceSheet(.edit, device: model.devices[1].id)
eventually("requested device details fail") { model.detailsError != nil && !model.detailsLoading }
try FileManager.default.removeItem(at: failedDetails)
model.select(originalID)
eventually("new selection loads") { model.details?.device.id == originalID }
require(model.sheet == nil, "changing selection cancels a failed pending device sheet")

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
model.paletteQuery = ""
pump()
require(model.paletteResultCount > 8 && model.paletteResultCount == model.paletteFiltered.count,
        "the complete command catalog is available")
let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: panel.windowNumber, context: nil, characters: "\u{f701}",
                           charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
for _ in 0..<9 { require(model.handleShortcutEvent(down), "palette handles arrow navigation") }
require(model.paletteSelection == 9, "keyboard navigation reaches results beyond eight")
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
require(!settings.window!.styleMask.contains(.miniaturizable) && !settings.window!.styleMask.contains(.resizable),
        "preferences do not offer minimize, zoom or full-screen controls")
let dataHeight = settings.window!.contentLayoutRect.height
model.settingsCategory = 0
pump()
require(settings.window!.contentLayoutRect.height < dataHeight, "preferences adapt height to the selected pane")

// Editable preferences must remain recognizable as controls in grouped forms.
for category in [1, 3] {
    model.settingsCategory = category
    pump()
    let fields = descendants(settings.window!.contentView!, NSTextField.self).filter { $0.isEditable }
    require(fields.count >= 2, "numeric and path preferences expose editable native fields")
    require(fields.allSatisfy { $0.isBezeled }, "editable preferences have a visible input border")
}
model.settingsCategory = 2
settings.close()

let tools = DeviceToolsPanelController(model: model, id: model.selected!, name: "Test", root: false)
tools.present(relativeTo: window)
pump()
require(tools.window?.appearance?.name == .darkAqua, "new tools window follows forced Dark")
require(tools.window is DeviceToolsNativePanel && tools.window?.parent === window, "device tools is attached to its owner as a native utility panel")
require(tools.window?.canBecomeMain == false && tools.window?.canBecomeKey == true, "tools accepts input without taking the main window role")
require(tools.window is LightweightPanel && tools.window?.titleVisibility == .hidden,
        "tools shares the app's lightweight panel chrome")
require(tools.window?.isExcludedFromWindowsMenu == true, "device tools never becomes an independent Window-menu entry")
require(tools.window?.styleMask.contains(.miniaturizable) == false && tools.window?.collectionBehavior.contains(.fullScreenNone) == true,
        "tools omits minimize and full-screen while retaining native resizing")
require(tools.window?.standardWindowButton(.closeButton)?.isHidden != false,
        "tools hides native traffic lights; the shared device footer provides Close")
app.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
window.makeMain()
pump()
tools.window?.makeKeyAndOrderFront(nil)
pump()
// Background test executables cannot activate macOS windows reliably. The
// native role contract is checked above; global key/main appearance is also
// inspected in the packaged foreground app.
require(!tools.window!.isMainWindow, "tools never takes the main window role")
eventually("native battery field loads its actual value") {
    descendants(tools.window!.contentView!, NSTextField.self).contains { $0.isEditable && $0.stringValue == "75" }
}
let chargeField = descendants(tools.window!.contentView!, NSTextField.self).first { $0.isEditable && $0.stringValue == "75" }!
require(chargeField.bounds.width >= 70, "native form labels never compress the battery input to an unreadable width")
let toolTables = descendants(tools.window!.contentView!, NSTableView.self)
require(toolTables.count == 1 && toolTables[0] is CompactDeviceToolsTableView && toolTables[0].style == .sourceList && toolTables[0].rowHeight == 32, "device tools uses its approved compact native sidebar")
require(tools.window!.firstResponder === toolTables[0], "native sidebar receives initial keyboard focus")
// User-reported regression: selecting tools must never resize or move the panel.
let initialToolsFrame = tools.window!.frame
for section in 0..<10 {
    tools.selection.section = section
    pump()
    require(tools.window!.frame == initialToolsFrame, "section jumps keep a stable panel frame")
}
var adjustedToolsFrame = initialToolsFrame
adjustedToolsFrame.size.width += 70
adjustedToolsFrame.size.height += 35
tools.window!.setFrame(adjustedToolsFrame, display: true)
let userToolsFrame = tools.window!.frame
for section in [8, 4, 0, 3, 7] {
    tools.selection.section = section
    pump()
    require(tools.window!.frame == userToolsFrame, "section jumps preserve a user's manual panel size")
}
tools.selection.section = 8
tools.present(relativeTo: window, root: true)
require(tools.window!.frame == userToolsFrame, "reusing the visible Root panel also preserves size and position")
require(tools.selection.section == 4, "Root entry switches a reused tools panel to Root")
let nestedToolsSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
nestedToolsSheet.isReleasedWhenClosed = false
tools.window!.beginSheet(nestedToolsSheet)
pump()
let nestedEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: nestedToolsSheet.windowNumber, context: nil, characters: "\u{1b}",
                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
app.sendEvent(nestedEscape)
require(tools.window?.isVisible == true, "Escape in a child sheet must not dismiss device tools")
tools.window!.endSheet(nestedToolsSheet)
nestedToolsSheet.orderOut(nil)

model.appearance = 1
pump()
require(tools.window?.appearance?.name == .aqua, "open tools window switches to Light")
require(settings.window?.appearance?.name == .aqua, "settings switches with the same preference")
model.appearance = 0
pump()
require(tools.window?.appearance == nil && settings.window?.appearance == nil, "System releases the window appearance override")
let toolEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: tools.window!.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
tools.window!.makeFirstResponder(nil)
tools.window!.interpretKeyEvents([toolEscape])
pump()
require(tools.window?.isVisible == false && tools.window?.parent == nil, "Escape closes and detaches the tools panel")
final class CompositionEditor: NSTextView {
    var cancelledComposition = false
    override func cancelOperation(_ sender: Any?) {
        cancelledComposition = true
        unmarkText()
    }
}
let compositionPanel = DeviceToolsNativePanel()
let compositionEditor = CompositionEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
compositionPanel.contentView = compositionEditor
compositionPanel.makeKeyAndOrderFront(nil)
compositionPanel.makeFirstResponder(compositionEditor)
compositionEditor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
require(compositionEditor.hasMarkedText(), "the test has an active input composition")
let compositionEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: compositionPanel.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
compositionEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
pump()
require(compositionEditor.cancelledComposition && compositionPanel.isVisible, "Escape cancels input composition without closing tools")
compositionPanel.makeFirstResponder(nil)
compositionPanel.cancelOperation(nil)
require(!compositionPanel.isVisible, "an unhandled cancel closes the panel")
let temporaryOwner = NSWindow(contentRect: window.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
temporaryOwner.isReleasedWhenClosed = false
tools.present(relativeTo: temporaryOwner)
temporaryOwner.close()
pump()
require(tools.window?.isVisible == false, "closing the owner also closes its tools panel")


let stoppedID = "00000000-0000-4000-8000-000000000002"
func requests(_ method: String, device: String) -> Int {
    let data = (try? String(contentsOf: testHome.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
    return data.split(separator: "\n").filter { line in
        guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return value["method"] as? String == method && value["device"] as? String == device
    }.count
}
let certReads = requests("root.cacert.list", device: stoppedID)
let rootHost = NSHostingView(rootView: RootDevToolsView(model: model, id: stoppedID, running: false))
let rootWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
rootWindow.isReleasedWhenClosed = false
rootWindow.contentView = rootHost
rootWindow.orderFrontRegardless()
eventually("stopped Root page loads offline status") { requests("root.status", device: stoppedID) > 0 }
pump()
require(requests("root.cacert.list", device: stoppedID) == certReads, "stopped Root pages never request live certificates")
rootWindow.orderOut(nil)
let cameraSelection = DeviceToolsSelection(section: 8)
let cameraHost = NSHostingView(rootView: AdvancedToolsView(model: model, id: stoppedID, initialRoot: false, selection: cameraSelection))
rootWindow.contentView = cameraHost
rootWindow.orderFrontRegardless()
eventually("camera settings load for a stopped device") { requests("camera.get", device: stoppedID) > 0 }
require(requests("camera.set", device: stoppedID) == 0, "opening cameras never writes settings")
pump()
let cameraPopups = descendants(cameraHost, NSPopUpButton.self)
require(cameraPopups.contains { $0.accessibilityLabel() == "Back camera" }, "back camera exposes a distinct native accessibility label")
require(cameraPopups.contains { $0.accessibilityLabel() == "Front camera" }, "front camera exposes a distinct native accessibility label")
let backPopup = cameraPopups.first { $0.accessibilityLabel() == "Back camera" }!
require(backPopup.selectedItem?.representedObject as? String == "none", "the popup displays the actual saved source")
let cameraReads = requests("camera.get", device: stoppedID)
backPopup.selectItem(withTitle: "Emulated")
NSApp.sendAction(backPopup.action!, to: backPopup.target, from: backPopup)
pump()
cameraSelection.section = 4
pump()
cameraSelection.section = 8
pump()
let restoredPopup = descendants(cameraHost, NSPopUpButton.self).first { $0.accessibilityLabel() == "Back camera" }!
require(restoredPopup.selectedItem?.representedObject as? String == "emulated", "unsaved camera edits survive section jumps")
require(requests("camera.get", device: stoppedID) == cameraReads, "scrolling back never overwrites edits with an automatic reload")
require(requests("camera.set", device: stoppedID) == 0, "editing a draft never writes device configuration")
let disabledCameraHost = NSHostingView(rootView: DeviceToolPopUp(label: "Back camera", identifier: "disabled-camera",
    options: [("none", "None")], selection: .constant("none")).disabled(true))
rootWindow.contentView = disabledCameraHost
rootWindow.orderFrontRegardless()
pump()
let disabledCamera = descendants(disabledCameraHost, NSPopUpButton.self).first!
require(!disabledCamera.isEnabled, "native camera controls respect the disabled state while a request is active")
rootWindow.orderOut(nil)
rootWindow.contentView = nil

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
let deviceMenu = app.mainMenu!.items.compactMap(\.submenu).first { $0.title == "Device" }!
menu.menuNeedsUpdate(deviceMenu)
require(menu.targetDevice(for: window) == nil, "the center has no implicit menu device")
for device in model.devices {
    let submenu = deviceMenu.items.first { $0.title == device.name }?.submenu
    require(submenu != nil, "each device has an explicitly named menu")
    require(submenu!.items.filter { $0.action != nil }.allSatisfy { ($0.representedObject as? String) == device.id },
            "device menu commands retain their explicit target")
}
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

// The device list remains usable at the supported minimum without a fixed detail pane.
window.setContentSize(NSSize(width: 800, height: 550))
pump()
let splits = descendants(window.contentView!, NSSplitView.self)
require(!splits.contains { $0.isVertical && $0.arrangedSubviews.count == 2 }, "minimum window has no fixed detail split")
require(descendants(window.contentView!, NSScrollView.self).contains { $0.identifier?.rawValue == "jidr-device-list" }, "device list remains visible at minimum size")
require(window.contentView!.bounds.width <= 801, "layout does not force the window beyond its minimum width")

// Deletion must be verified against device.list, including a server that lies
// about success. The script configures device 2 as a deliberate no-op.
let deletedID = "00000000-0000-4000-8000-000000000003"
let retainedID = "00000000-0000-4000-8000-000000000002"
model.select(deletedID)
eventually("select deletion candidate") { model.details?.device.id == deletedID }
var deletionCallbacks = 0
model.requestDeletion(deletedID)
let deletionTarget = model.deleteTarget!
require(deletionTarget.name == model.devices.first { $0.id == deletedID }!.name, "confirmation identifies the device by name")
model.select(retainedID)
model.confirmDeletion(deletionTarget)
eventually("delete finishes after the authoritative list reply") { !model.busy.contains(deletedID) }
require(!model.devices.contains { $0.id == deletedID }, "successful deletion removes the device row")
require(model.selected != deletedID && model.details?.device.id != deletedID, "deleted device cannot remain in the inspector")
require(model.toast?.text == "Device deleted" && model.devices.contains { $0.id == retainedID }, "success is shown only after read-back verification")
model.operation("device.delete", id: retainedID) { deletionCallbacks += 1 }
eventually("false success is checked") { !model.busy.contains(retainedID) }
require(model.devices.contains { $0.id == retainedID }, "failed deletion preserves the authoritative row")
require(model.toast?.text.contains("did not take effect") == true && model.toast?.tone == .negative && deletionCallbacks == 0, "a no-op response reports failure and never calls success")
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
require(emptyToolbar == ["jidr.new", NSToolbarItem.Identifier.flexibleSpace.rawValue, "jidr.tasks", "jidr.settings"],
        "empty-library chrome keeps creation, background tasks and settings")
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
require(descendants(window.contentView!, NSScrollView.self).contains { $0.identifier?.rawValue == "jidr-device-list" },
        "the device list returns when devices exist")
model.deviceQuery = "no-matching-device-name"
pump()
require(!model.isEmptyDeviceLibrary && background.isEnabled, "zero search results retain usable search and the workspace")
model.devices = []
pump()
require(model.isEmptyDeviceLibrary && window.toolbar!.items.count == 4 && model.deviceQuery.isEmpty,
        "the empty-library transition is repeatable and clears filters before a new device is created")
tools.close()
window.orderOut(nil)
model.close()
print("Center UI regressions passed: palette focus/input/Escape, native toolbar/preferences, native list selection/stale replies, unified title bar, task/search panels, menu routing, appearance, minimum-size list")
