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

/// Real AppKit toolbar: native title-bar spacing, overflow and customization.
/// Search focus is owned here; a pending request can never steal it from an
/// overlay, because the condition is checked again on the main-queue turn.
final class CenterToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let searchID = NSToolbarItem.Identifier("jidr.search")
    private let model: CenterModel
    private weak var window: NSWindow?
    let searchField = NSSearchField()
    private var searchWidthConstraint: NSLayoutConstraint?
    private var subscriptions = Set<AnyCancellable>()
    private var focusRequest = 0
    private let toolbar = NSToolbar(identifier: "jidr.center")
    private let viewSwitch = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private var showingEmptyLibrary: Bool?
    private var populatedConfiguration: [NSToolbarItem.Identifier]?

    init(model: CenterModel, window: NSWindow) {
        self.model = model
        self.window = window
        model.centerWindow = window
        super.init()
        viewSwitch.target = self
        viewSwitch.action = #selector(viewChanged)
        viewSwitch.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 0)
        viewSwitch.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 1)
        viewSwitch.setToolTip(model.text("网格视图", "Grid view"), forSegment: 0)
        viewSwitch.setToolTip(model.text("列表视图", "List view"), forSegment: 1)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.identifier = NSUserInterfaceItemIdentifier("device-search")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(WbColor.surface)
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &subscriptions)
        update()
    }

    var backgroundEnabled: Bool { !model.isEmptyDeviceLibrary && !model.paletteOpen && model.sheet == nil }
    private func update() {
        let empty = model.isEmptyDeviceLibrary
        if showingEmptyLibrary != empty {
            if empty, showingEmptyLibrary == false {
                populatedConfiguration = toolbar.items.map(\.itemIdentifier)
            }
            showingEmptyLibrary = empty
            if empty, !model.deviceQuery.isEmpty { model.deviceQuery = "" }
            let identifiers = (empty ? emptyItems : (populatedConfiguration ?? populatedItems))
                .filter { $0.rawValue != "jidr.details" }
            if empty, window?.firstResponder === searchField.currentEditor() {
                window?.makeFirstResponder(nil)
            }
            while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
            for (index, identifier) in identifiers.enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
            toolbar.allowsUserCustomization = !empty
        }
        window?.appearance = model.windowAppearance
        window?.title = model.text("Jidr 设备中心", "Jidr Device Center")
        searchField.placeholderString = model.text("搜索设备", "Search devices")
        searchField.setAccessibilityLabel(searchField.placeholderString)
        searchField.isEnabled = backgroundEnabled
        viewSwitch.selectedSegment = model.gridView ? 0 : 1
        viewSwitch.isEnabled = backgroundEnabled
        if searchField.stringValue != model.deviceQuery { searchField.stringValue = model.deviceQuery }
        if focusRequest != model.searchFocusRequest {
            focusRequest = model.searchFocusRequest
            if backgroundEnabled { window?.makeFirstResponder(searchField) }
        }
        for item in toolbar.items {
            if item.itemIdentifier.rawValue == "jidr.view" { continue }
            if item.itemIdentifier.rawValue == "jidr.new", let button = item.view as? NSButton {
                button.title = model.text("新建手机", "New phone")
                button.isEnabled = model.sheet == nil
                continue
            }
            guard item.itemIdentifier != Self.searchID else {
                item.label = model.text("搜索设备", "Search devices")
                continue
            }
            configure(item)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchID, .init("jidr.new"), .init("jidr.view"), .init("jidr.palette"), .init("jidr.tasks"),
         .init("jidr.refresh"), .init("jidr.settings"), .flexibleSpace, .space]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        model.isEmptyDeviceLibrary ? emptyItems : populatedItems
    }
    private var emptyItems: [NSToolbarItem.Identifier] {
        [.init("jidr.new"), .flexibleSpace, .init("jidr.tasks"), .init("jidr.settings")]
    }
    private var populatedItems: [NSToolbarItem.Identifier] {
        [.init("jidr.new"), .flexibleSpace, Self.searchID, .init("jidr.view"), .init("jidr.settings")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.searchID {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            item.preferredWidthForSearchField = 200
            if searchWidthConstraint == nil {
                let width = searchField.widthAnchor.constraint(equalToConstant: 200)
                width.isActive = true
                searchWidthConstraint = width
            }
            item.label = model.text("搜索设备", "Search devices")
            item.visibilityPriority = .high
            return item
        }
        if identifier.rawValue == "jidr.view" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = viewSwitch
            item.label = model.text("视图", "View")
            item.paletteLabel = item.label
            return item
        }
        if identifier.rawValue == "jidr.new" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            let button = NSButton(title: model.text("新建手机", "New phone"), target: self, action: #selector(newDevice))
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.toolTip = model.text("新建设备", "New device")
            item.view = button
            item.label = model.text("新建手机", "New phone")
            item.paletteLabel = item.label
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        configure(item)
        return item
    }
    private func configure(_ item: NSToolbarItem) {
        let title: String
        let symbol: String
        switch item.itemIdentifier.rawValue {
        case "jidr.new": title = model.text("新建设备", "New device"); symbol = WbIcon.plus; item.action = #selector(newDevice)
        case "jidr.palette": title = model.text("命令面板", "Command palette"); symbol = WbIcon.command; item.action = #selector(palette)
        case "jidr.tasks": title = model.text("后台任务", "Background tasks"); symbol = WbIcon.tasks; item.action = #selector(tasks)
        case "jidr.refresh": title = model.text("刷新设备", "Refresh devices"); symbol = WbIcon.refresh; item.action = #selector(refresh)
        case "jidr.settings": title = model.text("设置", "Settings"); symbol = WbIcon.settings; item.action = #selector(settings)
        default: title = model.detailsVisible ? model.text("隐藏详情", "Hide details") : model.text("显示详情", "Show details"); symbol = WbIcon.hideDetails; item.action = #selector(details)
        }
        item.label = title
        item.paletteLabel = title
        item.toolTip = item.itemIdentifier.rawValue == "jidr.palette" ? model.text("搜索命令 ⌘K", "Search commands ⌘K") : title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.isEnabled = model.sheet == nil
        item.autovalidates = false
    }
    @objc private func searchChanged() { if backgroundEnabled { model.deviceQuery = searchField.stringValue } }
    @objc private func viewChanged() { model.gridView = viewSwitch.selectedSegment == 0; model.keyboardDevice = nil }
    func controlTextDidChange(_ notification: Notification) { searchChanged() }
    @objc private func newDevice() { model.present(.newDevice) }
    @objc private func palette() { model.togglePalette() }
    @objc private func tasks() { model.openTasks() }
    @objc private func refresh() { model.refresh(); model.refreshJobs() }
    @objc private func details() { model.detailsVisible.toggle() }
    @objc private func settings() { model.present(.settings) }
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

/// Explicit native first-responder transfer after attachment, rather than a
/// SwiftUI FocusState competing with the background NSSearchField.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.identifier = .init("palette-search")
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
    }
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let owner = window else { return }
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, let owner, self.window === owner else { return }
                if owner.firstResponder !== self && owner.firstResponder !== self.currentEditor() {
                    owner.makeFirstResponder(self)
                }
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
    }
}
