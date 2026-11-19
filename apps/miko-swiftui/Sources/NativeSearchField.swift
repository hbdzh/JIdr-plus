// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// Shared search appearance and editing semantics for every search/filter UI.
/// AppKit owns the rounded bezel, editor geometry, cancel button and focus ring.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var focusRequest = 0
    var canFocus: () -> Bool = { true }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NativeSearchContainer {
        let view = NativeSearchContainer()
        view.field.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: NativeSearchContainer, context: Context) {
        context.coordinator.parent = self
        let field = view.field
        field.identifier = .init(identifier)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.isEnabled = context.environment.isEnabled
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if field.isEnabled && canFocus() {
                DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                    guard let field, let coordinator, field.isEnabled,
                          coordinator.parent.canFocus() else { return }
                    field.window?.makeFirstResponder(field)
                }
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var focusRequest: Int
        init(_ parent: NativeSearchField) { self.parent = parent; focusRequest = parent.focusRequest }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}

final class NativeSearchContainer: NSView {
    let field = NSSearchField()
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        if #available(macOS 14.0, *) { clipsToBounds = false }
        if #available(macOS 26.0, *) {
            // Keep AppKit's rounded search geometry and focus mask while letting
            // the system glass underneath provide the translucent bezel.
            field.cell = GlassSearchCell()
            field.isEditable = true
            field.isSelectable = true
        }
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        // Borderless mode breaks the native editor insets and rounded focus mask.
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.drawsBackground = !Self.supportsGlass
        field.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 15
            glass.contentView = field
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor),
                field.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }
    required init?(coder: NSCoder) { nil }

    private static var supportsGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// AppKit still draws the search contents and focus ring; only its opaque bezel
/// is omitted, so the native glass view can show through.
private final class GlassSearchCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}
