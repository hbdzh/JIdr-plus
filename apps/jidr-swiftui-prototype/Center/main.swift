// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: CenterModel?
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count == 4, ProcessInfo.processInfo.environment["JIDR_HOME"]?.isEmpty == false else { fputs("usage: JIDR_HOME=<isolated-home> Center CENTER_BRIDGE GAME_APP PLAYER_BRIDGE\n",stderr); NSApp.terminate(nil); return }
        do {
            let model = try CenterModel(center:args[1],game:args[2],bridge:args[3]); self.model = model
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            // Keep the native resize limit consistent with CenterView's minimum layout.
            window.contentMinSize = NSSize(width:800,height:550)
            window.title = "Jidr SwiftUI 设备中心预览"; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true; window.delegate = self
            window.contentView = NSHostingView(rootView:CenterView(model:model)); self.window = window
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        } catch { fputs("\(error)\n",stderr); NSApp.terminate(nil) }
    }
    private var shuttingDown = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.hasExternalPlayer else { model.notice = model.text("请先关闭独立运行的旧版测试窗口。", "Close the standalone test window first."); return .terminateCancel }
        guard !model.hasActiveRecording && model.recording.isEmpty else { model.notice = model.text("请先停止录屏并等待保存完成。", "Stop recording and wait for it to be saved first."); return .terminateCancel }
        guard !shuttingDown else { return .terminateLater }
        guard model.busy.isEmpty && !model.hasMutations else { model.notice = model.text("请等待当前操作完成后再退出。", "Wait for the current operation to finish before quitting."); return .terminateCancel }
        model.closePlayers()
        guard !model.hasPlayers else { model.notice = model.text("请先关闭游戏窗口。", "Close the game window first."); return .terminateCancel }
        shuttingDown = true
        model.notice = model.text("正在安全停止设备并退出…", "Stopping devices safely and quitting…")
        model.call("center.quit") { [weak self] result in
            guard let self else { return }
            self.shuttingDown = false
            switch result {
            case .success: NSApp.reply(toApplicationShouldTerminate:true)
            case .failure(let error): model.notice = model.text("无法安全退出：", "Unable to quit safely: ") + error.localizedDescription; NSApp.reply(toApplicationShouldTerminate:false)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationWillTerminate(_ notification:Notification) { model?.close() }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
