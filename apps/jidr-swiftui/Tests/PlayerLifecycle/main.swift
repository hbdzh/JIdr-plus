// SPDX-License-Identifier: GPL-3.0-only
// Integration regressions against the real center, transport and window owner.
// The bridge only serves fixtures; /usr/bin/false simulates a lost player link.
import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func eventually(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    require(condition(), message)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JIDR_HOME"]!)
try FileManager.default.createDirectory(at: home.appendingPathComponent("data"), withIntermediateDirectories: true)
let model = try CenterModel(center: CommandLine.arguments[1], bridge: "/usr/bin/false")
eventually("center fixture connects") { model.connection.isOnline && model.deviceListLoaded && model.dataDirectory != nil }
let id = "00000000-0000-4000-8000-000000000001"
model.openGame(id)
eventually("first player disconnects") { model.players[id]?.transport.connectionEnded == true }
let original = model.players[id]!
original.transport.reconnect()
eventually("center replaces disconnected player after Reconnect") {
    model.players[id] != nil && model.players[id] !== original
}
eventually("replacement bridge exits") { model.players[id]?.transport.connectionEnded == true }
let replacement = model.players[id]!
// Stop periodic refreshes: the remaining cases explicitly inject device states.
model.beginSafeQuit()

let mapping = replacement.transport.mapping
mapping.load(path: home.appendingPathComponent("test-keymap.json").path)
require(mapping.begin(), "mapping edit starts")
replacement.transport.reconnect()
require(model.players[id] === replacement, "Reconnect preserves an unsaved mapping")
mapping.cancel()
replacement.transport.recording = .recording
replacement.transport.reconnect()
require(model.players[id] === replacement, "Reconnect is blocked while recording")
replacement.transport.recording = .idle
replacement.transport.recordingStateUnknown = true
replacement.transport.reconnect()
require(model.players[id] === replacement, "Reconnect is blocked for an unknown recording")
replacement.transport.recordingStateUnknown = false

// Each in-flight recording phase can be interrupted by either a device stop
// or reboot. None may keep the window/quit guard stuck or claim a saved file.
let interruptedStates: [PlayerTransport.RecordingState] = [.starting, .recording, .stopping]
let launchStates: [PlayerLaunchState] = [.stopped(reason: "external stop"), .booting(progress: nil, message: "external reboot")]
for launch in launchStates {
    for state in interruptedStates {
        var notices: [String] = []
        replacement.transport.onStatus = { notices.append($0) }
        replacement.transport.recordingStateUnknown = false
        replacement.transport.recording = state
        replacement.transport.applyLaunchState(launch)
        require(replacement.transport.recording == .idle, "interrupted recording releases the pending phase")
        require(replacement.transport.recordingStateUnknown, "interrupted recording needs verification")
        require(notices.contains(where: { $0.contains("recording state is unknown") }), "interruption explains the unknown result")
        require(replacement.windowShouldClose(replacement.window!), "interrupted recording does not trap the window")
        require(!model.hasActiveRecording, "center quit guard is no longer stuck on this player")
        replacement.transport.toggleRecording()
        require(replacement.transport.recording == .idle, "unknown recording cannot start or stop on a dead bridge")
    }
}
replacement.transport.recordingStateUnknown = false
replacement.transport.applyLaunchState(.stopped(reason: "idle stop"))
require(!replacement.transport.recordingStateUnknown, "an idle stop does not invent a recording interruption")
replacement.window?.performClose(nil)
require(!model.hasPlayers && model.quitBlockReason == nil, "window and center can close after the interruption")
model.close()

// A diagnostic may already be queued when a CLI stop/reboot is processed.
// Hold the main queue until the fixture has emitted its "recording" reply,
// interrupt it, then drain callbacks from the retired generation.
let late = PlayerTransport()
late.language = 0
try late.start(device: id, width: 480, height: 640, executable: CommandLine.arguments[2])
late.recording = .starting
let marker = home.appendingPathComponent("recording-diagnostic-ready")
let diagnosticDeadline = Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath: marker.path), Date() < diagnosticDeadline {
    Thread.sleep(forTimeInterval: 0.01)
}
require(FileManager.default.fileExists(atPath: marker.path), "player fixture emitted its diagnostic")
Thread.sleep(forTimeInterval: 0.05)
late.applyLaunchState(.stopped(reason: "stop before queued diagnostic"))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
require(late.recording == .idle && late.recordingStateUnknown, "retired recording diagnostic cannot revive the pending phase")
late.stop()

// Run the real Rust fixture through the real window/transport. It must deliver
// a first frame and report unsupported device commands, not silently consume
// them. Pending recording must be released on that explicit rejection.
setenv("JIDR_PLAYER_FIXTURE", "1", 1)
let preview = GameWindowController()
preview.transport.language = 0
preview.open(device: id, width: 480, height: 640, executable: CommandLine.arguments[3], dataDirectory: home.appendingPathComponent("data").path)
eventually("real fixture produces a first frame and enables tools") { preview.transport.linkState.isRunning && preview.transport.frameWidth > 0 }
require(preview.transport.mapping.begin(), "local key mapping loads without a daemon in preview")
preview.transport.mapping.cancel()
var previewNotices: [String] = []
preview.transport.onStatus = { previewNotices.append($0) }
preview.transport.send(["type": "tool_key", "key": "home"])
eventually("device tool rejection reaches the player") { previewNotices.contains { $0.contains("UI preview") } }
preview.transport.recording = .starting
preview.transport.send(["type": "start_recording", "path": home.appendingPathComponent("preview.mp4").path])
eventually("preview recording rejection releases the pending phase") { preview.transport.recording == .idle }
require(!FileManager.default.fileExists(atPath: home.appendingPathComponent("preview.mp4").path), "preview never creates a fake recording")
preview.window?.performClose(nil)
unsetenv("JIDR_PLAYER_FIXTURE")
print("Center/player lifecycle regression tests passed")
