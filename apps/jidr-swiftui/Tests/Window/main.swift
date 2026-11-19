// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI

// Exercise the same owner-release pattern as the device center. This test
// requires a macOS GUI session, but does not contact an emulator or daemon.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var player: GameWindowController? = GameWindowController()
var closeCount = 0
player?.onClose = {
    closeCount += 1
    player = nil
}
player?.open(device:"test-device",width:720,height:1280,executable:"/usr/bin/false",displayName:"Test device")
precondition(player?.window?.title == "Test device — miko simulator")
precondition(player?.window?.isReleasedWhenClosed == false)
player?.window?.performClose(nil)
precondition(closeCount == 1 && player == nil)
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
let root = FileManager.default.temporaryDirectory.appendingPathComponent("jidr-window-ui-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let id = UUID().uuidString.lowercased()
let screen = NSScreen.main!.visibleFrame
let store = try GameWindowStateStore(dataDirectory:root.path,device:id)
_ = try store.load()
let state = GameWindowState(x:screen.minX + 100,y:screen.minY + 100,width:420,height:700,sidebar:false,onTop:true,landscape:false)
try store.save(state)
let restored = GameWindowController()
restored.open(device:id,width:720,height:1280,executable:"/usr/bin/false",dataDirectory:root.path)
precondition(restored.window?.level == .floating)
precondition(restored.chrome.pinned)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
func findScreen(_ view: NSView) -> ScreenView? {
    if let screen = view as? ScreenView { return screen }
    return view.subviews.lazy.compactMap { findScreen($0) }.first
}
let restoredScreen = findScreen(restored.window!.contentView!)!
precondition(abs(restoredScreen.bounds.width / restoredScreen.bounds.height - 720.0 / 1280.0) < 0.002,
             "restored player viewport must match device aspect")
let accessories = restored.window!.titlebarAccessoryViewControllers
let traffic = restored.window!.standardWindowButton(.closeButton)!
let trafficCenter = traffic.convert(NSPoint(x: traffic.bounds.midX, y: traffic.bounds.midY), to: nil).y
for accessory in accessories {
    let view = accessory.view
    let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil).y
    precondition(abs(center - trafficCenter) < 1, "titlebar controls share a centered native baseline")
}
precondition(accessories.count >= 2 && !accessories[1].isHidden)
precondition(abs(restored.window!.frame.height - restored.window!.contentLayoutRect.height + restored.titlebarInset - WbLayout.windowDeviceToolbarWidth) < 1)
let title = restored.window!.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "jidr.player.title" }!
let titleFrame = title.convert(title.bounds, to: nil)
precondition(abs(titleFrame.midY - trafficCenter) < 1, "window title shares the traffic lights' vertical center")
precondition(titleFrame.maxX <= accessories.map { $0.view.convert($0.view.bounds, to: nil).minX }.min()!, "window title never overlaps actions")
precondition(title.lineBreakMode == .byTruncatingTail, "long device names are truncated")
precondition(NSImage(systemSymbolName: "hand.tap", accessibilityDescription: nil) != nil)
restored.toggleSidebarFromMenu()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(!accessories[1].isHidden)
precondition(abs(restoredScreen.bounds.width / restoredScreen.bounds.height - 720.0 / 1280.0) < 0.002,
             "player viewport keeps its aspect with the sidebar visible")
precondition(abs(restored.window!.contentLayoutRect.width - restoredScreen.bounds.width - WbLayout.windowDeviceToolbarWidth) < 1,
             "sidebar uses the configured width")
restored.toggleSidebarFromMenu()
precondition(!accessories[1].isHidden)
restored.transport.mapping.load(path: root.appendingPathComponent("keymap-fixture.json").path)
precondition(restored.transport.mapping.begin())
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
restored.transport.mapping.cancel()
restored.chrome.togglePinAction?()
precondition(restored.window?.level == .normal && !restored.chrome.pinned)
restored.chrome.togglePinAction?()
precondition(restored.window?.level == .floating && restored.chrome.pinned)
precondition(abs((restored.window?.frame.minX ?? 0) - state.x) < 1)
precondition(abs((restored.window?.frame.minY ?? 0) - state.y) < 1)
restored.window?.performClose(nil)
let readBack = try GameWindowStateStore(dataDirectory:root.path,device:id).load()
precondition(readBack?.sidebar == false && readBack?.onTop == true)

