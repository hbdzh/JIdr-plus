// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Glass panels use the system overlay scroller so the legacy scroller's
/// persistent track does not form a second dark strip over the material.
/// SwiftUI can replace scroll views as content changes, so reconcile on layout.
final class GlassPanelHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        func update(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.scrollerStyle != .overlay {
                scroll.scrollerStyle = .overlay
            }
            view.subviews.forEach(update)
        }
        subviews.forEach(update)
    }
}

/// Both lightweight surfaces use the same native frame, border and shadow.
/// SwiftUI draws content only, avoiding a second outline on top of AppKit's rim.
class LightweightPanel: NSPanel {
    private var transitionGeneration = 0
    private(set) var isDismissing = false
    /// Override only in tests; production follows the system accessibility setting.
    var reduceMotionOverride: Bool?
    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(kind)?.isHidden = true }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        // The full-size hosting view includes the transparent title-bar area.
        setFrame(NSRect(origin: .zero, size: size), display: false)
    }
    required init?(coder: NSCoder) { nil }

    private var restingFrame: NSRect?
    private let travelDistance: CGFloat = 14

    /// Controllers set the resting location before presentation; keeping it
    /// separate from the animated frame also handles a quick reopen.
    func preparePosition(_ origin: NSPoint) {
        restingFrame = NSRect(origin: origin, size: frame.size)
    }

    func showAnimated() {
        transitionGeneration += 1
        isDismissing = false
        let fresh = !isVisible || alphaValue < 0.05
        let target = restingFrame ?? frame
        restingFrame = target
        ignoresMouseEvents = false
        if !isVisible { alphaValue = reduceMotion ? 1 : 0 }
        if reduceMotion {
            setFrame(target, display: true)
            alphaValue = 1
            makeKeyAndOrderFront(nil)
            return
        }
        if fresh {
            var start = target
            start.origin.y += travelDistance
            setFrame(start, display: true)
        }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func hideAnimated(immediately: Bool = false, completion: (() -> Void)? = nil) {
        transitionGeneration += 1
        let generation = transitionGeneration
        isDismissing = true
        ignoresMouseEvents = true
        let finish = { [self] in
            guard generation == transitionGeneration else { return }
            // Leave the final frame transparent until the next presentation;
            // resetting it while ordering out can produce a visible flash.
            orderOut(nil)
            isDismissing = false
            completion?()
        }
        guard isVisible, !immediately, !reduceMotion else { finish(); return }
        var destination = frame
        destination.origin.y = (restingFrame?.origin.y ?? frame.origin.y) + travelDistance
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(destination, display: true)
            animator().alphaValue = 0
        } completionHandler: { finish() }
    }

}

struct LightweightPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

/// The device panels share the exact surface and transparent borderless
/// window used by the task and command panels.
struct DeviceSheetGlass: ViewModifier {
    var enabled = true
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(LightweightPanelSurface()) }
        else { content }
    }
}

final class DeviceSheetPanelController: NSWindowController, NSWindowDelegate {
    private weak var model: CenterModel?
    private var backgroundInputMonitor: Any?
    let kind: CenterSheet
    let deviceID: String?

    init(model: CenterModel, kind: CenterSheet, parent: NSWindow) {
        self.model = model
        self.kind = kind
        self.deviceID = model.selected
        let size: NSSize
        switch kind {
        case .newDevice: size = NSSize(width: 650, height: 580)
        case .snapshots: size = NSSize(width: 600, height: 560)
        case .imageManagement: size = NSSize(width: 700, height: 500)
        default: size = NSSize(width: 560, height: 620)
        }
        let panel = LightweightPanel(size: size)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        let close: (@escaping () -> Void) -> Void = { [weak model] completion in
            if let model { model.dismissDevicePanel(after: completion) } else { completion() }
        }
        let content: AnyView
        switch kind {
        case .newDevice:
            content = AnyView(NewDeviceView(model: model, startAtDeviceSetup: true, onPanelClose: close))
        case .imageManagement:
            content = AnyView(ImageManagementView(model: model, onPanelClose: close))
        case .snapshots:
            if let device = model.devices.first(where: { $0.id == model.selected }) {
                content = AnyView(SnapshotsView(model: model, device: device, onPanelClose: close))
            } else { content = AnyView(EmptyView()) }
        case .edit:
            if let details = model.details {
                content = AnyView(EditDeviceView(model: model, details: details, onPanelClose: close))
            } else { content = AnyView(EmptyView()) }
        default: content = AnyView(EmptyView())
        }
        let host = GlassPanelHostingView(rootView: content
            .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
            .preferredColorScheme(model.colorScheme))
        host.wantsLayer = true
        host.layer?.cornerRadius = 26
        host.layer?.masksToBounds = true
        panel.contentView = host
        panel.appearance = model.windowAppearance
        panel.preparePosition(NSPoint(x: parent.frame.midX - size.width / 2,
                                      y: parent.frame.midY - size.height / 2))
        panel.alphaValue = 0
        // The panel is modal to its parent, without disabling or rewrapping
        // the SwiftUI root (which changes its title-bar safe area).
        backgroundInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp
        ]) { [weak parent, weak panel] event in
            if let panel, event.window === panel {
                if panel.isDismissing { return nil }
                if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "w",
                   let escape = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                                 modifierFlags: [], timestamp: event.timestamp,
                                                 windowNumber: panel.windowNumber, context: nil,
                                                 characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53) {
                    // Route Cmd-W through the form's cancel action so a
                    // disabled cancel button cannot be bypassed while saving.
                    DispatchQueue.main.async { NSApp.sendEvent(escape) }
                    return nil
                }
            }
            guard let parent, event.window === parent else { return event }
            return nil
        }
        parent.addChildWindow(panel, ordered: .above)
        panel.showAnimated()
    }
    required init?(coder: NSCoder) { nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    func windowWillClose(_ notification: Notification) { model?.dismissDevicePanel() }
    deinit { if let backgroundInputMonitor { NSEvent.removeMonitor(backgroundInputMonitor) } }
    func dismissPanel(immediately: Bool = false, completion: @escaping () -> Void = {}) {
        guard let panel = window as? LightweightPanel else { completion(); return }
        panel.hideAnimated(immediately: immediately) { [self] in
            panel.parent?.removeChildWindow(panel)
            if let backgroundInputMonitor { NSEvent.removeMonitor(backgroundInputMonitor); self.backgroundInputMonitor = nil }
            completion()
        }
    }
}

