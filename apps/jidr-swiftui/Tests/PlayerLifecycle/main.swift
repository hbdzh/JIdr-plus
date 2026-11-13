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

func findScreenView(in view: NSView) -> ScreenView? {
    if let screen = view as? ScreenView { return screen }
    for subview in view.subviews {
        if let found = findScreenView(in: subview) { return found }
    }
    return nil
}
func stopRequests(in home: URL) -> Int {
    let text = (try? String(contentsOf: home.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
    return text.components(separatedBy: "\n").filter { $0.contains("\"method\": \"device.stop\"") }.count
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JIDR_HOME"]!)
try FileManager.default.createDirectory(at: home.appendingPathComponent("data"), withIntermediateDirectories: true)
let model = try CenterModel(center: CommandLine.arguments[1], bridge: "/usr/bin/false")
eventually("center fixture connects") { model.connection.isOnline && model.deviceListLoaded && model.dataDirectory != nil }
let id = "00000000-0000-4000-8000-000000000001"
model.loadCardHardware(id)
model.loadCardHardware(id)
let secondID = "00000000-0000-4000-8000-000000000002"
model.loadCardHardware(secondID)
eventually("card loads its device's hardware") { model.cardHardware[id]?.memory == "2048" }
eventually("another card loads its own hardware") { model.cardHardware[secondID]?.memory == "4096" }
require(model.cardHardware[secondID]?.width == "720" && model.cardHardware[id]?.width == "480",
        "device cards do not share another device's configuration")
require(model.cardHardware[id]?.summary(language: 0) == "480 × 640 · 2048 MB · 2 cores · 320 DPI",
        "card hardware displays resolution, memory, CPU and DPI")
let missingHardware = DeviceHardware(config: ["hw.ramSize": "invalid"])
require(missingHardware.summary(language: 1) == "— × — · — MB · — 核 · — DPI",
        "missing or invalid hardware values remain unknown")
FileManager.default.createFile(atPath: home.appendingPathComponent("hardware-updated").path, contents: Data())
model.refreshCardHardware(id)
eventually("card reloads changed hardware") { model.cardHardware[id]?.memory == "3072" }
model.openGame(id)
eventually("first player disconnects") { model.players[id]?.transport.connectionEnded == true }
let original = model.players[id]!
original.transport.reconnect()
eventually("center replaces disconnected player after Reconnect") {
    model.players[id] != nil && model.players[id] !== original
}
eventually("replacement bridge exits") { model.players[id]?.transport.connectionEnded == true }
var replacement = model.players[id]!
require(stopRequests(in: home) == 0, "reconnecting a player does not stop the device")
model.recording.insert(id)
replacement.window?.performClose(nil)
require(model.players[id] === replacement && stopRequests(in: home) == 0,
        "an active center recording prevents closing and stopping the player")
model.recording.remove(id)
model.operation("test.block", id: id)
eventually("fixture operation is in progress") { FileManager.default.fileExists(atPath: home.appendingPathComponent("block-started").path) }
replacement.window?.performClose(nil)
require(!model.hasPlayers, "closing the player removes its window")
require(stopRequests(in: home) == 0, "stop waits for the in-flight operation")
FileManager.default.createFile(atPath: home.appendingPathComponent("block-release").path, contents: Data())
eventually("window close stops the device after the in-flight operation") { stopRequests(in: home) == 1 && !model.busy.contains(id) }
model.openGame(id)
eventually("player reopens before an explicit stop") { model.players[id]?.transport.connectionEnded == true }
model.stop(id)
eventually("explicit stop sends exactly one request") { stopRequests(in: home) == 2 && !model.busy.contains(id) }
require(!model.hasPlayers, "explicit stop closes the player")
FileManager.default.createFile(atPath: home.appendingPathComponent("fixture-stopped").path, contents: Data())
FileManager.default.createFile(atPath: home.appendingPathComponent("block-start").path, contents: Data())
model.refresh()
eventually("fixture device is stopped before startup") { model.devices.first?.stopped == true }
model.start(id)
eventually("starting player opens while startup is in progress") {
    model.players[id]?.window != nil && FileManager.default.fileExists(atPath: home.appendingPathComponent("start-started").path)
}
model.players[id]?.window?.performClose(nil)
require(!model.hasPlayers && stopRequests(in: home) == 2, "closing during startup queues the stop")
FileManager.default.createFile(atPath: home.appendingPathComponent("start-release").path, contents: Data())
eventually("startup completion is followed by one stop") { stopRequests(in: home) == 3 && !model.busy.contains(id) }
try FileManager.default.removeItem(at: home.appendingPathComponent("fixture-stopped"))
model.refresh()
eventually("fixture reports the device running") { model.devices.first?.running == true }
model.openGame(id)
eventually("player can be opened for remaining lifecycle checks") { model.players[id]?.transport.connectionEnded == true }
replacement = model.players[id]!
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
eventually("closing a running player requests one stop") { stopRequests(in: home) == 4 && !model.busy.contains(id) }
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
require(preview.transport.measureDecodedFrame == nil && preview.transport.onMeasuredFramePresented == nil
        && preview.transport.onFrameDrawn == nil && preview.transport.onFrameReplaced == nil,
        "normal windows leave all measurement hooks disabled")
var matchingSamples = 0
var actualDraws = 0
preview.transport.measureDecodedFrame = { frame in
    PlayerFrameProbeSample(receivedAt: ProcessInfo.processInfo.systemUptime,
                           red: Double(frame.width), green: Double(frame.height), blue: Double(frame.rotation))
}
preview.transport.onMeasuredFramePresented = { [weak transport = preview.transport] sample in
    require(sample.red == Double(transport?.frameWidth ?? 0) && sample.green == Double(transport?.frameHeight ?? 0),
            "measurement metadata follows its matching displayed frame")
    matchingSamples += 1
}
preview.transport.onFrameDrawn = { actualDraws += 1 }
preview.open(device: id, width: 480, height: 640, executable: CommandLine.arguments[3], dataDirectory: home.appendingPathComponent("data").path)
eventually("real fixture produces a first frame and enables tools") { preview.transport.linkState.isRunning && preview.transport.frameWidth > 0 }
eventually("measurement counts actual ScreenView draws and matched samples") { matchingSamples > 0 && actualDraws > 0 }

// Regression: the player has no bottom Logcat strip. The screen area must use
// the full window content height (otherwise the window's device aspect would
// produce side letterboxing), leave the sidebar strip at its width, and keep the
// device frame aspect.
guard let playerContent = preview.window?.contentView,
      let playerContentSize = preview.window?.contentLayoutRect.size,
      let screenView = findScreenView(in: playerContent) else {
    preconditionFailure("player window has no ScreenView for the layout regression")
}
let expectedSidebarWidth = WbLayout.windowDeviceToolbarWidth
require(abs(screenView.frame.height - playerContentSize.height) < 1.5,
        "screen area uses the full content height (no Logcat strip)")
require(abs(screenView.frame.width - (playerContentSize.width - expectedSidebarWidth)) < 1.5,
        "screen area is content width minus the sidebar")
require(abs(screenView.frame.width / screenView.frame.height
            - CGFloat(preview.transport.frameWidth) / CGFloat(preview.transport.frameHeight)) < 0.01,
        "screen area aspect matches the device frame (no letterbox)")
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
