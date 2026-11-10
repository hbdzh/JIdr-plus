// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: CenterModel?
    var window: NSWindow?
    /// The Rust helpers shipped in a packaged app: this executable's `Contents/Helpers`.
    /// Returns nil when that layout is incomplete, so the caller prints the usage line.
    private static func helpersInBundle() -> (center: String, game: String, bridge: String)? {
        guard let executable = Bundle.main.executableURL ?? CommandLine.arguments.first.map({ URL(fileURLWithPath:$0) }) else { return nil }
        let helpers = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers")
        let center = helpers.appendingPathComponent("jidr-center-bridge")
        let bridge = helpers.appendingPathComponent("jidr-swiftui-bridge")
        let daemon = helpers.appendingPathComponent("jidr")
        let player = helpers.appendingPathComponent("JidrSwiftUIPrototype.app")
        let files = FileManager.default
        guard files.isExecutableFile(atPath:center.path),
              files.isExecutableFile(atPath:bridge.path),
              files.isExecutableFile(atPath:daemon.path) else { return nil }
        // The daemon auto-start in jidr-client already resolves Contents/Helpers/jidr
        // next to the bridge; point it explicitly so the package never falls back to
        // a `jidr` on PATH or a development build.
        if ProcessInfo.processInfo.environment["JIDR_DAEMON_BIN"] == nil { setenv("JIDR_DAEMON_BIN", daemon.path, 1) }
        // The standalone player is a development/test entry and may be absent from a
        // package; the center draws game windows in-process through the player bridge.
        return (center.path, files.fileExists(atPath:player.path) ? player.path : center.path, bridge.path)
    }
    /// A packaged test bundle carries the `test-package` sentinel. Without JIDR_HOME it
    /// uses its own data directory, so a Finder double-click works and never touches the
    /// user's Jidr data; development builds keep the explicit-JIDR_HOME requirement.
    private static func useTestPackageHome() {
        guard ProcessInfo.processInfo.environment["JIDR_HOME"]?.isEmpty != false,
              let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("test-package").path)
        else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jidr-SwiftUI-Test")
        setenv("JIDR_HOME", home.path, 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let usage = "usage: JIDR_HOME=<isolated-home> Center CENTER_BRIDGE GAME_APP PLAYER_BRIDGE\n       or launch the packaged app (its Contents/Helpers are found automatically)\n"
        Self.useTestPackageHome()
        guard ProcessInfo.processInfo.environment["JIDR_HOME"]?.isEmpty == false else { fputs(usage,stderr); NSApp.terminate(nil); return }
        // The explicit three-path form used by run-center.sh keeps its behaviour;
        // without arguments the packaged app resolves the helpers inside its bundle.
        let paths: (center: String, game: String, bridge: String)?
        if args.count == 4 { paths = (args[1], args[2], args[3]) }
        else if args.count == 1 { paths = Self.helpersInBundle() }
        else { paths = nil }
        guard let paths else { fputs(usage,stderr); NSApp.terminate(nil); return }
        do {
            let model = try CenterModel(center:paths.center,game:paths.game,bridge:paths.bridge); self.model = model
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
