// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct DeviceToolNavigationItem: Equatable {
    let section: Int?
    let title: String
    var symbol: String? = nil
}

/// Native table selection, type-to-select and keyboard navigation, with the
/// compact integrated layout. Selection drawing/colors belong to AppKit.
struct CompactDeviceToolsSidebar: NSViewRepresentable {
    var items: [DeviceToolNavigationItem]
    @Binding var selection: Int
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let table = CompactDeviceToolsTableView()
        let column = NSTableColumn(identifier: .init("device-tool"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.floatsGroupRows = false
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityIdentifier("device-tools-navigation")
        table.setAccessibilityLabel(label)
        scroll.documentView = table
        context.coordinator.update(self, table: table)
        DispatchQueue.main.async { [weak table] in
            guard let table, table.selectedRow >= 0, (table.enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else { return }
            table.scrollRowToVisible(table.selectedRow)
        }
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // A sidebar is a viewport, not the intrinsic size of its full document.
        CGSize(width: proposal.width ?? 168, height: proposal.height ?? 0)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? CompactDeviceToolsTableView else { return }
        context.coordinator.update(self, table: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: CompactDeviceToolsSidebar
        private var currentItems: [DeviceToolNavigationItem] = []
        private var updating = false
        init(_ parent: CompactDeviceToolsSidebar) { self.parent = parent }
        func update(_ parent: CompactDeviceToolsSidebar, table: NSTableView) {
            self.parent = parent
            updating = true
            if currentItems != parent.items {
                currentItems = parent.items
                table.reloadData()
            }
            table.setAccessibilityLabel(parent.label)
            if let row = currentItems.firstIndex(where: { $0.section == parent.selection }), table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if (table.enclosingScrollView?.contentView.bounds.height ?? 0) > 0 { table.scrollRowToVisible(row) }
            }
            refreshCells(table)
            updating = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { currentItems.count }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { currentItems[row].section == nil }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { currentItems[row].section != nil }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            currentItems[row].section == nil ? (row == 0 ? 22 : 28) : 32
        }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            currentItems[row].section == nil ? nil : currentItems[row].title
        }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { currentItems[row].title }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = currentItems[row]
            let identifier = NSUserInterfaceItemIdentifier(item.section == nil ? "tool-heading" : "tool-item")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CompactDeviceToolCell)
                ?? CompactDeviceToolCell(heading: item.section == nil)
            cell.identifier = identifier
            cell.configure(item, selected: row == tableView.selectedRow)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NSTableRowView() }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            if !updating, currentItems.indices.contains(table.selectedRow), let section = currentItems[table.selectedRow].section {
                parent.selection = section
            }
            refreshCells(table)
        }
        private func refreshCells(_ table: NSTableView) {
            for row in currentItems.indices {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CompactDeviceToolCell)?
                    .configure(currentItems[row], selected: row == table.selectedRow)
                table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }
    }
}

final class CompactDeviceToolsTableView: NSTableView {}

private final class CompactDeviceToolCell: NSTableCellView {
    private let heading: Bool
    private var current = false
    init(heading: Bool) {
        self.heading = heading
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        if heading {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
            ])
        } else {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }
    required init?(coder: NSCoder) { nil }
    // Let standard row emphasis propagate to both native cells. System
    // selection colors then remain correct for accent changes and key focus.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }
    func configure(_ item: DeviceToolNavigationItem, selected: Bool) {
        current = selected
        textField?.stringValue = item.title
        textField?.font = .systemFont(ofSize: heading ? 11 : 13, weight: heading || selected ? .medium : .regular)
        if let symbol = item.symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            image?.isTemplate = true
            imageView?.image = image
        }
        imageView?.contentTintColor = nil
        toolTip = item.title
        applyColors()
    }
    private func applyColors() {
        textField?.textColor = heading ? .secondaryLabelColor
            : (backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor)
        // No fixed palette or forced normal background: native template symbols
        // follow the same emphasized/inactive state as their system row.
        imageView?.contentTintColor = nil
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }
}
