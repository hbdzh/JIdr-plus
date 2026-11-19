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
setenv("MIKO_UI_SDK_PROGRESS", "1", 1)
let model = try CenterModel(center: CommandLine.arguments[1], bridge: "/usr/bin/false")
let directDeviceView = NewDeviceView(model: model, startAtDeviceSetup: true)
let initialDeviceStep = Mirror(reflecting: directDeviceView).children.first { $0.label == "_step" }?.value as? State<Int>
require(initialDeviceStep?.wrappedValue == 3, "new-device panel starts on the configuration page before its first render")
unsetenv("MIKO_UI_SDK_PROGRESS")
eventually("fixture loads") { model.connection.isOnline && model.details != nil }
// Settings follows the selected pane and stays within the current display.
let settingsController = SettingsWindowController(model: model)
settingsController.showWindow(nil)
settingsController.window?.orderFrontRegardless()
settingsController.window?.displayIfNeeded()
pump(0.8)
let settingsWindow = settingsController.window!
let generalHeight = settingsWindow.frame.height
model.settingsCategory = 2
pump(0.8)
let measuredDataHeight = settingsWindow.frame.height
if let screen = settingsWindow.screen {
    require(settingsWindow.frame.width <= screen.frame.width * 0.7 + 1 &&
            settingsWindow.frame.height <= screen.frame.height * 0.7 + 1,
            "settings window is capped at 70 percent of the current screen")
}
require(measuredDataHeight > generalHeight + 20, "settings window grows to fit a longer pane")
// Shrinking during a SwiftUI layout used to leave a stale native window
// surface. Check both the content geometry and native input after a real
// tall-to-short transition, then repeat it to exercise deferred updates.
for _ in 0..<3 {
    model.settingsCategory = 3
    pump(0.4)
    let root = settingsWindow.contentView!
    root.layoutSubtreeIfNeeded()
    require(abs(root.bounds.height - settingsWindow.frame.height) < 1,
            "settings content matches the resized native window")
    let fields = descendants(root, NSTextField.self).filter { $0.isEditable && $0.window === settingsWindow }
    require(!fields.isEmpty, "the shorter settings pane exposes an editable field")
    let field = fields[0]
    let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: root)
    let hit = root.hitTest(point)
    require(hit === field || hit?.isDescendant(of: field) == true,
            "settings controls remain hit-testable after shrinking")
    model.settingsCategory = 2
    pump(0.4)
}

var smallFrame = settingsWindow.frame
smallFrame.size.height = 300
settingsWindow.setFrame(smallFrame, display: true)
pump(0.2)
let settingsScrolls = descendants(settingsWindow.contentView!, NSScrollView.self)
require(settingsScrolls.contains { scroll in
    guard let document = scroll.documentView else { return false }
    return scroll.hasVerticalScroller && document.frame.height > scroll.contentSize.height + 1
}, "settings content scrolls when it exceeds the available height")
model.settingsCategory = 5
pump(0.8)
require(settingsWindow.frame.height < measuredDataHeight - 20, "settings window shrinks for a shorter pane")
settingsController.close()
model.settingsCategory = 0
// Installation has its own progress page. Its events must not leave a second,
// stale progress message in the global notice after the operation ends.
model.notice = "Unrelated notice"
var sdkProgressReceived = false
var sdkRequestFinished = false
model.call("sdk.install", onProgress: { message, _, _ in
    sdkProgressReceived = message == "Downloading emulator"
}) { _ in sdkRequestFinished = true }
eventually("synthetic SDK installation finishes") { sdkRequestFinished }
require(sdkProgressReceived && model.notice == "Unrelated notice",
        "handled installation progress does not overwrite the global notice")
model.notice = ""
let stoppedDevice = model.devices.first { $0.stopped }!
let moreButton = DeviceMoreButton(model: model, device: stoppedDevice)
let menuCoordinator = moreButton.makeCoordinator()
let deleteItem = menuCoordinator.menu().items.first { $0.tag == 13 }!
for device in model.devices {
    let menu = DeviceMoreButton(model: model, device: device).makeCoordinator().menu()
    require(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil },
            "every available device menu action has a system icon")
    require(!menu.items.contains { $0.tag == 1 }, "device menus omit the redundant details dialog")
    require(!menu.items.contains { [2, 3, 4, 5, 7, 8, 9, 10].contains($0.tag) }, "more menu omits actions already available in the overview")
    require(!menu.items.contains { $0.tag == 11 }, "stop is available in the overview header, not in the more menu")
    if device.running { require(menu.items.contains { $0.tag == 12 && $0.isEnabled }, "running devices retain restart") }
}
// Advanced information is collapsed by default and reveals technical fields on demand.
final class AdvancedInfoTestState: ObservableObject { @Published var expanded = false }
struct AdvancedInfoTestHost: View {
    @ObservedObject var state: AdvancedInfoTestState
    let model: CenterModel
    let device: Device
    var body: some View {
        DeviceAdvancedInformation(model: model, device: device, isExpanded: $state.expanded).padding(24)
    }
}
let infoState = AdvancedInfoTestState()
let infoDevice = model.devices.first { $0.running }!
let infoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
infoWindow.isReleasedWhenClosed = false
infoWindow.contentView = NSHostingView(rootView: AdvancedInfoTestHost(state: infoState, model: model, device: infoDevice))
infoWindow.orderFrontRegardless()
pump()
let collapsedHeight = infoWindow.contentView!.fittingSize.height
infoState.expanded = true
pump()
let expandedHeight = infoWindow.contentView!.fittingSize.height
require(expandedHeight > collapsedHeight + 100,
        "expanding advanced information reveals its technical rows")
infoState.expanded = false
pump()
require(abs(infoWindow.contentView!.fittingSize.height - collapsedHeight) < 2,
        "collapsing advanced information restores the compact layout")
