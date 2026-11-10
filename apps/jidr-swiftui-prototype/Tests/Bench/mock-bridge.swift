// SPDX-License-Identifier: GPL-3.0-only
// Offline fixture for the M4-B benchmark: a mock `jidr-swiftui-bridge` used only
// by `bench-player.sh --self-test`. It emits JFR1 160x160 RGBA frames at ~60 Hz;
// a `touch` down command paints a white probe patch (the show-taps dot) until
// touch up, so the harness' frame pump, probe detector and report can be
// validated without a daemon or a device. It is never built into the app.
import Foundation

final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var down = false
    func setDown(_ value: Bool) { lock.lock(); down = value; lock.unlock() }
    func isDown() -> Bool { lock.lock(); defer { lock.unlock() }; return down }
}
let state = State()

let width = 160, height = 160
let bytesPerRow = width * 4
var base = [UInt8](repeating: 0, count: height * bytesPerRow)
for y in 0..<height {
    for x in 0..<width {
        let o = y * bytesPerRow + x * 4
        base[o] = 40
        base[o + 1] = 60
        base[o + 2] = 90
        base[o + 3] = 255
    }
}
func paintProbe(_ target: inout [UInt8]) {
    let cx = Int(0.5 * Double(width)), cy = Int(0.55 * Double(height))
    for y in max(0, cy - 6)...min(height - 1, cy + 6) {
        for x in max(0, cx - 6)...min(width - 1, cx + 6) {
            let o = y * bytesPerRow + x * 4
            target[o] = 255; target[o + 1] = 255; target[o + 2] = 255
        }
    }
}
var downFrame = base
paintProbe(&downFrame)

let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput
let lock = NSLock()

DispatchQueue.global().async {
    var buffer = Data()
    while true {
        let data = stdin.availableData
        if data.isEmpty { break }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "touch",
                  let down = object["down"] as? Bool else { continue }
            state.setDown(down)
        }
    }
}

var sequence = 0
while true {
    let start = Date()
    let pixels = state.isDown() ? downFrame : base
    var packet = Data("JFR1".utf8)
    for value in [width, height, 0, pixels.count] {
        var bigEndian = UInt32(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { packet.append(contentsOf: $0) }
    }
    packet.append(contentsOf: pixels)
    lock.lock()
    try? stdout.write(contentsOf: packet)
    lock.unlock()
    sequence += 1
    let elapsed = Date().timeIntervalSince(start)
    let sleep = max(0, 1.0 / 60.0 - elapsed)
    Thread.sleep(forTimeInterval: sleep)
}
