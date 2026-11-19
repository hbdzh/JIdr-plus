// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: CenterModel?
    var window: NSWindow?
    /// App-wide key monitor: the center's shortcuts (⌘K, ⌘N, ⌘,, ⌘R, /, Esc)
    /// work from any responder, while unclaimed keys and text editing pass through.
    private var shortcutMonitor: Any?
    /// Bounds the safe-quit wait: a daemon that stops answering must not leave
    /// the app stuck in "quitting" forever.
    private var quitWatchdog: DispatchWorkItem?
    /// One center per MIKO_HOME; a second launch activates this one.
    private var singleInstance: CenterSingleInstance?
    /// Distributed-notification handler for "another launch wants this window".
    private var activationObserver: NSObjectProtocol?
    /// Native menu bar + Dock menu.
    private var menuController: CenterMenuController?
    /// The Rust helpers shipped in a packaged app: this executable's `Contents/Helpers`.
    /// Returns nil when that layout is incomplete, so the caller prints the usage line.
    private static func helpersInBundle() -> (center: String, bridge: String)? {
        guard let executable = Bundle.main.executableURL ?? CommandLine.arguments.first.map({ URL(fileURLWithPath:$0) }) else { return nil }
        let helpers = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers")
        let center = helpers.appendingPathComponent("miko-center-bridge")
        let bridge = helpers.appendingPathComponent("miko-swiftui-bridge")
        let daemon = helpers.appendingPathComponent("miko")
        let files = FileManager.default
        guard files.isExecutableFile(atPath:center.path),
              files.isExecutableFile(atPath:bridge.path),
              files.isExecutableFile(atPath:daemon.path) else { return nil }
        // The daemon auto-start in miko-client already resolves Contents/Helpers/miko
        // next to the bridge; point it explicitly so the package never falls back to
        // a `miko` on PATH or a development build.
        if ProcessInfo.processInfo.environment["MIKO_DAEMON_BIN"] == nil { setenv("MIKO_DAEMON_BIN", daemon.path, 1) }
        return (center.path, bridge.path)
    }
    /// The data directory a plain (`MIKO_HOME` unset) launch resolves to: the same
    /// `~/Library/Application Support/miko` the CLI and daemon use.
    private static func standardDataDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/miko").path
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let usage = "usage: MIKO_HOME=<isolated-home> Center CENTER_BRIDGE PLAYER_BRIDGE\n       or launch the packaged app (its Contents/Helpers are found automatically)\n"
        // A packaged production app is launched without
        // arguments: leave MIKO_HOME unset so the bridge and daemon use the same
        // standard paths as the CLI (`~/Library/Application Support/miko` as the
        // data directory). Development builds pass two helper arguments and
        // keep requiring an explicit MIKO_HOME, so a stray target/ launch never
        // writes real data.
        let environmentHome = ProcessInfo.processInfo.environment["MIKO_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
        if args.count != 1, environmentHome == nil {
            fputs(usage,stderr); NSApp.terminate(nil); return
        }
        let homeKey = environmentHome ?? Self.standardDataDirectory()
        // Single instance: take the per-data-directory lock before anything
        // spawns a bridge (or a daemon). A second launch only asks the running
        // center to show itself and exits, so it opens no window of its own.
        guard let instance = CenterSingleInstance.acquire(home: homeKey) else {
            CenterSingleInstance.requestActivation(home: homeKey)
            fputs("miko center: already running for \(homeKey); activating it\n", stderr)
            Thread.sleep(forTimeInterval: 0.4)
            exit(0)
        }
        singleInstance = instance
        // The explicit two-path form used by run-center.sh keeps its behaviour;
        // without arguments the packaged app resolves the helpers inside its bundle.
        let paths: (center: String, bridge: String)?
        if args.count == 3 { paths = (args[1], args[2]) }
        else if args.count == 1 { paths = Self.helpersInBundle() }
        else { paths = nil }
        guard let paths else { fputs(usage,stderr); NSApp.terminate(nil); return }
        do {
            let model = try CenterModel(center:paths.center,bridge:paths.bridge); self.model = model
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            // Keep the native resize limit consistent with CenterView's minimum layout.
            window.contentMinSize = NSSize(width:800,height:550)
            window.title = model.text("miko 模拟器 · 设备中心", "miko simulator · Device Center")
            window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none; window.backgroundColor = NSColor(WbColor.surface); window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:CenterView(model:model)); self.window = window
            menuController = CenterMenuController(model:model, presenter:self)
            menuController?.install()
            activationObserver = CenterSingleInstance.observeActivation(home: homeKey) { [weak self] in
                self?.showCenterWindow()
            }
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // Only the center window's plain keys (", Esc, palette arrows).
                // Command shortcuts belong to the menu key equivalents, and
                // player/tool windows keep their own shortcuts.
                guard let self, let model = self.model, event.window === self.window || event.window == nil else { return event }
                if event.type != .keyDown { model.keyboardDevice = nil; return event }
                if event.modifierFlags.contains(.command) { return event }
                return model.handleShortcutEvent(event) ? nil : event
            }
        } catch { fputs("\(error)\n",stderr); NSApp.terminate(nil) }
    }
    private var shuttingDown = false
    /// Closing the center window does not quit: hide it so the Dock icon and
    /// the menu bar can bring it back (macOS single-window app convention).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if model?.onboardingInstallForegroundRequired == true {
            model?.showOnboardingInstallBlocker()
            return false
        }
        sender.orderOut(nil)
        return false
    }

    /// Dock icon click (or AppleScript `reopen`) restores the hidden center;
    /// when a window is already visible this only activates the app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || window?.isVisible != true {
            showCenterWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuController?.dockMenu()
    }
    /// Brings the center window forward, from the Dock, a menu action or a
    /// second launch; deminiaturizes it when needed.
    func showCenterWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.onboardingInstallForegroundRequired {
            showCenterWindow()
            model.showOnboardingInstallBlocker()
            return .terminateCancel
        }
        guard !shuttingDown else { return .terminateLater }
        if model.canQuitWhileStopping {
            // The daemon has acknowledged every stop and owns it independently
            // of this client. Let the UI close while those stops finish.
            model.beginSafeQuit()
            return .terminateNow
        }
        if let reason = model.quitWorkBlockReason {
            showCenterWindow()
            model.presentQuitBlocker()
            model.showError(reason)
            return .terminateCancel
        }
        model.closePlayers()
        // Do not block silently: show the task list with the concrete reason
        // (recording, open windows, running jobs, in-flight operations) so the
        // user can cancel the work or wait for it right there.
        if let reason = model.quitBlockReason {
            showCenterWindow()
            model.presentQuitBlocker()
            model.showError(reason)
            return .terminateCancel
        }
        // Nothing to stop safely when the daemon is already unreachable.
        if !model.connection.isOnline {
            model.beginSafeQuit()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate:true) }
            return .terminateLater
        }
        shuttingDown = true
        model.beginSafeQuit()
        model.notice = model.text("正在安全停止设备并退出…", "Stopping devices safely and quitting…")
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.shuttingDown else { return }
            self.shuttingDown = false
            model.resumeAfterFailedQuit()
            model.notice = model.text("安全退出超时：后台没有及时响应。", "Safe quit timed out: the daemon did not answer in time.")
            model.showError(model.notice)
            NSApp.reply(toApplicationShouldTerminate:false)
        }
        quitWatchdog = watchdog
        // Each running emulator may need a guest sync, a bounded shutdown
        // request and up to two minutes to finish writing its snapshot.
        let timeout = 30.0 + 160.0 * Double(model.devices.filter(\.running).count)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        model.call("center.quit") { [weak self] result in
            guard let self, self.shuttingDown else { return }
            self.quitWatchdog?.cancel(); self.quitWatchdog = nil
            self.shuttingDown = false
            switch result {
            case .success: NSApp.reply(toApplicationShouldTerminate:true)
            case .failure(let error):
                model.resumeAfterFailedQuit()
                if (error as? CenterMessageError)?.isQuickBootSaveFailure == true {
                    model.notice = model.quickBootFailureMessage(error)
                    model.showError(model.notice)
                } else {
                    model.notice = model.text("无法安全退出：", "Unable to quit safely: ") + error.localizedDescription
                    model.showError(model.notice)
                }
                NSApp.reply(toApplicationShouldTerminate:false)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationWillTerminate(_ notification:Notification) {
        quitWatchdog?.cancel(); quitWatchdog = nil
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor); shortcutMonitor = nil }
        if let activationObserver { DistributedNotificationCenter.default().removeObserver(activationObserver) }
        activationObserver = nil
        model?.close()
        singleInstance?.release()
        singleInstance = nil
    }
}

extension Delegate: CenterWindowPresenting {
    var centerWindow: NSWindow? { window }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
