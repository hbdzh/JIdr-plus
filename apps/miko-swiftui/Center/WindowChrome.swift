// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// The onboarding window uses native Liquid Glass; older macOS uses the
/// system's behind-window material instead.
struct CenterOnboardingGlass: NSViewRepresentable {
    var identifier = "onboarding-glass"
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = NSView()
            glass.setAccessibilityIdentifier(identifier)
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.setAccessibilityIdentifier(identifier)
        return material
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Shared by every hosting root, including independent auxiliary windows.
extension CenterModel {
    var colorScheme: ColorScheme? { appearance == 1 ? .light : appearance == 2 ? .dark : nil }
    var windowAppearance: NSAppearance? {
        appearance == 0 ? nil : NSAppearance(named: appearance == 2 ? .darkAqua : .aqua)
    }
}

/// A retained, nonmodal settings window keeps both the current pane and edits
/// when closed. Cmd+, always raises this one instance.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let model: CenterModel
    private var subscriptions = Set<AnyCancellable>()
    private let toolbar = NSToolbar(identifier: "miko.preferences")
    private var contentHeight: CGFloat?
    private var pendingResize = false
    private var screenObservers: [NSObjectProtocol] = []
    private var titles: [String] {
        [model.text("通用", "General"), model.text("设备策略", "Device policies"),
         model.text("数据与工具", "Data & tools"), model.text("智能体", "Agents"),
         model.text("高级", "Advanced"), model.text("关于", "About")]
    }
    private let symbols = ["gearshape", "iphone", "externaldrive", "sparkles", "slider.horizontal.3", "info.circle"]
    init(model: CenterModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        super.init(window: window)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // Keep the glass behind the toolbar, and constrain scrolling content
        // below it so that it cannot overlap the toolbar controls.
        let container = NSView()
        window.contentView = container
        let backdrop = NSHostingView(rootView: ZStack {
            CenterOnboardingGlass(identifier: "settings-glass")
            Color(nsColor: .windowBackgroundColor).opacity(0.5)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true))
        let content = GlassPanelHostingView(rootView: SettingsView(model: model, glassBackground: true, onContentHeightChange: { [weak self] category, height in
            guard let self, category == self.model.settingsCategory else { return }
            self.contentHeight = height
            self.scheduleResize()
        }, onClose: { [weak self] in self?.close() }))
        for view in [backdrop, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            content.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true
        } else {
            content.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        }
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateChrome() }
        }.store(in: &subscriptions)
        for (name, object) in [(NSWindow.didChangeScreenNotification, window as Any?),
                               (NSApplication.didChangeScreenParametersNotification, nil)] {
            screenObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.scheduleResize()
            })
        }
        updateChrome()
        window.center()
        resizeToContent()
    }
    required init?(coder: NSCoder) { nil }
    deinit { screenObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    // SwiftUI reports geometry during a layout pass. Resizing the NSWindow in
    // that callback can leave AppKit's window surface and hit testing out of
    // sync. Coalesce updates and resize after the current layout has finished.
    private func scheduleResize() {
        guard !pendingResize else { return }
        pendingResize = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingResize = false
            self.resizeToContent()
        }
    }

    private func resizeToContent() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let limit = screen.frame.size
        let available = screen.visibleFrame
        let width = min(700, limit.width * 0.7, available.width)
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let height = min((contentHeight ?? 340) + chromeHeight, limit.height * 0.7, available.height)
        let old = window.frame
        let x = min(max(old.minX, available.minX), available.maxX - width)
        let y = min(max(old.maxY - height, available.minY), available.maxY - height)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if abs(old.width - width) > 0.5 || abs(old.height - height) > 0.5 || abs(old.minX - x) > 0.5 || abs(old.minY - y) > 0.5 {
            window.setFrame(frame, display: true)
        }
    }
    private func updateChrome() {
        let selected = min(5, max(0, model.settingsCategory))
        window?.title = titles[selected]
        if window?.appearance?.name != model.windowAppearance?.name { window?.appearance = model.windowAppearance }
        toolbar.selectedItemIdentifier = .init("miko.preferences.\(selected)")
        for item in toolbar.items {
            item.label = titles[item.tag]
            item.paletteLabel = titles[item.tag]
            item.image = NSImage(systemSymbolName: symbols[item.tag], accessibilityDescription: titles[item.tag])
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (0..<6).map { .init("miko.preferences.\($0)") }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = Int(id.rawValue.split(separator: ".").last ?? ""), (0..<6).contains(index) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.tag = index; item.label = titles[index]; item.paletteLabel = titles[index]
        item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: titles[index])
        item.target = self; item.action = #selector(selectPane(_:))
        return item
    }
    @objc private func selectPane(_ sender: NSToolbarItem) { model.settingsCategory = sender.tag }
}

/// Native title-bar actions for the library. Device search and its focus
/// requests belong to LibrarySearchField in the persistent sidebar.
final class CenterToolbarController: NSObject, NSToolbarDelegate {
    private let model: CenterModel
    private weak var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private let toolbar = NSToolbar(identifier: "miko.library")
    private let legacyOnboardingToolbar = NSToolbar(identifier: "miko.onboarding.legacy")
    private let useItemHiding: Bool
    private let normalBackground: NSColor
    private let normalOpaque: Bool
    private var toolbarObserver: NSKeyValueObservation?

