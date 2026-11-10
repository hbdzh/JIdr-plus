// SPDX-License-Identifier: GPL-3.0-only
import AppKit
final class PlayerDelegate: NSObject, NSApplicationDelegate {
    let game = GameWindowController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count == 5, let width = Int(args[2]), let height = Int(args[3]), width > 0, height > 0 else {
            fputs("usage: JidrSwiftUIPrototype DEVICE WIDTH HEIGHT BRIDGE_PATH\n",stderr); NSApp.terminate(nil); return
        }
        game.open(device:args[1],width:width,height:height,executable:args[4])
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard game.transport.recording == .idle else { game.transport.onStatus?("请先停止录屏并等待保存完成"); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { game.transport.stop() }
}
let app = NSApplication.shared
let delegate = PlayerDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