let landscapeID = UUID().uuidString.lowercased()
let landscapeStore = try GameWindowStateStore(dataDirectory:root.path,device:landscapeID)
_ = try landscapeStore.load()
try landscapeStore.save(GameWindowState(x:screen.minX + 100,y:screen.minY + 100,width:700,height:420,sidebar:true,onTop:false,landscape:true))
let rotated = GameWindowController()
rotated.open(device:landscapeID,width:720,height:1280,executable:"/usr/bin/false",dataDirectory:root.path)
precondition((rotated.window?.frame.height ?? 0) > (rotated.window?.frame.width ?? 0))
rotated.window?.performClose(nil)
let pixel = GameWindowController()
pixel.open(device:"pixel-test",width:480,height:640,executable:"/usr/bin/false")
pixel.transport.onFrameSize?(480,640)
pixel.transport.onPixelPerfect?()
let pixelScale = pixel.window?.backingScaleFactor ?? 1
let content = pixel.window?.contentLayoutRect.size ?? .zero
precondition(abs((content.width - WbLayout.windowDeviceToolbarWidth) * pixelScale - 480) < 1)
precondition(abs((content.height - pixel.titlebarInset) * pixelScale - 640) < 1)
var pixelError = ""
pixel.transport.onStatus = { pixelError = $0 }
pixel.transport.onFrameSize?(16000,16000)
pixel.transport.onPixelPerfect?()
precondition(pixelError.contains("超出"))
pixel.window?.performClose(nil)
let offscreenID = UUID().uuidString.lowercased()
let offscreenStore = try GameWindowStateStore(dataDirectory:root.path,device:offscreenID)
_ = try offscreenStore.load()
try offscreenStore.save(GameWindowState(x:90000,y:90000,width:420,height:700,sidebar:true,onTop:false,landscape:false))
let moved = GameWindowController()
moved.open(device:offscreenID,width:720,height:1280,executable:"/usr/bin/false",dataDirectory:root.path)
precondition(moved.window.map { screen.intersects($0.frame) } == true)
moved.window?.performClose(nil)
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
let toolsModel = try CenterModel(center:"/usr/bin/false", bridge:"/usr/bin/false")
let toolController = DeviceToolsPanelController(model:toolsModel, id:"test-device", name:"Test", root:false)
toolController.present(relativeTo:nil)
RunLoop.main.run(until:Date().addingTimeInterval(0.8))
func findToolTable(_ view: NSView) -> CompactDeviceToolsTableView? {
    if let table = view as? CompactDeviceToolsTableView { return table }
    return view.subviews.lazy.compactMap { findToolTable($0) }.first
}
// The palette editor must not recreate NSSearchField's bezel/focus ring or
// overlap its separately laid-out magnifying glass with the text editor.
struct PaletteSearchFixtureView: View {
    @ObservedObject var fixture: PaletteSearchFixture
    var body: some View {
        PaletteSearchField(text: $fixture.value, placeholder: "Search commands")
            .frame(width: 300, height: 32)
    }
}
final class PaletteSearchFixture: ObservableObject { @Published var value = "" }
let paletteSearchFixture = PaletteSearchFixture()
let paletteHost = NSHostingView(rootView: PaletteSearchFixtureView(fixture: paletteSearchFixture))
let paletteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
paletteWindow.isReleasedWhenClosed = false
paletteWindow.contentView = paletteHost
paletteWindow.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
func findPaletteField(_ view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.identifier?.rawValue == "palette-search" { return field }
    return view.subviews.lazy.compactMap { findPaletteField($0) }.first
}
let paletteField = findPaletteField(paletteHost)!
precondition(!(paletteField is NSSearchField) && !paletteField.isBezeled && !paletteField.drawsBackground && paletteField.focusRingType == .none,
             "palette editor is borderless and leaves its symbol outside the editable area")
paletteWindow.makeFirstResponder(paletteField)
(paletteField.currentEditor() as! NSTextView).insertText("device", replacementRange: NSRange(location: NSNotFound, length: 0))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(paletteSearchFixture.value == "device", "palette editor updates the query")
paletteWindow.close()
print("Palette search editor regression passed")


let toolsWindow = toolController.window!
precondition(toolsWindow.styleMask.contains(.titled) && toolsWindow.styleMask.contains(.fullSizeContentView)
             && toolsWindow.styleMask.contains(.resizable), "device tools retains its native resizable window frame")
precondition(toolsWindow.isOpaque && toolsWindow.isMovableByWindowBackground,
             "device tools uses its native surface and can be dragged from its background")
