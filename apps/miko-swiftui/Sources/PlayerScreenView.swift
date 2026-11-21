// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

final class ScreenView: NSView, NSTextInputClient {
    var transport: PlayerTransport?
    var image: CGImage? { didSet { needsDisplay = true } }
    private enum EditingDrag {
        case binding(key: String, rotation: Int, start: NSPoint, moved: Bool)
        case joystick(index: Int, start: NSPoint, moved: Bool)
    }
    private var rotation = 0
    private var mappedKeys: [UInt16: (id: Int, x: Double, y: Double)] = [:]
    private var activeJoysticks: [Int: (id: Int, x: Double, y: Double, held: Set<JoystickDirection>)] = [:]
    private var activeJoystickKeys: [UInt16: (index: Int, direction: JoystickDirection)] = [:]
    private var editingDrag: EditingDrag?
    func present(_ frame: CGImage, rotation next: Int) {
        if rotation != next { releaseMappedKeys(); rotation = next; transport?.mapping.rotationChanged(to: next) }
        image = frame
    }
    private var marked = NSMutableAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var dragging = false
    private var lastTouch: (CGFloat, CGFloat)?
    private var gesture: PlayerGesture = .single
    private var secondFingerDown = false
    private var secondFinger: (x: Double, y: Double)?
    private var pendingKey: (UInt16, String)?
    private var pressedKeys: [UInt16: String] = [:]
    private var pressedModifiers: Set<String> = []
    private var scriptPlaybackBlocked = false
    private var syncFollowerLocked = false
    private var lastSyncRole: PlayerSyncRole = .off
    private var windowObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        transport?.setDropHover(draggedURL(sender))
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { transport?.setDropHover(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedURL(sender), sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count == 1 else { return false }
        transport?.setDropHover(nil)
        transport?.sendFile(url)
        return true
    }
    private func draggedURL(_ sender: NSDraggingInfo) -> URL? {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
              url.isFileURL else { return nil }
        return url
    }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.releaseHeldInputs() }
        } else {
            windowObserver = nil
        }
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    private var imageRect: NSRect {
        guard let image, image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let boundsAspect = bounds.width / bounds.height
        if abs(boundsAspect - imageAspect) / imageAspect < 0.01 {
            return bounds
        }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        // AppKit can request drawing outside a view's bounds. Keep the video
        // background from painting over the shared titlebar or side rail.
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.black.setFill()
        dirtyRect.fill()
        if let image {
            let backing = window?.backingScaleFactor ?? 1
            let exact = abs(imageRect.width * backing - CGFloat(image.width)) < 0.5 && abs(imageRect.height * backing - CGFloat(image.height)) < 0.5
            NSGraphicsContext.current?.imageInterpolation = exact ? .none : .high
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: imageRect)
            transport?.onFrameDrawn?()
        }
        if let mapping = transport?.mapping {
            let markerFont = WbFontResolver.nsFont(family: WbType.label.family, weight: .semibold, size: WbType.label.size)
            let joystickFont = WbFontResolver.nsFont(family: WbType.caption.family, weight: .semibold, size: WbType.caption.size)
            let markerAlpha = CGFloat(mapping.editing ? max(0.75, mapping.markerOpacity) : mapping.markerOpacity)
            let labelAlpha = min(1.0, markerAlpha + 0.15)
            let rect = imageRect
            let shortSide = min(rect.width, rect.height)
            for (index, joystick) in mapping.visibleJoysticks.enumerated() where joystick.rotation == rotation {
                let c = NSPoint(x: rect.minX + rect.width * joystick.x, y: rect.minY + rect.height * joystick.y)
                let r = max(20, shortSide * joystick.radius)
                let circle = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                NSColor(white: 0.14, alpha: markerAlpha * 0.56).setFill()
                let ringPath = NSBezierPath(ovalIn: circle)
                ringPath.fill()
                ringPath.lineWidth = 1.5
                NSColor.white.withAlphaComponent(markerAlpha * 0.78).setStroke()
                ringPath.stroke()
                if mapping.editing && mapping.selectedJoystickIndex == index {
                    let selectedRing = NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2))
                    selectedRing.lineWidth = 2.5
                    NSColor(WbColor.accent).setStroke()
                    selectedRing.stroke()
                }
                let centerDot = NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                NSColor.white.withAlphaComponent(min(1.0, markerAlpha * 0.9)).setFill()
                NSBezierPath(ovalIn: centerDot).fill()
                let offset = r * 0.62
                let labels: [(String, NSPoint)] = [
                    (joystick.up, NSPoint(x: c.x, y: c.y - offset)),
                    (joystick.down, NSPoint(x: c.x, y: c.y + offset)),
                    (joystick.left, NSPoint(x: c.x - offset, y: c.y)),
                    (joystick.right, NSPoint(x: c.x + offset, y: c.y)),
                ]
                let attrs: [NSAttributedString.Key: Any] = [.font: joystickFont, .foregroundColor: NSColor.white.withAlphaComponent(labelAlpha)]
                for (rawKey, pos) in labels {
                    let label = MappingKey.displayLabel(rawKey)
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: pos.x - size.width / 2, y: pos.y - size.height / 2), withAttributes: attrs)
                }
            }
            for binding in mapping.visibleBindings where binding.rotation == rotation {
                let p = NSPoint(x: rect.minX + rect.width * binding.x, y: rect.minY + rect.height * binding.y)
                let circle = NSRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)
                NSColor(white: 0.14, alpha: markerAlpha * 0.78).setFill()
                let oval = NSBezierPath(ovalIn: circle)
                oval.fill()
                oval.lineWidth = 1.5
                NSColor.white.withAlphaComponent(markerAlpha * 0.85).setStroke()
                oval.stroke()
                if mapping.editing && mapping.selectedKey == binding.key {
                    let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2))
                    ring.lineWidth = 2.5
                    NSColor(WbColor.accent).setStroke()
                    ring.stroke()
                }
                let label = MappingKey.displayLabel(binding.key)
                let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: NSColor.white.withAlphaComponent(labelAlpha)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
            }
            if mapping.editing, let pending = mapping.pendingPoint, pending.rotation == rotation {
                let p = NSPoint(x: rect.minX + rect.width * pending.x, y: rect.minY + rect.height * pending.y)
                let circle = NSRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)
                NSColor(WbColor.accent).withAlphaComponent(0.28).setFill()
                let path = NSBezierPath(ovalIn: circle)
                path.fill()
                path.lineWidth = 2
                let dashes: [CGFloat] = [4, 3]
                path.setLineDash(dashes, count: dashes.count, phase: 0)
                NSColor(WbColor.accent).setStroke()
                path.stroke()
                let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: NSColor(WbColor.textOnAccent)]
                let label = "?"
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
            }
        }
        if marked.length > 0 {
            let box = NSRect(x: 12, y: max(12, bounds.height - 46), width: max(0, bounds.width - 24), height: 34)
            NSColor(WbColor.chrome).withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            marked.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 6))
        }
    }
    private func normalized(_ event: NSEvent) -> (CGFloat, CGFloat)? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return (min(1, max(0, (point.x - rect.minX) / rect.width)),
                min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func sendTouch(_ event: NSEvent, down: Bool) {
        let rect = imageRect, point = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.height > 0 else { return }
        if !dragging && !rect.contains(point) { return }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        let y = min(1, max(0, (point.y - rect.minY) / rect.height))
        lastTouch = (x, y)
        transport?.noteInput()
        transport?.send(["type": "touch", "x": x, "y": y, "down": down])
    }
    /// ⌥ drag = pinch, ⇧⌥ drag = two-finger pan. The second finger travels as a
    /// mapped touch (identifier 3) and goes through the same rotation mapping.
    private func secondFingerPoint(_ event: NSEvent) -> (x: Double, y: Double)? {
        guard let image, let (x, y) = normalized(event) else { return nil }
        return PlayerTouch.secondFinger(gesture, x: Double(x), y: Double(y),
                                        shownWidth: Double(image.width), shownHeight: Double(image.height))
    }
    private func sendSecondFinger(_ point: (x: Double, y: Double), down: Bool) {
        transport?.noteInput()
        transport?.send(["type": "mapped_touch", "id": PlayerTouch.secondFingerID,
                         "x": point.x, "y": point.y, "down": down])
    }
    private func clampedNormalizedPoint(_ point: NSPoint) -> (Double, Double)? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (Double(min(1, max(0, (point.x - rect.minX) / rect.width))),
                Double(min(1, max(0, (point.y - rect.minY) / rect.height))))
    }
    private func bindingHit(at point: NSPoint) -> MappingBinding? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, let mapping = transport?.mapping else { return nil }
        return mapping.visibleBindings.reversed().first { binding in
            guard binding.rotation == rotation else { return false }
            let center = NSPoint(x: rect.minX + rect.width * binding.x, y: rect.minY + rect.height * binding.y)
            return hypot(point.x - center.x, point.y - center.y) <= 19
        }
    }
    private func joystickHit(at point: NSPoint) -> Int? {
        let rect = imageRect
        let shortSide = min(rect.width, rect.height)
        guard rect.width > 0, rect.height > 0, let mapping = transport?.mapping else { return nil }
        for (index, joystick) in mapping.visibleJoysticks.enumerated().reversed() where joystick.rotation == rotation {
            let center = NSPoint(x: rect.minX + rect.width * joystick.x, y: rect.minY + rect.height * joystick.y)
            let r = max(20, shortSide * joystick.radius)
            if hypot(point.x - center.x, point.y - center.y) <= r + 6 {
                return index
            }
        }
        return nil
    }
    private func nextTouchID() -> Int? {
        let used = Set(mappedKeys.values.map(\.id)).union(activeJoysticks.values.map(\.id))
        return (3...9).first { !used.contains($0) }
    }
    private var imageAspect: Double {
        if let image, image.height > 0 { return Double(image.width) / Double(image.height) }
        let rect = imageRect
        return rect.height > 0 ? Double(rect.width / rect.height) : 1.0
    }
    override func mouseDown(with event: NSEvent) {
        guard !scriptPlaybackActive else { return }
        if syncFollowerLocked {
            transport?.showSyncLockedHint()
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        if let mapping = transport?.mapping, mapping.editing {
            let lang = transport?.language ?? 1
            if let hit = bindingHit(at: point), mapping.select(key: hit.key, rotation: rotation) {
                editingDrag = .binding(key: hit.key, rotation: rotation, start: point, moved: false)
            } else if let idx = joystickHit(at: point), mapping.selectJoystick(at: idx) {
                editingDrag = .joystick(index: idx, start: point, moved: false)
            } else if let (nx, ny) = clampedNormalizedPoint(point) {
                editingDrag = nil
                if mapping.placementMode == .joystick {
                    if mapping.addJoystick(x: nx, y: ny, rotation: rotation, preset: .wasd)
                        || mapping.addJoystick(x: nx, y: ny, rotation: rotation, preset: .arrows) {
                        mapping.placementMode = .tap
                    } else {
                        transport?.onStatus?(t("WASD 和方向键均已被占用", "WASD and arrow keys are already bound", lang))
                    }
                } else {
                    mapping.place(x: nx, y: ny, rotation: rotation)
                }
            }
            return
        }
        gesture = PlayerGesture.from(option: event.modifierFlags.contains(.option),
                                     shift: event.modifierFlags.contains(.shift))
        dragging = true
        if gesture.needsSecondFinger, let second = secondFingerPoint(event) {
            secondFinger = second
            secondFingerDown = true
            sendSecondFinger(second, down: true)
        }
        sendTouch(event, down: true)
    }
    override func mouseDragged(with event: NSEvent) {
        if let mapping = transport?.mapping, mapping.editing, let drag = editingDrag {
            let point = convert(event.locationInWindow, from: nil)
            switch drag {
            case .binding(let key, let rot, let start, var moved):
                if moved || hypot(point.x - start.x, point.y - start.y) >= 3 {
                    moved = true
                    editingDrag = .binding(key: key, rotation: rot, start: start, moved: moved)
                    if let (nx, ny) = clampedNormalizedPoint(point) {
                        _ = mapping.move(key: key, rotation: rot, x: nx, y: ny)
                    }
                }
            case .joystick(let idx, let start, var moved):
                if moved || hypot(point.x - start.x, point.y - start.y) >= 3 {
                    moved = true
                    editingDrag = .joystick(index: idx, start: start, moved: moved)
                    if let (nx, ny) = clampedNormalizedPoint(point) {
                        _ = mapping.moveJoystick(at: idx, x: nx, y: ny)
                    }
                }
            }
            return
        }
        guard dragging, !inputBlocked else { return }
        if secondFingerDown, let second = secondFingerPoint(event) {
            secondFinger = second
            sendSecondFinger(second, down: true)
        }
        sendTouch(event, down: true)
    }
    override func mouseUp(with event: NSEvent) {
        if let mapping = transport?.mapping, mapping.editing, editingDrag != nil {
            editingDrag = nil
            return
        }
        if inputBlocked { clearHeldInputState(); return }
        guard dragging else { return }
        if secondFingerDown, let second = secondFinger {
            sendSecondFinger(second, down: false)
        }
        sendTouch(event, down: false)
        dragging = false
        secondFingerDown = false
        secondFinger = nil
        gesture = .single
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let mapping = transport?.mapping, mapping.editing else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let lang = transport?.language ?? 1
        if let hit = bindingHit(at: point) {
            if mapping.remove(key: hit.key, rotation: rotation) {
                transport?.onStatus?(t("已删除键位 ", "Removed ", lang) + MappingKey.displayLabel(hit.key))
            }
            return
        }
        if let idx = joystickHit(at: point), mapping.removeJoystick(at: idx) {
            transport?.onStatus?(t("已删除摇杆", "Removed joystick", lang))
        }
    }
    private func releaseMappedKeys() {
        for value in mappedKeys.values { transport?.send(["type": "mapped_touch", "id": value.id, "x": value.x, "y": value.y, "down": false]) }
        mappedKeys.removeAll()
        for state in activeJoysticks.values { transport?.send(["type": "mapped_touch", "id": state.id, "x": state.x, "y": state.y, "down": false]) }
        activeJoysticks.removeAll()
        activeJoystickKeys.removeAll()
    }
    /// Playback owns input in the bridge. The view stops sending ordinary input
    /// while a script plays; held state is dropped locally without sending
    /// releases because the bridge already released it on playback start.
    func setScriptPlaybackBlocked(_ blocked: Bool) {
        guard blocked != scriptPlaybackBlocked else { return }
        scriptPlaybackBlocked = blocked
        if blocked { clearHeldInputState() }
    }

    func setSyncState(role: PlayerSyncRole, locked: Bool) {
        let roleChanged = role != lastSyncRole
        let lockedNow = role == .follower && locked
        let becameLocked = lockedNow && !syncFollowerLocked
        lastSyncRole = role
        syncFollowerLocked = lockedNow
        if roleChanged || becameLocked {
            clearHeldInputState()
        }
    }

    private func clearHeldInputState() {
        mappedKeys.removeAll()
        activeJoysticks.removeAll()
        activeJoystickKeys.removeAll()
        editingDrag = nil
        dragging = false
        secondFingerDown = false
        secondFinger = nil
        pendingKey = nil
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        marked = NSMutableAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    private var scriptPlaybackActive: Bool {
        scriptPlaybackBlocked || transport?.scriptPlaybackActive == true
    }

    private var inputBlocked: Bool {
        scriptPlaybackActive || syncFollowerLocked
    }

    fileprivate func releaseHeldInputs() {
        releaseMappedKeys()
        if secondFingerDown, let secondFinger { sendSecondFinger(secondFinger, down: false) }
        secondFingerDown = false
        secondFinger = nil
        if dragging, let lastTouch {
            transport?.send(["type": "touch", "x": lastTouch.0, "y": lastTouch.1, "down": false])
            dragging = false
        }
        for key in pressedKeys.values { transport?.send(["type": "key", "key": key, "down": false]) }
        for key in pressedModifiers { transport?.send(["type": "key", "key": key, "down": false]) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
    }
    override func resignFirstResponder() -> Bool {
        releaseHeldInputs()
        return super.resignFirstResponder()
    }
    override func flagsChanged(with event: NSEvent) {
        guard !inputBlocked else { return }
        for (flag, key) in [(NSEvent.ModifierFlags.shift, "Shift"), (.control, "Control"), (.option, "Alt")] {
            let down = event.modifierFlags.contains(flag)
            if down && !pressedModifiers.contains(key) {
                pressedModifiers.insert(key)
                transport?.send(["type": "key", "key": key, "down": true])
            } else if !down && pressedModifiers.remove(key) != nil {
                transport?.send(["type": "key", "key": key, "down": false])
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        guard !scriptPlaybackActive else { return }
        if syncFollowerLocked {
            transport?.showSyncLockedHint()
            return
        }
        if let mapping = transport?.mapping, mapping.editing {
            let lang = transport?.language ?? 1
            if event.keyCode == 53 {
                mapping.clearSelection()
                return
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                if let selected = mapping.selectedKey, mapping.remove(key: selected, rotation: rotation) {
                    transport?.onStatus?(t("已删除键位 ", "Removed ", lang) + MappingKey.displayLabel(selected))
                } else if let idx = mapping.selectedJoystickIndex, mapping.removeJoystick(at: idx) {
                    transport?.onStatus?(t("已删除摇杆", "Removed joystick", lang))
                }
                return
            }
            if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
                if mapping.pending || mapping.selectedKey != nil {
                    if let key = MappingKey.normalize(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers),
                       mapping.assign(key) {
                        transport?.onStatus?(t("已绑定 ", "Bound ", lang) + MappingKey.displayLabel(key))
                    } else {
                        transport?.onStatus?(t("请使用字母、数字、方向键或常用按键", "Use a letter, digit, arrow, or standard key", lang))
                    }
                }
                return
            }
        }
        if let mapping = transport?.mapping, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            if mappedKeys[event.keyCode] != nil || activeJoystickKeys[event.keyCode] != nil { return }
            if mapping.enabled,
               let key = MappingKey.normalize(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers) {
                if let binding = mapping.scheme.bindings.first(where: { $0.key == key && $0.rotation == rotation }) {
                    guard let id = nextTouchID() else { return }
                    mappedKeys[event.keyCode] = (id, binding.x, binding.y)
                    transport?.noteInput()
                    transport?.send(["type": "mapped_touch", "id": id, "x": binding.x, "y": binding.y, "down": true])
                    return
                }
                for (index, joystick) in mapping.scheme.joysticks.enumerated() where joystick.rotation == rotation {
                    guard let direction = joystick.direction(for: key) else { continue }
                    handleJoystickKeyDown(keyCode: event.keyCode, index: index, joystick: joystick, direction: direction)
                    return
                }
            }
        }
        if event.isARepeat && pressedKeys[event.keyCode] != nil { return }
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v": transport?.paste(); return
            case "c": transport?.copy(cut: false); return
            case "x": transport?.copy(cut: true); return
            case "a": transport?.send(["type": "select_all"]); return
            default: break
            }
        }
        let specials: [UInt16: String] = [36: "Enter", 48: "Tab", 51: "Backspace", 53: "Escape", 117: "Delete", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp"]
        if let key = specials[event.keyCode], !hasMarkedText() {
            pressedKeys[event.keyCode] = key
            transport?.noteInput()
            transport?.send(["type": "key", "key": key, "down": true])
            return
        }
        if !event.isARepeat, let value = event.charactersIgnoringModifiers, value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first, scalar.isASCII, !CharacterSet.controlCharacters.contains(scalar) {
            pendingKey = (event.keyCode, value.lowercased())
        }
        interpretKeyEvents([event])
        pendingKey = nil
    }
    private func handleJoystickKeyDown(keyCode: UInt16, index: Int, joystick: JoystickBinding, direction: JoystickDirection) {
        if var state = activeJoysticks[index] {
            state.held.insert(direction)
            let target = joystick.target(for: state.held, aspectWidthOverHeight: imageAspect)
            state.x = target.x
            state.y = target.y
            activeJoysticks[index] = state
            activeJoystickKeys[keyCode] = (index, direction)
            transport?.noteInput()
            transport?.send(["type": "mapped_touch", "id": state.id, "x": target.x, "y": target.y, "down": true])
            return
        }
        guard let id = nextTouchID() else { return }
        let held: Set<JoystickDirection> = [direction]
        let target = joystick.target(for: held, aspectWidthOverHeight: imageAspect)
        activeJoysticks[index] = (id, target.x, target.y, held)
        activeJoystickKeys[keyCode] = (index, direction)
        transport?.noteInput()
        // Touch down at center first so dynamic/floating joysticks anchor cleanly.
        transport?.send(["type": "mapped_touch", "id": id, "x": joystick.x, "y": joystick.y, "down": true])
        if target.x != joystick.x || target.y != joystick.y {
            transport?.send(["type": "mapped_touch", "id": id, "x": target.x, "y": target.y, "down": true])
        }
    }
    private func handleJoystickKeyUp(keyCode: UInt16) -> Bool {
        guard let entry = activeJoystickKeys.removeValue(forKey: keyCode) else { return false }
        guard var state = activeJoysticks[entry.index] else { return true }
        state.held.remove(entry.direction)
        if state.held.isEmpty {
            activeJoysticks.removeValue(forKey: entry.index)
            transport?.send(["type": "mapped_touch", "id": state.id, "x": state.x, "y": state.y, "down": false])
        } else if let mapping = transport?.mapping, mapping.scheme.joysticks.indices.contains(entry.index) {
            let joystick = mapping.scheme.joysticks[entry.index]
            let target = joystick.target(for: state.held, aspectWidthOverHeight: imageAspect)
            state.x = target.x
            state.y = target.y
            activeJoysticks[entry.index] = state
            transport?.send(["type": "mapped_touch", "id": state.id, "x": target.x, "y": target.y, "down": true])
        }
        return true
    }
    override func keyUp(with event: NSEvent) {
        if inputBlocked {
            _ = mappedKeys.removeValue(forKey: event.keyCode)
            _ = activeJoystickKeys.removeValue(forKey: event.keyCode)
            _ = pressedKeys.removeValue(forKey: event.keyCode)
            return
        }
        if let value = mappedKeys.removeValue(forKey: event.keyCode) {
            transport?.send(["type": "mapped_touch", "id": value.id, "x": value.x, "y": value.y, "down": false])
            return
        }
        if handleJoystickKeyUp(keyCode: event.keyCode) { return }
        if let key = pressedKeys.removeValue(forKey: event.keyCode) { transport?.send(["type": "key", "key": key, "down": false]) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !inputBlocked else {
            marked = NSMutableAttributedString(string: "")
            markedSelection = NSRange(location: 0, length: 0)
            needsDisplay = true
            return
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        marked = NSMutableAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
        if !wasComposing, let pendingKey, text.unicodeScalars.count == 1, text.unicodeScalars.first?.isASCII == true {
            pressedKeys[pendingKey.0] = pendingKey.1
            transport?.send(["type": "key", "key": pendingKey.1, "down": true])
        } else if !text.isEmpty {
            transport?.send(["type": "text", "text": text])
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !inputBlocked else { return }
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let markedFont = WbFontResolver.nsFont(family: WbType.body.family, weight: .regular, size: WbType.title.size)
        marked = NSMutableAttributedString(string: value, attributes: [.foregroundColor: NSColor(WbColor.textPrimary), .font: markedFont])
        markedSelection = selectedRange
        needsDisplay = true
    }
    func unmarkText() { marked = NSMutableAttributedString(string: ""); needsDisplay = true }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.foregroundColor, .font] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = NSRect(x: 12, y: max(12, bounds.height - 46), width: 1, height: 24)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) { }
}

struct PlayerView: NSViewRepresentable {
    let transport: PlayerTransport
    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.transport = transport
        transport.mapping.onChange = { [weak view, weak transport] in
            guard let view else { return }
            if let mapping = transport?.mapping, !mapping.enabled || mapping.editing { view.releaseHeldInputs() }
            view.needsDisplay = true
        }
        transport.onFrame = { [weak view] image, rotation in view?.present(image, rotation: rotation) }
        return view
    }
    func updateNSView(_ view: ScreenView, context: Context) {
        view.setScriptPlaybackBlocked(transport.scriptPlaybackActive)
        view.setSyncState(role: transport.syncRole, locked: transport.syncFollowerLocked)
    }
}
