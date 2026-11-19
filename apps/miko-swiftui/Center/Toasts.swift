// SPDX-License-Identifier: GPL-3.0-only
// Transient feedback for the center: every operation reports success or a
// readable error in one toast instead of ad-hoc text. Tones and durations
// follow the Slint app (positive 4 s, error 9 s).

import Foundation

enum ToastTone: Equatable {
    case positive
    case negative
}

struct Toast: Identifiable, Equatable {
    let id: UUID
    let text: String
    let tone: ToastTone
    let duration: TimeInterval

    static let positiveDuration: TimeInterval = 4
    static let negativeDuration: TimeInterval = 9

    static func positive(_ text: String) -> Toast {
        Toast(id: UUID(), text: text, tone: .positive, duration: positiveDuration)
    }

    static func negative(_ text: String) -> Toast {
        Toast(id: UUID(), text: text, tone: .negative, duration: negativeDuration)
    }
}