struct PanelCloseButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                .foregroundStyle(WbColor.textSecondary).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

/// A transient progress panel: no title bar, traffic lights or independent
/// window controls. Dismissing it never cancels the underlying daemon jobs.
final class TaskPanelController: NSWindowController, NSWindowDelegate {
    private let model: CenterModel
    private var subscription: AnyCancellable?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    init(model: CenterModel) {
        self.model = model
        let panel = LightweightPanel(size: NSSize(width: 480, height: 260))
        super.init(window: panel)
        panel.delegate = self
        let host = GlassPanelHostingView(rootView: TaskCenterView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 26
        host.layer?.masksToBounds = true
        panel.contentView = host
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateChrome() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if (self.window as? LightweightPanel)?.isDismissing == true { return nil }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "w" { self.model.taskPanelDidClose(); return nil }
                return event
            }
            return self.model.handleShortcutEvent(event) ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.model.tasksOpen, event.window !== self.window { self.model.taskPanelDidClose() }
            return event
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.model.taskPanelDidClose()
        }
        updateChrome()
    }
    required init?(coder: NSCoder) { nil }
    override func showWindow(_ sender: Any?) {
        guard let panel = window else { return }
        updateChrome()
        let reference = model.centerWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        guard let lightweight = panel as? LightweightPanel else { return }
        lightweight.preparePosition(NSPoint(x: reference.midX - panel.frame.width / 2,
                                            y: reference.midY - panel.frame.height / 2))
        lightweight.showAnimated()
    }
    func dismissPanel(immediately: Bool = false, completion: @escaping () -> Void = {}) {
        guard let panel = window as? LightweightPanel else { completion(); return }
        panel.hideAnimated(immediately: immediately, completion: completion)
    }
    private func updateChrome() {
        guard let window else { return }
        guard (window as? LightweightPanel)?.isDismissing != true else { return }
        window.title = model.text("后台任务", "Background tasks")
        if window.appearance?.name != model.windowAppearance?.name { window.appearance = model.windowAppearance }
        let count = model.taskRows.count
        let height: CGFloat = count == 0 && model.quitReason == nil && model.jobsError == nil ? 260 : min(420, CGFloat(120 + max(count, 2) * 72))
        if window.frame.height != height {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.midY - height / 2, width: 480, height: height), display: true)
        }
    }
    func windowWillClose(_ notification: Notification) { model.taskPanelDidClose() }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}

/// A Spotlight-like search panel uses the native window shadow, with no grey
/// modal mask over the application. It dismisses when another window is used.
final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    private let model: CenterModel
    private var subscription: AnyCancellable?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    init(model: CenterModel) {
        self.model = model
        let panel = LightweightPanel(size: NSSize(width: 600, height: 450))
        super.init(window: panel)
        panel.delegate = self
        let host = GlassPanelHostingView(rootView: CommandPaletteView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 26
        host.layer?.masksToBounds = true
        panel.contentView = host
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, let window = self.window,
                      (window as? LightweightPanel)?.isDismissing != true else { return }
                if window.appearance?.name != self.model.windowAppearance?.name {
                    window.appearance = self.model.windowAppearance
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if (self.window as? LightweightPanel)?.isDismissing == true { return nil }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "w" { self.model.hidePalette(); return nil }
                return event
            }
            return self.model.handleShortcutEvent(event) ? nil : event
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.model.hidePalette()
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.model.paletteOpen, event.window !== self.window { self.model.hidePalette() }
            return event
        }
    }
    required init?(coder: NSCoder) { nil }
    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        let reference = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        (window as? LightweightPanel)?.preparePosition(NSPoint(x: reference.midX - window.frame.width / 2,
                                                                y: reference.maxY - window.frame.height - 100))
        window.appearance = model.windowAppearance
        window.title = model.text("命令搜索", "Command search")
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "palette-search" { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let content = window.contentView, let field = find(content) {
            // Clear synchronously before the first keystroke. A delayed selectAll
            // can select the first typed character and let the next replace it.
            field.stringValue = model.paletteQuery
            if let editor = field.currentEditor() as? NSTextView { editor.string = model.paletteQuery }
            window.initialFirstResponder = field
            (window as? LightweightPanel)?.showAnimated()
            if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
        } else { (window as? LightweightPanel)?.showAnimated() }
    }
    func dismissPanel(immediately: Bool = false, completion: @escaping () -> Void = {}) {
        guard let panel = window as? LightweightPanel else { completion(); return }
        panel.hideAnimated(immediately: immediately, completion: completion)
    }

    func windowWillClose(_ notification: Notification) { model.hidePalette() }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}
