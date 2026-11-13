// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// A native sidebar reserves enough width for a Device-settings-sized detail
/// form. Category selection never resizes the lightweight panel.
final class DeviceToolsNativePanel: LightweightPanel {
    init() {
        super.init(size: NSSize(width: 716, height: 500))
        styleMask.insert(.resizable)
        // AppKit rebuilds the frame controls when the style mask changes.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        collectionBehavior.insert(.fullScreenNone)
        contentMinSize = NSSize(width: 660, height: 460)
    }
    required init?(coder: NSCoder) { nil }
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else { return }
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
            return
        }
        close()
    }
}

/// Stable tool IDs shared by sidebar selection and dedicated Root entry.
final class DeviceToolsSelection: ObservableObject {
    @Published var section: Int
    init(section: Int) { self.section = section }
}

/// A retained, owner-attached utility panel. Unlike search, clicking outside
/// keeps drafts intact; explicit Close, Escape or Cmd+W dismisses it.
final class DeviceToolsPanelController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let selection: DeviceToolsSelection
    private let model: CenterModel
    private let deviceID: String
    private var subscription: AnyCancellable?
    private var keyMonitor: Any?
    private var ownerObserver: NSObjectProtocol?

    init(model: CenterModel, id: String, name: String, root: Bool) {
        self.model = model
        deviceID = id
        selection = DeviceToolsSelection(section: root ? 4 : 0)
        let panel = DeviceToolsNativePanel()
        super.init(window: panel)
        panel.delegate = self
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = NSHostingView(rootView: AdvancedToolsView(
            model: model, id: id, initialRoot: root, selection: selection,
            onClose: { [weak self] in self?.close() }))
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateChrome() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            let commandW = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w"
            if commandW { self.close(); return nil }
            return event
        }
        updateChrome()
    }
    required init?(coder: NSCoder) { nil }

    func present(relativeTo owner: NSWindow?, root: Bool = false, section: Int? = nil) {
        guard let panel = window else { return }
        if root { selection.section = 4 }
        if let section, (0...10).contains(section) { selection.section = section }
        let needsPlacement = !panel.isVisible || panel.parent !== owner
        if let old = panel.parent, old !== owner { old.removeChildWindow(panel) }
        if let owner, panel.parent !== owner { owner.addChildWindow(panel, ordered: .above) }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        if let owner {
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in self?.close() }
        }
        let reference = owner?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let screen = owner?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? reference
        if needsPlacement {
            let width = min(panel.frame.width, screen.width - 32)
            let height = min(panel.frame.height, screen.height - 32)
            let x = min(max(reference.midX - width / 2, screen.minX + 16), screen.maxX - width - 16)
            let y = min(max(reference.midY - height / 2, screen.minY + 16), screen.maxY - height - 16)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        updateChrome()
        panel.contentView?.layoutSubtreeIfNeeded()
        func sidebar(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { sidebar(in: $0) }.first
        }
        let list = panel.contentView.flatMap { sidebar(in: $0) }
        panel.initialFirstResponder = list
        panel.makeKeyAndOrderFront(nil)
        if !(panel.firstResponder is NSTextView), let list { panel.makeFirstResponder(list) }
    }
    private func updateChrome() {
        window?.appearance = model.windowAppearance
        let name = model.devices.first(where: { $0.id == deviceID })?.name ?? ""
        window?.title = model.text("设备工具 — \(name)", "Device tools — \(name)")
    }
    func windowWillClose(_ notification: Notification) {
        let keepAlive = self
        if let panel = window { panel.parent?.removeChildWindow(panel) }
        onClose?()
        DispatchQueue.main.async { _ = keepAlive }
    }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
    }
}

/// Shared non-scrolling groups for the device-tool page.
struct DeviceToolSection<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        DeviceToolPageGroup(content: content)
    }
}

/// Full-label actions wrap within one native form row at compact widths.
struct DeviceToolActions<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        DeviceToolActionsLayout { content() }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .buttonStyle(.bordered).controlSize(.regular)
    }
}

private struct DeviceToolActionsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = ActionFlowLayout.arrange(sizes, width: proposal.width ?? .greatestFiniteMagnitude, spacing: WbSpace.sm)
        return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = ActionFlowLayout.arrange(sizes, width: bounds.width, spacing: WbSpace.sm)
        for (subview, frame) in zip(subviews, result.frames) {
            let rowWidth = result.frames.filter { $0.minY == frame.minY }.map(\.maxX).max() ?? 0
            subview.place(at: CGPoint(x: bounds.minX + max(0, bounds.width - rowWidth) + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Used by the Root property editor within its section.
struct DeviceToolForm<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { Form(content: content).formStyle(.columns) }
}

/// A non-scrolling group of native controls. Only the containing detail page
/// owns scrolling, so its indicator stays on the far right of the page.
struct DeviceToolPageGroup<Content: View>: View {
    private let content: Content
    private let header: AnyView?
    private let footer: AnyView?
    init(@ViewBuilder content: () -> Content) {
        self.content = content(); header = nil; footer = nil
    }
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.content = content(); header = AnyView(Text(title)); footer = nil
    }
    init<Header: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); self.header = AnyView(header()); footer = nil
    }
    init<Footer: View>(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content(); header = nil; self.footer = AnyView(footer())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let header {
                header.font(.system(size: 13, weight: .medium)).foregroundStyle(WbColor.textPrimary)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(WbColor.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            if let footer {
                footer.font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explicit row alignment when native controls are used in a scrolling page
/// rather than inside Form's internal grid/scrolling layout.
struct DeviceToolFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
