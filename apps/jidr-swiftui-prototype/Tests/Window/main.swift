// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

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
precondition(player?.window?.title == "Test device — Jidr")
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
precondition(abs((content.width - 48) * pixelScale - 480) < 1)
precondition(abs(content.height * pixelScale - 640) < 1)
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
print("Game window lifecycle test passed")
