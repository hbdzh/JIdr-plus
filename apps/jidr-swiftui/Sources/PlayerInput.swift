// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Multi-touch gestures with modifiers, matching the Slint player's own
/// bindings (crates/jidr-ui/src/player/input.rs):
///
/// - plain drag: one finger;
/// - ⌥ drag (pinch): a second finger mirrors the first around the screen centre;
/// - ⇧⌥ drag (pan): a second finger follows at a fixed offset.
///
/// Points are normalized (0…1) to the screen as displayed. The bridge converts
/// them to panel pixels with the current rotation (`panel_point`), so the
/// player reuses the existing rotation/zoom mapping instead of duplicating it.
enum PlayerGesture: Equatable {
    case single
    case pinch
    case pan

    static func from(option: Bool, shift: Bool) -> PlayerGesture {
        if option && shift { return .pan }
        if option { return .pinch }
        return .single
    }

    var needsSecondFinger: Bool { self != .single }
}

enum PlayerTouch {
    /// Normalized position of the second finger for a gesture. `nil` for a
    /// single-finger gesture or invalid coordinates.
    ///
    /// The pan offset is `max(width / 8, 40)` device-independent pixels of the
    /// shown screen, the same as `fingers()` in the Slint input module.
    static func secondFinger(_ gesture: PlayerGesture,
                             x: Double, y: Double,
                             shownWidth: Double, shownHeight: Double) -> (x: Double, y: Double)? {
        guard gesture.needsSecondFinger,
              x.isFinite, y.isFinite, shownWidth.isFinite, shownHeight.isFinite,
              shownWidth > 0, shownHeight > 0,
              (0...1).contains(x), (0...1).contains(y) else { return nil }
        switch gesture {
        case .pinch:
            return (clamp(1 - x), clamp(1 - y))
        case .pan:
            let offset = max(shownWidth / 8, 40) / shownWidth
            return (clamp(x + offset), clamp(y))
        case .single:
            return nil
        }
    }

    /// The bridge maps a normalized shown point back to the panel with the
    /// frame's quarter-turn rotation. The second finger goes through the same
    /// path, so both fingers unrotate consistently (input.rs `panel_touches`).
    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    /// Mapped-touch identifiers used for the second finger: the bridge reserves
    /// 3…9 for mapped touches and 1 for the primary pointer.
    static let secondFingerID = 3
}
