// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func waitUntil(_ condition: () -> Bool) -> Bool {
    let limit = Date().addingTimeInterval(3)
    while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return condition()
}
var events: [(Int, Int)] = []
var ended: [Int] = []
let bridge = CenterBridgeProcess(executable: "/bin/cat", onEvent: { value, session in
    if let id = value["id"] as? Int { events.append((session, id)) }
}, onTermination: { ended.append($0) })
try bridge.start(session: 7)
precondition(bridge.isRunning && bridge.canWrite)
precondition(bridge.send(id: 1, data: Data("{\"id\":1}\n".utf8)) { _ in preconditionFailure("unexpected write failure") })
precondition(waitUntil { events.contains { $0.0 == 7 && $0.1 == 1 } }, "echo arrives with originating session")
precondition(bridge.send(id: 4, data: Data("{\"id\":".utf8)) { _ in preconditionFailure("unexpected write failure") })
precondition(bridge.send(id: 5, data: Data("4}\nnot-json\n{\"id\":5}\n".utf8)) { _ in preconditionFailure("unexpected write failure") })
precondition(waitUntil { events.contains { $0.0 == 7 && $0.1 == 4 } && events.contains { $0.0 == 7 && $0.1 == 5 } },
             "fragmented and multiple lines are parsed and malformed lines ignored")
bridge.stopWriting()
precondition(!bridge.canWrite && !bridge.send(id: 2, data: Data()) { _ in }, "closed writer rejects work")
precondition(waitUntil { ended.contains(7) }, "closing input ends the first process")
bridge.stopReading()
try bridge.start(session: 8)
precondition(bridge.send(id: 3, data: Data("{\"id\":3}\n".utf8)) { _ in preconditionFailure("unexpected write failure") })
precondition(waitUntil { events.contains { $0.0 == 8 && $0.1 == 3 } }, "a new process reports its own session")
bridge.stopWriting()
precondition(waitUntil { ended.contains(8) })
bridge.stopReading()
print("Center bridge process tests passed")
