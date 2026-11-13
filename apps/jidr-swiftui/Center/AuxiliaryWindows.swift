// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// Both lightweight surfaces use the same native frame, border and shadow.
/// SwiftUI draws content only, avoiding a second outline on top of AppKit's rim.
class LightweightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(kind)?.isHidden = true }
        backgroundColor = NSColor(WbColor.raised)
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        // The full-size hosting view includes the transparent title-bar area.
        setFrame(NSRect(origin: .zero, size: size), display: false)
    }
    required init?(coder: NSCoder) { nil }
}

struct LightweightPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(WbColor.raised).ignoresSafeArea(.container, edges: .top)
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
        panel.contentView = NSHostingView(rootView: TaskCenterView(model: model))
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateChrome() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
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
        panel.setFrameOrigin(NSPoint(x: reference.maxX - panel.frame.width - 24,
                                     y: reference.maxY - panel.frame.height - 80))
        panel.makeKeyAndOrderFront(sender)
    }
    private func updateChrome() {
        guard let window else { return }
        window.title = model.text("后台任务", "Background tasks")
        window.appearance = model.windowAppearance
        let count = model.taskRows.count
        let height: CGFloat = count == 0 && model.quitReason == nil && model.jobsError == nil ? 260 : min(420, CGFloat(120 + max(count, 2) * 72))
        if window.frame.height != height {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: 480, height: height), display: true)
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
        panel.contentView = NSHostingView(rootView: CommandPaletteView(model: model))
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.window?.appearance = self?.model.windowAppearance }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
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
        window.setFrameOrigin(NSPoint(x: reference.midX - window.frame.width / 2,
                                      y: reference.maxY - window.frame.height - 100))
        window.appearance = model.windowAppearance
        window.title = model.text("命令搜索", "Command search")
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> PaletteSearchField.Field? {
            if let field = view as? PaletteSearchField.Field { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        if let content = window.contentView, let field = find(content) {
            // Clear synchronously before the first keystroke. A delayed selectAll
            // can select the first typed character and let the next replace it.
            field.stringValue = model.paletteQuery
            if let editor = field.currentEditor() as? NSTextView { editor.string = model.paletteQuery }
            window.initialFirstResponder = field
            window.makeKeyAndOrderFront(nil)
            if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
                window.makeFirstResponder(field)
            }
        } else { window.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) { model.paletteOpen = false }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}
