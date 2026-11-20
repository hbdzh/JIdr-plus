import AppKit
import SwiftUI
import Foundation
func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func eventually(_ seconds: Double, _ condition: () -> Bool) -> Bool {
 let end = Date().addingTimeInterval(seconds)
 while !condition() && Date() < end { pump(0.01) }
 return condition()
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = try CenterModel(center: CommandLine.arguments[1], bridge: "/usr/bin/false")
let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.contentView = NSHostingView(rootView: CenterView(model:model))
window.orderFrontRegardless()
precondition(eventually(5) { model.connection.isOnline }, "fixture connection")
var pauseReady = false
model.call("test.pause") { _ in pauseReady = true }
precondition(eventually(3) { pauseReady }, "pause setup")
model.detailsReadTimeout = 0.1
var timeoutDone = 0, timeoutFailed = false
var timerElapsed = -1.0
let start = ProcessInfo.processInfo.systemUptime
DispatchQueue.main.asyncAfter(deadline:.now()+0.05) { timerElapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
var largeDone = 0
model.call("clipboard.set", ["text":String(repeating:"a", count:524288)]) { _ in largeDone += 1 }
model.call("device.details", ["device":"unsent-timeout"]) { result in timeoutDone += 1; if case .failure = result { timeoutFailed = true } }
let callMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
precondition(eventually(5) { timerElapsed >= 0 && largeDone == 1 && timeoutDone == 1 }, "large request completes and queued request times out")
precondition(timeoutFailed, "queued timeout fails")
let logPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIKO_HOME"]!).appendingPathComponent("requests.log")
let log = try String(contentsOf: logPath, encoding: .utf8)
precondition(!log.contains("device.details"), "timed-out queued request must not be sent")
print("TIMEOUT callbacks=\(timeoutDone) failed=\(timeoutFailed) unsent=true")
print("SLOW call_ms=\(callMs) main_timer_ms=\(timerElapsed) callbacks=\(largeDone)")
var outcomes: [Int] = []
for i in 0..<10 { model.call("test.order", ["seq":i]) { result in
 if case .success(let value) = result, let data = value as? [String:Any], let seq = data["seq"] as? Int { outcomes.append(seq) }
} }
precondition(eventually(5) { outcomes.count == 10 }, "order responses")
precondition(outcomes == Array(0..<10), "responses follow fixture request order")
print("ORDER responses=\(outcomes)")
var heldCallbacks = 0, heldFailure = false, disconnectCallbacks = 0
model.call("test.hold") { result in heldCallbacks += 1; if case .failure = result { heldFailure = true } }
model.call("test.disconnect") { _ in disconnectCallbacks += 1 }
precondition(eventually(5) { heldCallbacks == 1 && disconnectCallbacks == 1 }, "fail pending on disconnect")
precondition(eventually(8) { model.connection.isOnline }, "reconnect")
var again = false
model.call("test.order", ["seq":99]) { result in if case .success = result { again = true } }
precondition(eventually(5) { again }, "request after reconnect")
pump(0.5)
precondition(heldFailure && heldCallbacks == 1 && disconnectCallbacks == 1, "disconnect callbacks are delivered once")
print("RECONNECT held_callbacks=\(heldCallbacks) held_failure=\(heldFailure) disconnect_callbacks=\(disconnectCallbacks) post_reconnect=\(again)")
model.close(); window.close()
