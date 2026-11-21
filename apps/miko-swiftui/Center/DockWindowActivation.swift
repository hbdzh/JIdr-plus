// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum DockWindowActivation {
    /// Returns only open player windows in AppKit's front-to-back order.
    static func visiblePlayers(_ players: [NSWindow], orderedWindows: [NSWindow]) -> [NSWindow] {
        orderedWindows.filter { candidate in
            candidate.isVisible && !candidate.isMiniaturized && players.contains { $0 === candidate }
        }
    }
}
