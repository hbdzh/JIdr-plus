// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Modifier → gesture mapping (⌥ pinch, ⇧⌥ two-finger pan).
precondition(PlayerGesture.from(option: false, shift: false) == .single)
precondition(PlayerGesture.from(option: true, shift: false) == .pinch)
precondition(PlayerGesture.from(option: true, shift: true) == .pan)
precondition(PlayerGesture.from(option: false, shift: true) == .single)
precondition(PlayerGesture.pinch.needsSecondFinger && PlayerGesture.pan.needsSecondFinger)
precondition(!PlayerGesture.single.needsSecondFinger)

// Single-finger gestures have no second finger.
precondition(PlayerTouch.secondFinger(.single, x: 0.4, y: 0.6, shownWidth: 720, shownHeight: 1280) == nil)

// Pinch mirrors the first finger around the screen centre.
let pinch = PlayerTouch.secondFinger(.pinch, x: 0.2, y: 0.3, shownWidth: 720, shownHeight: 1280)
precondition(pinch?.x == 0.8 && pinch?.y == 0.7)
let pinchEdge = PlayerTouch.secondFinger(.pinch, x: 1, y: 1, shownWidth: 720, shownHeight: 1280)
precondition(pinchEdge?.x == 0 && pinchEdge?.y == 0)

// Pan offsets by max(width / 8, 40) shown pixels (fingers() in input.rs).
let panWide = PlayerTouch.secondFinger(.pan, x: 0.2, y: 0.5, shownWidth: 1080, shownHeight: 2400)
precondition(panWide != nil)
precondition(abs((panWide?.x ?? 0) - 0.325) < 1e-9, "wide pan \(String(describing: panWide))")
let panNarrow = PlayerTouch.secondFinger(.pan, x: 0.2, y: 0.5, shownWidth: 200, shownHeight: 300)
precondition(abs((panNarrow?.x ?? 0) - 0.4) < 1e-9, "narrow pan \(String(describing: panNarrow))")
let panClamped = PlayerTouch.secondFinger(.pan, x: 0.95, y: 0.5, shownWidth: 720, shownHeight: 1280)
precondition(panClamped?.x == 1)

// Invalid input never produces a touch point.
precondition(PlayerTouch.secondFinger(.pinch, x: -0.1, y: 0.5, shownWidth: 720, shownHeight: 1280) == nil)
precondition(PlayerTouch.secondFinger(.pinch, x: 0.5, y: 0.5, shownWidth: 0, shownHeight: 1280) == nil)
precondition(PlayerTouch.secondFinger(.pinch, x: .nan, y: 0.5, shownWidth: 720, shownHeight: 1280) == nil)
precondition(PlayerTouch.secondFingerID == 3)

print("Player input tests passed")