infoWindow.orderOut(nil)

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
// Device surfaces use the same transparent borderless window as the task
// panel, with one clipped glass surface and no system sheet frame.
let mainSearchBeforePanels = descendants(window.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "device-search" }!
let searchWasEnabled = mainSearchBeforePanels.isEnabled
let panelToolbarToggle = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "miko.sidebar" }!
let toolbarWasEnabled = panelToolbarToggle.isEnabled
let toolbarButton = panelToolbarToggle.view!
window.contentView!.layoutSubtreeIfNeeded()
let mainWindowFrameBeforePanels = window.frame
let mainContentFrameBeforePanels = window.contentView!.frame
let searchFrameBeforePanels = mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil)
let toolbarFrameBeforePanels = toolbarButton.convert(toolbarButton.bounds, to: nil)
eventually("device overview more button is available") {
    descendants(window.contentView!, NSButton.self).contains { $0.identifier?.rawValue == "miko-device-more:\(model.selected ?? "")" }
}
let overviewMoreButton = descendants(window.contentView!, NSButton.self).first { $0.identifier?.rawValue == "miko-device-more:\(model.selected ?? "")" }!
let overviewMoreFrameBeforePanels = overviewMoreButton.convert(overviewMoreButton.bounds, to: nil)
let mainSplit = descendants(window.contentView!, NSSplitView.self).first { $0.isVertical && $0.arrangedSubviews.count == 2 }!
let mainSplitFrameBeforePanels = mainSplit.convert(mainSplit.bounds, to: nil)
let panelTestLibraryTable = descendants(window.contentView!, NSTableView.self).first { $0.accessibilityIdentifier() == "library-devices" }!
func viewChain(_ source: NSView) -> String {
    var current: NSView? = source
    var values: [String] = []
    while let view = current, values.count < 12 {
        values.append("\(type(of: view)) frame=\(view.frame) safe=\(view.safeAreaInsets) window=\(view.window != nil)")
        current = view.superview
    }
    return values.joined(separator: " | ")
}
let searchChainBeforePanels = viewChain(mainSearchBeforePanels)
func windowChrome(_ window: NSWindow) -> String {
    "toolbar=\(String(describing: window.toolbar?.identifier)) visible=\(String(describing: window.toolbar?.isVisible)) style=\(window.styleMask.rawValue) layout=\(window.contentLayoutRect) key=\(window.isKeyWindow) main=\(window.isMainWindow)"
}
let chromeBeforePanels = windowChrome(window)
let requestLogURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIKO_HOME"]!).appendingPathComponent("requests.jsonl")
func snapshotRequestCount() -> Int {
    guard let contents = try? String(contentsOf: requestLogURL, encoding: .utf8) else { return 0 }
    return contents.split(separator: "\n").filter { line in
        guard let data = String(line).data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return request["method"] as? String == "snapshot.list"
    }.count
}
for sheet: CenterSheet in [.newDevice, .snapshots, .folderSync, .edit, .imageManagement] {
    model.present(sheet)
    eventually("device panel is attached") { model.deviceSheetPanel?.window != nil }
    guard let child = model.deviceSheetPanel?.window else { fatalError("missing device panel") }
    (child as? LightweightPanel)?.reduceMotionOverride = false
    require(child is LightweightPanel && child.parent === window && window.attachedSheet == nil,
            "device panel uses the same native panel as tasks, not a system sheet")
    pump(0.1)
    child.contentView?.layoutSubtreeIfNeeded()
    let panelScrolls = descendants(child.contentView!, NSScrollView.self).filter(\.hasVerticalScroller)
    require(panelScrolls.count == 1 && panelScrolls[0].scrollerStyle == .overlay,
            "\(sheet) uses one native overlay scrollbar")
    if sheet == .edit {
        let scroll = panelScrolls[0]
        let original = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: original.x, y: original.y + 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        require(scroll.contentView.bounds.origin.y != original.y, "the overlay scrollbar still scrolls device settings")
        scroll.contentView.scroll(to: original)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    if app.isActive, let row = panelTestLibraryTable.rowView(atRow: panelTestLibraryTable.selectedRow, makeIfNecessary: false) {
        require(row.isEmphasized, "sidebar selection stays active behind a device panel")
    }
    window.contentView!.layoutSubtreeIfNeeded()
    let searchFrameDuringPanel = mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil)
    let splitFrameDuringPanel = mainSplit.convert(mainSplit.bounds, to: nil)
    require(window.frame == mainWindowFrameBeforePanels && window.contentView!.frame == mainContentFrameBeforePanels,
            "opening \(sheet) preserves the main window and content frames: window \(mainWindowFrameBeforePanels) -> \(window.frame), content \(mainContentFrameBeforePanels) -> \(window.contentView!.frame)")
    require(searchFrameDuringPanel == searchFrameBeforePanels && splitFrameDuringPanel == mainSplitFrameBeforePanels,
            "opening \(sheet) preserves main layout: search \(searchFrameBeforePanels) -> \(searchFrameDuringPanel), split \(mainSplitFrameBeforePanels) -> \(splitFrameDuringPanel)\nBEFORE: \(searchChainBeforePanels)\nAFTER: \(viewChain(mainSearchBeforePanels))\nCHROME: \(chromeBeforePanels) -> \(windowChrome(window))")
    require(mainSearchBeforePanels.isEnabled == searchWasEnabled && panelToolbarToggle.isEnabled == toolbarWasEnabled,
            "opening a device panel does not change the main controls' enabled appearance (search: \(searchWasEnabled) -> \(mainSearchBeforePanels.isEnabled), toolbar: \(toolbarWasEnabled) -> \(panelToolbarToggle.isEnabled))")
    let searchCenter = mainSearchBeforePanels.convert(
        NSPoint(x: mainSearchBeforePanels.bounds.midX, y: mainSearchBeforePanels.bounds.midY), to: nil)
    let oldResponder = window.firstResponder
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        guard let click = NSEvent.mouseEvent(with: type, location: searchCenter, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            fatalError("cannot create background click")
        }
        NSApp.sendEvent(click)
    }
    require(window.firstResponder === oldResponder,
            "a device panel blocks pointer input on the background search field")
    let sidebarBeforeBlockedAction = model.sidebarVisible
    require(NSApp.sendAction(panelToolbarToggle.action!, to: panelToolbarToggle.target, from: panelToolbarToggle),
            "the toolbar routes its action while a panel is open")
    require(model.sidebarVisible == sidebarBeforeBlockedAction,
            "the toolbar ignores input behind an open device panel")
    require(!child.isOpaque && child.backgroundColor.alphaComponent == 0 && child.styleMask.contains(.borderless),
            "device panel has a transparent borderless window")
    require(child.contentView?.layer?.masksToBounds == true && child.contentView?.layer?.cornerRadius == 26,
            "device panel clips content to the glass corner radius")
    guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: child.windowNumber,
                                       context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
        fatalError("cannot create Escape event")
    }
    child.makeKeyAndOrderFront(nil)
    pump(0.1)
    // Drain the manager's own initial request before counting the refresh
    // caused by closing the panel.
    var requestBarrier = false
    model.call("device.list") { _ in requestBarrier = true }
    eventually("panel requests have reached the fixture") { requestBarrier }
    let requestsBeforeClose = snapshotRequestCount()
    let delaySnapshotURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIKO_HOME"]!).appendingPathComponent("slow-snapshot-list")
    if sheet == .snapshots { try Data().write(to: delaySnapshotURL) }
    require(child.delegate?.windowShouldClose?(child) == false,
            "native window closing cannot bypass the form's cancel policy")
    if sheet == .edit {
        guard let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: 0, windowNumber: child.windowNumber, context: nil,
                                               characters: "w", charactersIgnoringModifiers: "w",
                                               isARepeat: false, keyCode: 13) else { fatalError("missing Cmd-W event") }
        NSApp.sendEvent(commandW)
    } else {
        NSApp.sendEvent(escape)
    }
    pump(0.03)
    require(model.sheet == sheet && child.parent === window,
            "modal state and ownership remain active until the exit animation completes")
    let closingResponder = window.firstResponder
    guard let closingClick = NSEvent.mouseEvent(with: .leftMouseDown, location: searchCenter, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 3, clickCount: 1, pressure: 1) else {
        fatalError("cannot create click during dismissal")
    }
    NSApp.sendEvent(closingClick)
    require(window.firstResponder === closingResponder, "background input remains blocked while the panel exits")
    for sample in 0..<45 {
        pump(0.01)
        window.contentView!.layoutSubtreeIfNeeded()
        let searchFrame = mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil)
        let toolbarFrame = toolbarButton.convert(toolbarButton.bounds, to: nil)
        let overviewFrame = overviewMoreButton.convert(overviewMoreButton.bounds, to: nil)
        require(searchFrame == searchFrameBeforePanels && toolbarFrame == toolbarFrameBeforePanels && overviewFrame == overviewMoreFrameBeforePanels,
                "closing \(sheet) moved main content at sample \(sample): search \(searchFrameBeforePanels) -> \(searchFrame), toolbar \(toolbarFrameBeforePanels) -> \(toolbarFrame), overview \(overviewMoreFrameBeforePanels) -> \(overviewFrame); \(windowChrome(window))")
    }
    if sheet == .snapshots {
        eventually("closing snapshot management refreshes the overview") { snapshotRequestCount() == requestsBeforeClose + 1 }
        try? FileManager.default.removeItem(at: delaySnapshotURL)
    } else {
        require(snapshotRequestCount() == requestsBeforeClose,
                "closing an unrelated panel does not reload snapshots")
    }
    eventually("device panel closes with Escape") { model.deviceSheetPanel == nil && model.sheet == nil }
    eventually("dismissed panel is removed from the center window") { child.parent == nil }
    pump(0.2)
    window.contentView!.layoutSubtreeIfNeeded()
    require(window.frame == mainWindowFrameBeforePanels &&
            mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil) == searchFrameBeforePanels,
            "closing a device panel preserves the main window layout")
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        guard let click = NSEvent.mouseEvent(with: type, location: searchCenter, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else {
            fatalError("cannot create restored background click")
        }
        NSApp.sendEvent(click)
    }
    eventually("background search works again after closing the panel") {
        mainSearchBeforePanels.currentEditor() != nil || window.firstResponder === mainSearchBeforePanels
    }
    window.makeFirstResponder(nil)
}
if ProcessInfo.processInfo.environment["MIKO_GLASS_PANEL_TEST_ONLY"] == "1" {
    final class TrackingPanel: LightweightPanel {
        var framesSet: [NSRect] = []
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            framesSet.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }
    }
    let animatedPanel = TrackingPanel(size: NSSize(width: 120, height: 80))
    let restingOrigin = NSPoint(x: 500, y: 500)
    animatedPanel.preparePosition(restingOrigin)
    animatedPanel.reduceMotionOverride = false
    animatedPanel.framesSet.removeAll()
    animatedPanel.showAnimated()
    require(animatedPanel.framesSet.contains { abs($0.origin.y - (restingOrigin.y + 14)) < 0.5 },
            "opening begins above the resting position")
    eventually("panel finishes appearing") {
        animatedPanel.isVisible && animatedPanel.alphaValue > 0.99 && abs(animatedPanel.frame.origin.y - restingOrigin.y) < 0.5
    }
    require(abs(animatedPanel.frame.origin.x - restingOrigin.x) < 0.5, "panel stays horizontally aligned")
    var staleDismissal = false
    animatedPanel.hideAnimated { staleDismissal = true }
    animatedPanel.showAnimated()
    pump(0.5)
    require(animatedPanel.isVisible && animatedPanel.alphaValue > 0.99 && !staleDismissal,
            "reopening prevents an earlier dismissal from hiding the panel")
    let wasKeyBeforeDismissal = animatedPanel.isKeyWindow
    var hiddenAlpha: CGFloat?
    animatedPanel.hideAnimated { hiddenAlpha = animatedPanel.alphaValue }
    require(!wasKeyBeforeDismissal || animatedPanel.isKeyWindow,
            "glass retains its key appearance until it has disappeared")
    eventually("panel finishes disappearing") { !animatedPanel.isVisible && hiddenAlpha != nil }
    require((hiddenAlpha ?? 1) < 0.01 && animatedPanel.alphaValue < 0.01,
            "dismissed window stays transparent rather than resetting to an opaque frame")
    require(animatedPanel.frame.origin.y > restingOrigin.y + 10,
            "closing moves the entire window upward")
    animatedPanel.showAnimated()
    eventually("reopened panel returns to its resting position") {
        animatedPanel.alphaValue > 0.99 && abs(animatedPanel.frame.origin.y - restingOrigin.y) < 0.5
    }
    animatedPanel.hideAnimated(immediately: true)
    animatedPanel.reduceMotionOverride = true
    animatedPanel.showAnimated()
    require(animatedPanel.isVisible && animatedPanel.alphaValue == 1 && abs(animatedPanel.frame.origin.y - restingOrigin.y) < 0.5,
            "reduced motion shows immediately at the resting position")
    animatedPanel.hideAnimated()
    require(!animatedPanel.isVisible, "reduced motion hides immediately")

    model.openTasks()
    eventually("tasks panel appears") { model.taskPanel?.window?.isVisible == true }
    pump(0.1)
    window.contentView!.layoutSubtreeIfNeeded()
    require(window.frame == mainWindowFrameBeforePanels && mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil) == searchFrameBeforePanels,
            "opening the task panel preserves main window layout")
    require(mainSearchBeforePanels.isEnabled == searchWasEnabled,
            "task panel does not change the main search field's enabled appearance")
    model.presentQuitBlocker()
    let outgoingQuitReason = model.quitReason
    require(outgoingQuitReason != nil, "task panel can display a quit blocker")
    model.openPalette()
    require(model.quitReason == outgoingQuitReason, "task content remains unchanged while its window fades out")
    eventually("tasks panel disappears and command panel appears") {
        model.taskPanel?.window?.isVisible == false && model.paletteWindow?.window?.isVisible == true
    }
    window.contentView!.layoutSubtreeIfNeeded()
    require(window.frame == mainWindowFrameBeforePanels && mainSearchBeforePanels.convert(mainSearchBeforePanels.bounds, to: nil) == searchFrameBeforePanels,
            "opening the command panel preserves main window layout")
    require(mainSearchBeforePanels.isEnabled == searchWasEnabled,
            "command panel does not change the main search field's enabled appearance")
    let paletteScrolls = descendants(model.paletteWindow!.window!.contentView!, NSScrollView.self).filter(\.hasVerticalScroller)
    require(!paletteScrolls.isEmpty && paletteScrolls.allSatisfy { $0.scrollerStyle == .overlay },
            "command panel uses the native overlay scrollbar")
    model.paletteQuery = "tasks"
    model.hidePalette()
    model.openPalette()
    require(model.paletteQuery == "tasks", "reopening does not reset the outgoing command content during its fade")
    pump(0.4)
    require(model.paletteOpen && model.paletteWindow?.window?.isVisible == true,
            "rapidly reopening command search keeps it visible")
    require(model.paletteQuery.isEmpty, "the newly presented command panel starts with a clean query")
    guard let newDeviceIndex = model.paletteFiltered.firstIndex(where: { $0.action == .newDevice }) else {
        fatalError("missing new-device command")
    }
    model.paletteSelection = newDeviceIndex
    let fadingPalette = model.paletteWindow!.window!
    model.hidePalette()
    guard let enterDuringClose = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: fadingPalette.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36) else { fatalError("missing Return event") }
    NSApp.sendEvent(enterDuringClose)
    eventually("command panel disappears") { model.paletteWindow?.window?.isVisible == false }
    pump(0.25)
    require(model.sheet == nil, "Return during palette dismissal cannot run a command")

    // Switching must not overlap windows or release modal input early.
    model.openPalette()
    eventually("palette becomes active before switching") { model.paletteOpen && model.paletteWindow?.window?.isVisible == true }
    let previousPalette = model.paletteWindow!.window!
    model.present(.edit)
    require(model.paletteOpen && model.sheet == nil && model.deviceSheetPanel == nil,
            "device settings waits for command search to finish closing")
    eventually("device settings opens after search closes") { model.sheet == .edit && model.deviceSheetPanel?.window?.isVisible == true }
    require(!previousPalette.isVisible && !model.paletteOpen, "old panel is gone before the new panel opens")
    model.openTasks()
    model.openPalette()
    model.present(.newDevice)
    pump(0.3)
    require(model.sheet == .edit && model.deviceSheetPanel?.window?.isVisible == true && !model.tasksOpen && !model.paletteOpen,
            "other panel requests do not discard an open device form")
    let editingPanel = model.deviceSheetPanel!.window!
    model.presentQuitBlocker()
    eventually("quit blocker appears on the device panel") { editingPanel.attachedSheet != nil }
    require(model.sheet == .edit && model.deviceSheetPanel?.window === editingPanel,
            "a blocked quit does not replace the device form")
    if let alert = editingPanel.attachedSheet {
        editingPanel.endSheet(alert)
        alert.orderOut(nil)
    }
    pump(0.2)
    let closingDevice = model.deviceSheetPanel!.window!
    var afterDeviceClose = false
    model.dismissDevicePanel {
        require(!closingDevice.isVisible && closingDevice.parent == nil && model.sheet == nil,
                "follow-up actions run only after the device panel is removed")
        afterDeviceClose = true
    }
    require(model.sheet == .edit && !afterDeviceClose, "device modal state stays active during closing")
    eventually("device panel follow-up runs") { afterDeviceClose }

    model.openPalette()
    eventually("palette opens before SDK setup") { model.paletteOpen && model.paletteWindow?.window?.isVisible == true }
    model.present(.setupSDK)
    require(model.sheet == nil, "SDK setup waits for the outgoing palette")
    eventually("SDK setup opens after palette dismissal") { model.sheet == .setupSDK && window.attachedSheet != nil }
    model.present(.newDevice)
    eventually("new device waits for the native SDK sheet to dismiss") {
        model.sheet == .newDevice && window.attachedSheet == nil && model.deviceSheetPanel?.window?.isVisible == true
    }
    model.dismissDevicePanel()
    eventually("device panel closes after SDK handoff") { model.sheet == nil && model.deviceSheetPanel == nil }
    model.present(.setupSDK)
    eventually("SDK sheet opens again") { model.sheet == .setupSDK && window.attachedSheet != nil }
    model.present(.newDevice)
    model.present(.setupSDK)
    eventually("latest SDK request waits for the previous sheet to close") {
        model.sheet == .setupSDK && window.attachedSheet != nil && model.deviceSheetPanel == nil
    }
    model.dismissSDKSheet()
    eventually("SDK sheet closes after the handoff test") { model.sheet == nil && window.attachedSheet == nil }

    model.openPalette()
    eventually("palette opens before a replaced settings request") { model.paletteOpen && model.paletteWindow?.window?.isVisible == true }
    model.present(.settings)
    model.present(.newDevice)
    eventually("latest request opens the new-device panel") { model.sheet == .newDevice && model.deviceSheetPanel?.window?.isVisible == true }
    require(model.settingsWindow == nil, "a replaced settings request cannot appear over a newer panel")
    model.dismissDevicePanel()
    eventually("new-device panel closes after request replacement") { model.sheet == nil && model.deviceSheetPanel == nil }
    let rightToolbarIDs = window.toolbar!.items.map(\.itemIdentifier.rawValue).filter { $0.hasPrefix("miko.") && $0 != "miko.sidebar" }
    require(rightToolbarIDs == ["miko.images", "miko.palette", "miko.tasks", "miko.refresh"],
            "system images is the first of the four right-side toolbar actions")
    let imagesToolbar = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "miko.images" }!
    let imageRevisionBefore = model.imageInventoryRevision
    require(NSApp.sendAction(imagesToolbar.action!, to: imagesToolbar.target, from: imagesToolbar), "image manager toolbar action is available")
    eventually("image manager opens from the center toolbar") {
        model.sheet == .imageManagement && model.deviceSheetPanel?.window?.parent === window
    }
    require(window.attachedSheet == nil && model.settingsWindow?.window?.isVisible != true,
            "image manager is centered on the main window without a settings sheet")
    model.dismissDevicePanel()
    eventually("image manager closes") { model.sheet == nil }
    require(model.imageInventoryRevision == imageRevisionBefore + 1,
            "closing image management invalidates the retained settings inventory")
    model.present(.settings)
    eventually("glass settings window opens") { model.settingsWindow?.window?.isVisible == true }
    let glassSettings = model.settingsWindow!.window!
    require(!glassSettings.isOpaque && glassSettings.backgroundColor == .clear && glassSettings.titlebarAppearsTransparent &&
            glassSettings.titlebarSeparatorStyle == .none &&
            glassSettings.styleMask.contains(.fullSizeContentView),
            "settings uses glass with a system toolbar backdrop")
    eventually("settings system glass is installed") {
        descendants(glassSettings.contentView!, NSView.self).contains { $0.accessibilityIdentifier() == "settings-glass" }
    }
    let settingsGlass = descendants(glassSettings.contentView!, NSView.self).first { $0.accessibilityIdentifier() == "settings-glass" }!
    let glassRect = settingsGlass.convert(settingsGlass.bounds, to: glassSettings.contentView!)
    require(glassRect.insetBy(dx: -1, dy: -1).contains(glassSettings.contentView!.bounds),
            "settings glass covers the content and toolbar area")
    if #available(macOS 26.0, *) { require(settingsGlass is NSGlassEffectView, "settings uses native Liquid Glass") }
    else { require(settingsGlass is NSVisualEffectView && (settingsGlass as? NSVisualEffectView)?.blendingMode == .behindWindow,
                   "older macOS uses a behind-window system material") }
    require(!descendants(glassSettings.contentView!, NSView.self).contains { $0.accessibilityIdentifier() == "settings-toolbar-blur" },
            "settings does not add a custom background filter over the native toolbar")
    for category in 0..<6 {
        model.settingsCategory = category
        pump(0.1)
        require(settingsGlass.window === glassSettings && glassSettings.toolbar?.selectedItemIdentifier?.rawValue == "miko.preferences.\(category)",
                "settings retains its glass and native category toolbar when switching panes")
        let settingsScrolls = descendants(glassSettings.contentView!, NSScrollView.self).filter(\.hasVerticalScroller)
        require(!settingsScrolls.isEmpty && settingsScrolls.allSatisfy { $0.scrollerStyle == .overlay },
                "settings panes use native overlay scrollbars")
        let scrollBounds = settingsScrolls[0].convert(settingsScrolls[0].bounds, to: nil)
        require(scrollBounds.maxY <= glassSettings.contentLayoutRect.maxY + 1,
                "settings scroll content stays below the toolbar")
        if category == 2 {
            require(!descendants(glassSettings.contentView!, NSButton.self).contains { $0.title == "Manage system images…" || $0.title == "管理系统镜像…" },
                    "image management no longer appears inside settings")
        }
    }
    model.settingsCategory = 1
    eventually("settings policy editor loads") {
        descendants(glassSettings.contentView!, NSTextField.self).contains { $0.isEditable && $0.stringValue == "80" }
    }
    let budgetField = descendants(glassSettings.contentView!, NSTextField.self).first { $0.isEditable && $0.stringValue == "80" }!
    glassSettings.makeKeyAndOrderFront(nil)
    glassSettings.makeFirstResponder(budgetField)
    guard let budgetEditor = budgetField.currentEditor() as? NSTextView else { fatalError("missing settings field editor") }
    budgetEditor.selectAll(nil)
    budgetEditor.insertText("75", replacementRange: budgetEditor.selectedRange())
    pump(0.1)
    window.makeKeyAndOrderFront(nil)
    require(NSApp.sendAction(imagesToolbar.action!, to: imagesToolbar.target, from: imagesToolbar), "image manager can open while settings is retained")
    eventually("image manager opens alongside retained settings") { model.sheet == .imageManagement }
    model.dismissDevicePanel()
    eventually("image manager finishes closing") { model.sheet == nil }
    pump(0.2)
    require(budgetField.stringValue == "75", "refreshing image inventory preserves unsaved settings edits")
    model.settingsWindow?.close()
    print("Device panel and animation tests passed")
    model.close()
    window.close()
    exit(0)
}
require(window.toolbar != nil, "center has a real native toolbar")
require(window.styleMask.contains(.fullSizeContentView), "content extends into the title-bar area")
require(window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none, "native toolbar blends with content without a separator")
require(window.titleVisibility == .hidden, "window title does not duplicate the content heading")
let centerToolbarIDs = window.toolbar!.items.map(\.itemIdentifier.rawValue)
func trafficLightFrames(_ window: NSWindow) -> [NSRect] {
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
        guard let button = window.standardWindowButton($0) else { return nil }
        let frame = button.convert(button.bounds, to: nil)
        // The window is resized between captures; compare against its top edge.
        return NSRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }
}
let centerTrafficLights = trafficLightFrames(window)
require(centerTrafficLights.count == 3, "device center traffic lights are available")
require(centerToolbarIDs.contains("miko.palette") && centerToolbarIDs.contains("miko.tasks") && centerToolbarIDs.contains("miko.refresh"),
        "library toolbar exposes commands, tasks and refresh")
