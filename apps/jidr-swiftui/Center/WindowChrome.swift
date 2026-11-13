// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

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
    private let toolbar = NSToolbar(identifier: "jidr.preferences")
    private var lastCategory: Int?
    private var titles: [String] {
        [model.text("通用", "General"), model.text("设备策略", "Device policies"),
         model.text("数据与工具", "Data & tools"), model.text("高级", "Advanced"), model.text("关于", "About")]
    }
    private let symbols = ["gearshape", "iphone", "externaldrive", "slider.horizontal.3", "info.circle"]
    init(model: CenterModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.contentView = NSHostingView(rootView: SettingsView(model: model, onClose: { [weak self] in self?.close() }))
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateChrome() }
        }.store(in: &subscriptions)
        updateChrome()
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    private func updateChrome() {
        let selected = min(4, max(0, model.settingsCategory))
        if lastCategory != selected, let window {
            let heights: [CGFloat] = [360, 460, 500, 400, 340]
            let oldFrame = window.frame
            let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 700, height: heights[selected]))
            window.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - frame.height, width: frame.width, height: frame.height), display: true)
            lastCategory = selected
        }
        window?.title = titles[selected]
        window?.appearance = model.windowAppearance
        toolbar.selectedItemIdentifier = .init("jidr.preferences.\(selected)")
        for item in toolbar.items {
            item.label = titles[item.tag]
            item.paletteLabel = titles[item.tag]
            item.image = NSImage(systemSymbolName: symbols[item.tag], accessibilityDescription: titles[item.tag])
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (0..<5).map { .init("jidr.preferences.\($0)") }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = Int(id.rawValue.split(separator: ".").last ?? ""), (0..<5).contains(index) else { return nil }
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
    private let toolbar = NSToolbar(identifier: "jidr.library")

    init(model: CenterModel, window: NSWindow) {
        self.model = model
        self.window = window
        model.centerWindow = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
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
    }
    private func update() {
        window?.appearance = model.windowAppearance
        window?.title = model.text("Jidr 设备中心", "Jidr Device Center")
        for item in toolbar.items { configure(item) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("jidr.palette"), .init("jidr.tasks"), .init("jidr.refresh")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        configure(item)
        return item
    }
    private func configure(_ item: NSToolbarItem) {
        let title: String
        let symbol: String
        switch item.itemIdentifier.rawValue {
        case "jidr.palette":
            title = model.text("命令面板", "Command palette"); symbol = WbIcon.command; item.action = #selector(palette)
        case "jidr.tasks":
            title = model.text("后台任务", "Background tasks"); symbol = WbIcon.tasks; item.action = #selector(tasks)
        case "jidr.refresh":
            title = model.text("刷新设备", "Refresh devices"); symbol = WbIcon.refresh; item.action = #selector(refresh)
        default: return
        }
        item.label = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self; item.autovalidates = false; item.isEnabled = model.sheet == nil
    }
    @objc private func palette() { model.togglePalette() }
    @objc private func tasks() { model.openTasks() }
    @objc private func refresh() { model.refresh(); model.refreshJobs() }
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
            if let window, chrome == nil {
                chrome = CenterToolbarController(model: model, window: window)
            }
        }
    }
}
