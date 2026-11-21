// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// The registry only owns these objects; these stand-ins avoid opening windows.
final class GameWindowController {}
final class DeviceToolsPanelController {
    var onClose: (() -> Void)?
    func close() { onClose?() }
}
enum PlayerLaunchState: Equatable { case running, stopped }

let lifecycle = CenterDeviceLifecycle()
lifecycle.beginStart("a")
precondition(lifecycle.requestWindowStop("a"))
precondition(!lifecycle.requestWindowStop("a"), "duplicate close requests do not stop twice")
precondition(lifecycle.jobToCancel(for: "a") == nil, "start job may arrive later")
lifecycle.recordStartJob("job", for: "a")
precondition(lifecycle.jobToCancel(for: "a") == "job")
precondition(lifecycle.jobToCancel(for: "a") == nil, "start cancellation is sent once")
lifecycle.finishStart("a")
precondition(!lifecycle.startingDevices.contains("a") && lifecycle.pendingWindowStops.contains("a"))
lifecycle.beginStop("a")
precondition(lifecycle.stoppingDevices.contains("a"))
lifecycle.finishStop("a"); lifecycle.finishWindowStop("a")
precondition(lifecycle.stoppingDevices.isEmpty && lifecycle.pendingWindowStops.isEmpty)
lifecycle.beginStart("a"); lifecycle.recordStartJob("next", for: "a")
precondition(lifecycle.requestWindowStop("a") && lifecycle.jobToCancel(for: "a") == "next", "next start has fresh cancellation state")

let windows = CenterWindowRegistry()
let player = GameWindowController()
windows.markBackground("a")
precondition(windows.isBackground("a") && windows.beginOpening("a") && !windows.beginOpening("a"))
windows.requestVisible("a")
precondition(!windows.isBackground("a") && windows.consumeVisible("a") && !windows.consumeVisible("a"))
windows.endOpening("a")
windows.setInitialLaunchState(.stopped, for: "a")
windows.setPlayer(player, for: "a")
precondition(!windows.markLaunchState(.stopped, for: "a"))
precondition(windows.markLaunchState(.running, for: "a") && !windows.markLaunchState(.running, for: "a"))
windows.removePlayer("a")
precondition(windows.players.isEmpty)
windows.setPlayer(player, for: "a")
precondition(windows.markLaunchState(.running, for: "a"), "removing a window clears its remembered state")
let tool = DeviceToolsPanelController()
tool.onClose = { windows.removeTool("a") }
windows.setTool(tool, for: "a")
windows.closeAllTools()
precondition(windows.tool("a") == nil, "closing tools tolerates callbacks removing entries")
print("Device lifecycle and window registry tests passed")