require(centerToolbarIDs.first == "miko.sidebar", "the native toolbar starts with the sidebar toggle")
let sidebarToggle = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "miko.sidebar" }!
require((sidebarToggle.view as? NSButton)?.isBordered == false, "sidebar toggle uses a borderless native button")
require(NSApp.sendAction(sidebarToggle.action!, to: sidebarToggle.target, from: sidebarToggle), "sidebar toggle is actionable")
eventually("the sidebar can be collapsed") {
    !model.sidebarVisible && descendants(window.contentView!, NSSearchField.self)
        .filter { $0.identifier?.rawValue == "device-search" }.allSatisfy { $0.isHiddenOrHasHiddenAncestor || $0.visibleRect.isEmpty }
}
// Let the system split-view transition settle before sending the next toggle.
pump(0.35)
require(NSApp.sendAction(sidebarToggle.action!, to: sidebarToggle.target, from: sidebarToggle), "sidebar can be reopened")
eventually("the sidebar is visible after reopening") { model.sidebarVisible }
let sidebarSearch = descendants(window.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "device-search" }!
require(sidebarSearch.placeholderString == "Search devices", "native sidebar search describes devices")
require(sidebarSearch.isBezeled && sidebarSearch.bezelStyle == .roundedBezel,
        "sidebar search preserves the native rounded search geometry")