    init(model: CenterModel, window: NSWindow, forceLegacyToolbar: Bool = false) {
        self.model = model
        self.window = window
        if #available(macOS 15.0, *) { self.useItemHiding = !forceLegacyToolbar }
        else { self.useItemHiding = false }
        self.normalBackground = window.backgroundColor
        self.normalOpaque = window.isOpaque
        model.centerWindow = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.isVisible = true
        legacyOnboardingToolbar.delegate = self
        legacyOnboardingToolbar.displayMode = .iconOnly
        legacyOnboardingToolbar.allowsUserCustomization = false
        legacyOnboardingToolbar.isVisible = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        update()
        // NavigationSplitView may install its own toolbar after attaching.
        toolbarObserver = window.observe(\.toolbar, options: [.new]) { [weak self] observed, _ in
            guard let self, observed.toolbar !== self.desiredToolbar else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.toolbar !== self.desiredToolbar else { return }
                window.toolbar = self.desiredToolbar
            }
        }
    }
    private var desiredToolbar: NSToolbar {
        !useItemHiding && model.isEmptyDeviceLibrary ? legacyOnboardingToolbar : toolbar
    }
    private func update() {
        window?.appearance = model.windowAppearance
        window?.title = model.text("miko 模拟器 · 设备中心", "miko simulator · Device Center")
        if let window, window.toolbar !== desiredToolbar { window.toolbar = desiredToolbar }
        if let window {
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = !model.onboardingInstallForegroundRequired
            window.isOpaque = model.isEmptyDeviceLibrary ? false : normalOpaque
            window.backgroundColor = model.isEmptyDeviceLibrary ? .clear : normalBackground
        }
        if #available(macOS 15.0, *), useItemHiding {
            toolbar.isVisible = true
            for item in toolbar.items {
                if item.itemIdentifier != .flexibleSpace { item.isHidden = model.isEmptyDeviceLibrary }
                configure(item)
            }
        } else {
            toolbar.isVisible = true
            for item in toolbar.items { configure(item) }
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar === legacyOnboardingToolbar { return [] }
        return [.init("miko.sidebar"), .flexibleSpace, .init("miko.images"), .init("miko.palette"), .init("miko.tasks"), .init("miko.refresh")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "miko.sidebar" {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            button.isBordered = false
            button.imagePosition = .imageOnly
            item.view = button
        }
        configure(item)
        return item
    }
    private func configure(_ item: NSToolbarItem) {
        let title: String
        let symbol: String
        switch item.itemIdentifier.rawValue {
        case "miko.sidebar":
            title = model.sidebarVisible ? model.text("隐藏侧边栏", "Hide sidebar") : model.text("显示侧边栏", "Show sidebar")
            symbol = "sidebar.leading"; item.action = #selector(toggleSidebar)
        case "miko.images":
            title = model.text("管理系统镜像", "Manage system images"); symbol = "square.3.layers.3d"; item.action = #selector(images)
        case "miko.palette":
            title = model.text("命令面板", "Command palette"); symbol = WbIcon.command; item.action = #selector(palette)
        case "miko.tasks":
            title = model.text("后台任务", "Background tasks"); symbol = WbIcon.tasks; item.action = #selector(tasks)
        case "miko.refresh":
            title = model.text("刷新设备", "Refresh devices"); symbol = WbIcon.refresh; item.action = #selector(refresh)
        default: return
        }
        item.label = title; item.toolTip = title
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.image = item.itemIdentifier.rawValue == "miko.sidebar"
            ? image?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) : image
        item.target = self; item.autovalidates = false
        // Keep the toolbar visually stable while a device panel is open;
        // actions below still reject input until it closes.
        item.isEnabled = !model.isEmptyDeviceLibrary
        if let button = item.view as? NSButton {
            button.image = item.image
            button.target = self
            button.action = item.action
            button.isEnabled = item.isEnabled
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }
    }
    @objc private func toggleSidebar() {
        guard model.sheet == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.sidebarVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { model.sidebarVisible.toggle() }
        }
    }
    @objc private func palette() { if model.sheet == nil { model.togglePalette() } }
    @objc private func images() { if model.sheet == nil { model.present(.imageManagement) } }
    @objc private func tasks() { if model.sheet == nil { model.openTasks() } }
    @objc private func refresh() { if model.sheet == nil { model.refresh(); model.refreshJobs() } }
}

/// Installs chrome for production and hosted UI tests through the same path.
struct CenterWindowChrome: NSViewRepresentable {
    let model: CenterModel
    func makeNSView(context: Context) -> Attachment { Attachment(model: model) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
        let model: CenterModel
        var chrome: CenterToolbarController?
        init(model: CenterModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.styleMask.contains(.titled), chrome == nil {
                chrome = CenterToolbarController(model: model, window: window)
            }
        }
    }
}
