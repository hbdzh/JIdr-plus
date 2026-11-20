// SPDX-License-Identifier: GPL-3.0-only
import Foundation

precondition(LogFilter.arguments("", level: "").isEmpty)
precondition(LogFilter.arguments("ActivityManager:I\tTest:D", level: "W") == ["ActivityManager:I", "Test:D", "*:W"])
precondition(LogFilter.arguments("  \n ", level: "E") == ["*:E"])
var buffer = LogLineBuffer(limit: 3)
buffer.append(["one", "two"])
buffer.append(["three", "four"])
precondition(buffer.lines == ["two", "three", "four"])
buffer.append(["five", "six", "seven", "eight"])
precondition(buffer.lines == ["six", "seven", "eight"])
// Compare the incremental roll-up with a full scan as old lines expire,
// including empty and oversized batches and errors that leave the window.
let sampleLogs = [
    "11-20 21:44:03.123  1000  1000 I ActivityManager: normal",
    "11-20 21:44:03.123  1000  1000 E ActivityManager: error",
    "11-20 21:44:03.123  1000  1000 F ActivityManager: fatal",
    "unknown header"
]
var incremental = LogLineBuffer(limit: 7)
var reference: [String] = []
for i in 0..<100 {
    let batch = (0..<(i % 11)).map { sampleLogs[(i * 3 + $0) % sampleLogs.count] }
    incremental.append(batch)
    reference.append(contentsOf: batch)
    if reference.count > 7 { reference.removeFirst(reference.count - 7) }
    precondition(incremental.lines == reference)
    precondition(incremental.errorCount == reference.filter(LogFilter.isError).count)
    precondition(incremental.lastError == (reference.last(where: LogFilter.isError) ?? ""))
}
var reset = LogLineBuffer(limit: 2)
reset.append([sampleLogs[1], sampleLogs[0], sampleLogs[0]])
precondition(reset.errorCount == 0 && reset.lastError.isEmpty)
print("Log filter tests passed")