if #available(macOS 26.0, *) {
    require(!sidebarSearch.drawsBackground && descendants(window.contentView!, NSGlassEffectView.self)
        .contains { descendants($0, NSSearchField.self).contains { $0 === sidebarSearch } },
            "sidebar search exposes the native translucent glass background")

}

require(descendants(window.contentView!, NSSplitView.self).contains { $0.isVertical && $0.arrangedSubviews.count == 2 },
        "device center uses the system navigation split")

// Native sidebar selection loads the corresponding overview; clearing it
// must also invalidate in-flight detail and app-list replies.
let originalID = model.selected!
eventually("device sidebar is attached") { !descendants(window.contentView!, NSTableView.self).isEmpty }
let libraryTable = descendants(window.contentView!, NSTableView.self).first { $0.accessibilityIdentifier() == "library-devices" }!
require(libraryTable.style == .sourceList, "device navigation uses native source-list selection")
require(!libraryTable.delegate!.tableView!(libraryTable, shouldSelectRow: 1), "the device section heading is not selectable")
libraryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
eventually("all-devices entry opens the library") { model.showingAllDevices && model.selected == nil }
model.refresh()
var allDevicesCheckpoint = false
model.call("device.list") { _ in allDevicesCheckpoint = true }
eventually("refresh preserves the library selection") { allDevicesCheckpoint && model.showingAllDevices && model.selected == nil }
libraryTable.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
eventually("sidebar selection loads the corresponding overview") { !model.showingAllDevices && model.details?.device.id == model.devices[1].id }
model.select(originalID)
eventually("original overview is restored") { model.details?.device.id == originalID }
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

