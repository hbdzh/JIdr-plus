// SPDX-License-Identifier: GPL-3.0-only
// Search content hosted by PaletteWindowController. Native window chrome owns
// its shadow and focus; the catalog/filter/keyboard selection remain in the model.

import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: CenterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [PaletteEntry] { model.paletteFiltered }

    /// VoiceOver label for a row: title, then the subtitle that explains it.
    private func paletteRowLabel(_ entry: PaletteEntry) -> String {
        entry.subtitle.isEmpty ? entry.title : entry.title + "，" + entry.subtitle
    }
    private var visible: [PaletteEntry] { entries }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                PaletteSearchField(text: $model.paletteQuery,
                                   placeholder: model.text("搜索命令或设备…", "Search commands or devices…"))
                    .frame(height: 32)
            }
            .padding(.horizontal, 22)
            .frame(height: 68)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(WbColor.textSecondary)
                    Text(model.paletteEmptyText).font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    model.closeOverlay()
                                    model.runPaletteAction(entry.action)
                                } label: { PaletteRow(entry: entry, selected: index == model.paletteSelection) }
                                .buttonStyle(.plain).id(index)
                                .onHover { if $0 { model.paletteSelection = index } }
                                .accessibilityLabel(paletteRowLabel(entry))
                                .accessibilityHint(model.text("按 Return 运行", "Press Return to run"))
                                .help(entry.title)
                            }
                        }.padding(8)
                    }
                    .onChange(of: model.paletteSelection) { selection in
                        withAnimation(WbMotion.scroll.animation(reduceMotion: reduceMotion)) { proxy.scrollTo(selection) }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(LightweightPanelSurface())
        .onChange(of: entries.count) { count in
            model.paletteSelection = min(model.paletteSelection, max(0, count - 1))
        }
        .tint(WbColor.accent)
        .preferredColorScheme(model.colorScheme)
        .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool

    private var symbol: String {
        switch entry.action {
        case .openDevice: return "arrow.up.forward.app"
        case .startDevice: return WbIcon.play
        case .stopDevice: return WbIcon.stop
        case .restartDevice: return WbIcon.refresh
        case .editDevice: return WbIcon.settings
        case .deleteDevice: return WbIcon.trash
        case .snapshots: return WbIcon.camera
        case .folderSync: return "arrow.triangle.2.circlepath"
        case .advancedTools: return WbIcon.advancedTools
        case .rootTools: return WbIcon.rootTab
        case .installAPK: return WbIcon.installAPK
        case .sendFile: return "paperplane"
        case .screenshot: return WbIcon.camera
        case .record: return WbIcon.record
        case .newDevice: return WbIcon.plus
        case .setupSDK: return "shippingbox"
        case .settings: return WbIcon.settings
        case .toggleAppearance: return "circle.lefthalf.filled"
        case .tasks: return WbIcon.tasks
        }
    }

    var body: some View {
        HStack(spacing: WbSpace.md) {
            Image(systemName: symbol)
                .font(.system(size: WbIconSize.iconSm, weight: .medium))
                .frame(width: WbIconSize.iconMd)
                .foregroundStyle(WbColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WbSpace.xxs) {
                Text(entry.title).lineLimit(1).truncationMode(.middle).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WbColor.textPrimary)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: WbSpace.sm)
            if !entry.keyboard.isEmpty {
                Text(entry.keyboard)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, WbSpace.md)
        .frame(height: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A borderless editor with a separate symbol, like Spotlight's search bar.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("palette-search")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
