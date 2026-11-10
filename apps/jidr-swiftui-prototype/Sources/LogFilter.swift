// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum LogFilter {
    static func arguments(_ text: String, level: String) -> [String] {
        var filters = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if !level.isEmpty { filters.append("*:\(level)") }
        return filters
    }

    /// Android level letter of a threadtime logcat line
    /// (`10-13 14:02:07.318  4821  4821 I ActivityManager: …`). Unknown lines
    /// (headers, bridge diagnostics) answer `""`.
    static func level(of line: String) -> String {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 6 else { return "" }
        let level = String(parts[4])
        guard level.count == 1, "VDIWEFA".contains(level) else { return "" }
        return level
    }

    /// Errors and fatal lines drive the player's collapsed logcat pill.
    static func isError(_ line: String) -> Bool {
        let level = level(of: line)
        return level == "E" || level == "F" || level == "A"
    }
}