// The overview's app search filters locally without changing device selection.
eventually("overview apps finish loading") { !model.appsLoading && !model.apps.isEmpty }
let overviewSearch = descendants(window.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "overview-app-search" }!
require(overviewSearch.isEnabled, "running-device overview allows app search")
window.makeFirstResponder(overviewSearch)
pump()
let overviewEditor = overviewSearch.currentEditor() as! NSTextView
overviewEditor.selectAll(nil)
overviewEditor.insertText("com.example.test", replacementRange: NSRange(location: NSNotFound, length: 0))
pump()
require(model.selected == originalID && model.deviceQuery.isEmpty && model.apps.count == 2,
        "overview app filtering leaves the selected device and source app list intact")
model.notice = "Overview search rerender"
pump()
require(overviewSearch.stringValue == "com.example.test", "overview search survives unrelated model updates")
(overviewSearch.cell as! NSSearchFieldCell).cancelButtonCell!.performClick(overviewSearch)
pump()
require(overviewSearch.stringValue.isEmpty, "overview app search clears with the native cancel button")
model.notice = ""
model.select(stoppedDevice.id)
eventually("stopped overview is selected") { model.details?.device.id == stoppedDevice.id }
pump()
let stoppedAppSearch = descendants(window.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "overview-app-search" }!
require(!stoppedAppSearch.isEnabled && model.apps.isEmpty, "stopped devices do not expose stale launchable apps")
model.select(originalID)
eventually("running overview is restored") { model.details?.device.id == originalID && !model.appsLoading }