for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
    precondition(toolsWindow.standardWindowButton(kind)?.isHidden == true, "device tools keeps its traffic lights hidden")
}
let table = findToolTable(toolsWindow.contentView!)!
let tableRect = table.enclosingScrollView!.convert(table.enclosingScrollView!.bounds, to: nil)
precondition(toolsWindow.frame.height - tableRect.maxY < 76,
             "device tools sidebar starts below its compact header, without reserved titlebar space")
precondition(toolController.window?.toolbar?.isVisible == false,
             "device tools hides the system toolbar and its sidebar toggle")
toolController.selection.section = 1
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
precondition(toolController.window?.toolbar?.isVisible == false,
             "the system toolbar stays hidden after changing tools")
toolController.close()

// The same native search control backs every search and filter entry.
final class SearchFixture: ObservableObject { @Published var value = "" }
struct SearchFixtureView: View {
    @ObservedObject var fixture: SearchFixture
    var body: some View {
        NativeSearchField(text: $fixture.value, placeholder: "Search", identifier: "search-fixture")
            .frame(width: 220, height: 30)
    }
}
let searchFixture = SearchFixture()
let searchHost = NSHostingView(rootView: SearchFixtureView(fixture: searchFixture))
let searchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
searchWindow.isReleasedWhenClosed = false
searchWindow.contentView = searchHost
searchWindow.makeKeyAndOrderFront(nil)
RunLoop.main.run(until:Date().addingTimeInterval(0.2))
func findSearchContainer(_ view: NSView) -> NativeSearchContainer? {
    if let container = view as? NativeSearchContainer { return container }
    return view.subviews.lazy.compactMap { findSearchContainer($0) }.first
}
let searchContainer = findSearchContainer(searchHost)!
let searchField = searchContainer.field
precondition(searchField.isBezeled && searchField.bezelStyle == .roundedBezel && searchField.focusRingType == .exterior)
if #available(macOS 26.0, *) {
    precondition(!searchField.drawsBackground && searchContainer.subviews.contains { $0 is NSGlassEffectView },
                 "all shared search fields use the device sidebar glass")
} else {
    precondition(searchField.drawsBackground, "older macOS keeps the native search background")
}
searchWindow.makeFirstResponder(searchField)
(searchField.currentEditor() as! NSTextView).insertText("fixture query", replacementRange: NSRange(location: NSNotFound, length: 0))
RunLoop.main.run(until:Date().addingTimeInterval(0.1))
precondition(searchFixture.value == "fixture query", "typing updates the search binding")
(searchField.cell as! NSSearchFieldCell).cancelButtonCell!.performClick(searchField)
RunLoop.main.run(until:Date().addingTimeInterval(0.1))
precondition(searchFixture.value.isEmpty, "the native clear button clears the search binding")
searchWindow.close()


let confirmedStop = ["one": "stopping", "two": "stopped"]
precondition(CenterModel.canLeaveStopsRunning(stopping: ["one"], deviceStates: confirmedStop,
                                             mutationMethods: ["device.stop"], mutationCount: 1, hasOtherWork: false))
// A relaunched client has no local mutation, but the daemon still owns the stop.
precondition(CenterModel.canLeaveStopsRunning(stopping: [], deviceStates: confirmedStop,
                                             mutationMethods: [], mutationCount: 0, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: [], deviceStates: ["one": "stopped"],
                                              mutationMethods: [], mutationCount: 0, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: [], deviceStates: ["one": "stopping", "two": "running"],
                                              mutationMethods: [], mutationCount: 0, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: [], deviceStates: confirmedStop,
                                              mutationMethods: [], mutationCount: 0, hasOtherWork: true))
precondition(!CenterModel.canLeaveStopsRunning(stopping: ["one"], deviceStates: ["one": "running"],
                                              mutationMethods: ["device.stop"], mutationCount: 1, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: ["one"], deviceStates: ["one": "stopping", "two": "running"],
                                              mutationMethods: ["device.stop"], mutationCount: 1, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: ["one"], deviceStates: confirmedStop,
                                              mutationMethods: ["device.stop", "device.edit"], mutationCount: 2, hasOtherWork: false))
precondition(!CenterModel.canLeaveStopsRunning(stopping: ["one"], deviceStates: confirmedStop,
                                              mutationMethods: ["device.stop"], mutationCount: 1, hasOtherWork: true))

print("Game window lifecycle test passed")
