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
print("Log filter tests passed")