// Failures and unanswered reads leave a recoverable state, never a spinner.
let testHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIKO_HOME"]!)
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

let background = sidebarSearch
model.searchFocusRequest += 1
pump()
require(window.firstResponder === background.currentEditor(), "device search receives requested focus")
if #available(macOS 26.0, *) {
    require(background.focusRingType == .exterior && background.stringValue.isEmpty,
            "empty focused search uses AppKit's exterior focus ring without waiting for typing")
    let container = descendants(window.contentView!, NativeSearchContainer.self).first!
    let editor = background.currentEditor() as! NSTextView
    let textRect = container.convert(background.searchTextBounds, from: background)
    let caretScreen = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    let caretRect = container.convert(window.convertFromScreen(caretScreen), from: nil)
    require(caretRect.minX >= textRect.minX - 2 && caretRect.minX < textRect.maxX,
            "the native insertion point stays inside the search text area: \(caretRect), \(textRect)")
    require(type(of: background) == NSSearchField.self,
            "focus rendering stays with AppKit's standard search control")
    editor.insertText("layout regression", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump()
    require(model.deviceQuery == "layout regression", "native search typing still updates the device filter")
    let searchCell = background.cell as! NSSearchFieldCell
    searchCell.cancelButtonCell!.performClick(background)
    pump()
    require(model.deviceQuery.isEmpty && background.stringValue.isEmpty,
            "the native cancel button clears the field and device filter")
    model.select(originalID)
    eventually("restore the selected device after native search regression") { model.details?.device.id == originalID }
}


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
let palette = descendants(panel.contentView!, NSTextField.self).first { $0.identifier?.rawValue == "palette-search" }!
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
eventually("Escape closes only the palette") { !model.paletteOpen && model.deviceQuery.isEmpty }
model.present(.settings)
require(model.settingsWindow === settings && model.settingsCategory == 2, "reopening preserves the same settings window and pane")
pump()
require(settings.window?.title.contains("Data & tools") == true, "native title reflects the selected pane")
require(settings.window?.toolbar?.items.count == 6, "settings has six native toolbar categories")
require(settings.window?.toolbar?.selectedItemIdentifier?.rawValue == "miko.preferences.2", "toolbar selection follows the retained pane")
require(!settings.window!.styleMask.contains(.miniaturizable) && !settings.window!.styleMask.contains(.resizable),
        "preferences do not offer minimize, zoom or full-screen controls")
