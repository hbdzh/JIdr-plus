// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum LogFilter {
    static func arguments(_ text: String, level: String) -> [String] {
        var filters = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if !level.isEmpty { filters.append("*:\(level)") }
        return filters
    }
}
