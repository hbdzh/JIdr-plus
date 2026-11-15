// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum PacketLoss {
    static func parse(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}