let dataHeight = settings.window!.contentLayoutRect.height
model.settingsCategory = 0
pump()
require(settings.window!.contentLayoutRect.height < dataHeight, "preferences adapt height to the selected pane")

// Editable preferences must remain recognizable as controls in grouped forms.
for (category, expectedFields) in [(1, 2), (3, 1), (4, 1)] {
    model.settingsCategory = category
    pump()
    let fields = descendants(settings.window!.contentView!, NSTextField.self).filter { $0.isEditable }
    require(fields.count >= expectedFields, "numeric and path preferences expose editable native fields")
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
// Logcat filtering shares the native search surface and preserves its draft.
tools.selection.section = 3
pump()
let logSearch = descendants(tools.window!.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "logcat-search" }!
require(logSearch.isBezeled && logSearch.focusRingType == .exterior, "Logcat uses the same native search and exterior focus ring")
tools.window!.makeFirstResponder(logSearch)
(logSearch.currentEditor() as! NSTextView).insertText("ActivityManager:I", replacementRange: NSRange(location: NSNotFound, length: 0))
pump()
tools.selection.section = 0
pump()
tools.selection.section = 3
pump()
let restoredLogSearch = descendants(tools.window!.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "logcat-search" }!
require(restoredLogSearch.stringValue == "ActivityManager:I", "Logcat filter text survives native view updates and section changes")
tools.window!.makeFirstResponder(restoredLogSearch)
(restoredLogSearch.cell as! NSSearchFieldCell).cancelButtonCell!.performClick(restoredLogSearch)
pump()
require(restoredLogSearch.stringValue.isEmpty, "Logcat uses the native clear control")

// Recordings search binds to its own view state without a connected device.
let recordingsTransport = PlayerTransport()
recordingsTransport.language = 0
let recordingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
recordingsWindow.isReleasedWhenClosed = false
recordingsWindow.contentView = NSHostingView(rootView: PlayerScriptsView(transport: recordingsTransport))
recordingsWindow.makeKeyAndOrderFront(nil)
pump()
let recordingsSearch = descendants(recordingsWindow.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "recordings-search" }!
require(recordingsSearch.focusRingType == .exterior && recordingsSearch.isBezeled,
        "recordings uses the shared native search appearance")
recordingsWindow.makeFirstResponder(recordingsSearch)
(recordingsSearch.currentEditor() as! NSTextView).insertText("recording query", replacementRange: NSRange(location: NSNotFound, length: 0))
pump()
recordingsTransport.language = 1
pump()
require(recordingsSearch.stringValue == "recording query", "recordings query remains bound across parent view updates")
(recordingsSearch.cell as! NSSearchFieldCell).cancelButtonCell!.performClick(recordingsSearch)
pump()
recordingsTransport.language = 0
pump()
require(recordingsSearch.stringValue.isEmpty, "clearing recordings search also clears the bound query")
recordingsWindow.orderOut(nil)

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
tools.present(relativeTo: window, section: 8)
require(tools.selection.section == 8 && tools.window!.frame == userToolsFrame,
        "camera settings link selects Cameras in the reused panel without resizing it")
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
eventually("clicking outside dismisses the task panel") { !model.tasksOpen && taskOwner.window?.isVisible == false }
model.openTasks()
window.makeKeyAndOrderFront(nil)
model.openPalette()
eventually("only one lightweight panel is displayed at a time") {
    !model.tasksOpen && taskOwner.window?.isVisible == false && model.paletteWindow?.window?.isVisible == true
}
require(taskOwner.window?.styleMask == model.paletteWindow?.window?.styleMask, "search and tasks share native frame styling")
require(taskOwner.window?.hasShadow == true && model.paletteWindow?.window?.hasShadow == true, "both panels use one native shadow")
let reusedPanel = model.paletteWindow!.window!
let reusedField = descendants(reusedPanel.contentView!, NSTextField.self).first { $0.identifier?.rawValue == "palette-search" }!
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
    require(!submenu!.items.contains { $0.title.contains("Details") }, "menu bar omits the removed device-details entry")
    require(submenu!.items.contains { $0.title == "Edit Device…" }, "menu bar retains device settings")
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
eventually("Escape dismisses the active lightweight panel") { !model.paletteOpen && !model.tasksOpen }
model.present(.edit)
eventually("device panel opens for menu isolation") { model.sheet == .edit && model.deviceSheetPanel?.window?.isVisible == true }
app.activate(ignoringOtherApps: true)
model.deviceSheetPanel?.window?.makeKeyAndOrderFront(nil)
pump(0.1)
menu.menuNeedsUpdate(deviceMenu)
guard let deviceCommand = deviceMenu.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.action != nil }) else {
    fatalError("missing explicit device menu command")
}
require(!menu.validateMenuItem(deviceCommand), "device menu actions are blocked while a center panel is active")
model.dismissDevicePanel()
eventually("device panel closes after menu isolation") { model.sheet == nil }
taskOwner.close()
pump()
require(!model.tasksOpen, "panel dismissal synchronizes the task state")
model.openTasks()
require(model.taskPanel === taskOwner, "task window reuses one instance")
model.taskPanel?.close()
model.openPalette()
pump()
NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
eventually("application deactivation clears the transient search state") {
    !model.paletteOpen && model.paletteWindow?.window?.isVisible == false
}

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
require(splits.contains { $0.isVertical && $0.arrangedSubviews.count == 2 }, "minimum window retains a resizable sidebar and scrolling overview")
require(!descendants(window.contentView!, NSTableView.self).isEmpty, "native sidebar remains visible at minimum size")
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
// Capture the real hosted onboarding before and after feedback. The positive
// checkmark must be rendered inside the window, even at the minimum size.
model.dismissToast()
model.notice = ""
pump(0.3)
func greenPixelCount(_ view: NSView) -> Int {
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.greenComponent > 0.35 && c.greenComponent > c.redComponent * 1.3 && c.greenComponent > c.blueComponent * 1.15 { count += 1 }
        }
    }
    return count
}
let greenBeforeToast = greenPixelCount(window.contentView!)
model.showToast("SDK installation cancelled")
pump(0.3)
require(greenPixelCount(window.contentView!) > greenBeforeToast + 8,
        "the cancellation toast is visible within the onboarding window")
model.dismissToast()
if #available(macOS 15.0, *) {
    let onboardingTrafficLights = trafficLightFrames(window)
    require(onboardingTrafficLights.count == 3 && zip(centerTrafficLights, onboardingTrafficLights).allSatisfy {
        abs($0.0.minX - $0.1.minX) < 0.5 && abs($0.0.midY - $0.1.midY) < 0.5
    }, "onboarding and device center traffic lights have matching positions")
}
require(!descendants(window.contentView!, NSSplitView.self).contains { $0.delegate is NSSplitViewController },
        "an empty library has no navigation sidebar")
if #available(macOS 15.0, *) {
    require(window.toolbar!.items.filter { $0.itemIdentifier != .flexibleSpace }.allSatisfy(\.isHidden), "empty onboarding hides toolbar actions")
} else { require(window.toolbar!.isVisible && window.toolbar!.items.isEmpty, "empty onboarding uses an empty toolbar") }
require(!descendants(window.contentView!, NSSearchField.self).contains { $0.identifier?.rawValue == "device-search" },
        "empty onboarding removes device search")
model.searchFocusRequest += 1
pump()
require(window.firstResponder !== background.currentEditor() || background.currentEditor() == nil,
        "search shortcuts never focus a field removed from the toolbar")
// A new device restores the workspace and its toolbar; filtering a nonempty
// library down to zero results must keep that workspace rather than onboarding.
model.devices = originalDevices
pump()
require(!model.isEmptyDeviceLibrary, "adding a device leaves onboarding")
let restoredSearch = descendants(window.contentView!, NSSearchField.self).first { $0.identifier?.rawValue == "device-search" }
require(restoredSearch?.isEnabled == true, "sidebar search is enabled when devices exist")
require(window.toolbar!.isVisible && window.toolbar!.items.map(\.itemIdentifier.rawValue) == centerToolbarIDs, "the toolbar returns with devices")
require(!descendants(window.contentView!, NSTableView.self).isEmpty,
        "the device list returns when devices exist")
model.deviceQuery = "no-matching-device-name"
pump()
require(!model.isEmptyDeviceLibrary && restoredSearch?.isEnabled == true, "zero search results retain usable search and the workspace")
model.devices = []
pump()
require(model.isEmptyDeviceLibrary && model.deviceQuery.isEmpty, "the empty-library transition clears filters")
if #available(macOS 15.0, *) {
    require(window.toolbar!.items.filter { $0.itemIdentifier != .flexibleSpace }.allSatisfy(\.isHidden), "onboarding hides toolbar actions again")
} else { require(window.toolbar!.isVisible && window.toolbar!.items.isEmpty, "onboarding restores the empty toolbar") }
tools.close()
window.orderOut(nil)
model.close()
print("Center UI regressions passed: palette focus/input/Escape, native toolbar/preferences, native list selection/stale replies, unified title bar, task/search panels, menu routing, appearance, minimum-size list")
