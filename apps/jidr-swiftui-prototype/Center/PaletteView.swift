// SPDX-License-Identifier: GPL-3.0-only
// Command palette overlay (⌘K). The catalog, fuzzy filter and selection live
// in CommandPalette.swift; this file only draws them. Arrows/Return/Esc are
// handled by CenterModel.handleShortcutEvent, so the search field keeps
// normal typing behaviour.

import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: CenterModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [PaletteEntry] { model.paletteFiltered }
    private var visible: [PaletteEntry] { Array(entries.prefix(model.paletteVisibleCount)) }

    var body: some View {
        ZStack(alignment: .top) {
            WbColor.scrim
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }
            VStack(spacing: WbSpace.zero) {
                HStack(spacing: WbSpace.md) {
                    Image(systemName: WbIcon.search).foregroundStyle(WbColor.textSecondary)
                    TextField(model.text("输入命令或设备名称", "Type a command or a device name"), text: $model.paletteQuery)
                        .textFieldStyle(.plain)
                        .wbFont(WbType.title.weighted(.regular))
                        .focused($searchFocused)
                    Text("esc")
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                        .padding(.horizontal, WbSpace.sm).padding(.vertical, WbSpace.xxs)
                        .background(WbStatus.neutral.container, in: RoundedRectangle(cornerRadius: WbRadius.xs))
                }
                .padding(.horizontal, WbSpace.lg)
                .frame(height: 52)
                Divider()
                if entries.isEmpty {
                    Text(model.paletteEmptyText)
                        .foregroundStyle(WbColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WbSpace.lg).padding(.vertical, WbSpace.lg)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: WbSpace.xxs) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                                    PaletteRow(entry: entry, selected: index == model.paletteSelection)
                                        .id(index)
                                        .onTapGesture {
                                            model.closeOverlay()
                                            model.runPaletteAction(entry.action)
                                        }
                                        .onHover { hovering in
                                            if hovering { model.paletteSelection = index }
                                        }
                                }
                            }.padding(WbSpace.xs)
                        }
                        .frame(height: CGFloat(visible.count) * 40 + 8)
                        .onChange(of: model.paletteSelection) { _, selection in
                            withAnimation(WbMotion.scroll.animation(reduceMotion: reduceMotion)) { proxy.scrollTo(selection) }
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderDefault, lineWidth: WbBorder.hairline))
            .wbShadow(WbShadow.popover)
            .padding(.top, 72)
        }
        .tint(WbColor.accent)
        .onAppear { searchFocused = true }
        .onDisappear { searchFocused = false }
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool

    private var symbol: String {
        switch entry.kind {
        case .device: return WbIcon.smartphone
        case .action: return WbIcon.command
        case .setting: return WbIcon.advancedTools
        }
    }

    var body: some View {
        HStack(spacing: WbSpace.md) {
            Image(systemName: symbol)
                .frame(width: WbIconSize.iconMd)
                .foregroundStyle(WbColor.textSecondary)
            VStack(alignment: .leading, spacing: WbSpace.xxs) {
                Text(entry.title).lineLimit(1).wbFont(WbType.body)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !entry.keyboard.isEmpty {
                Text(entry.keyboard)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .padding(.horizontal, WbSpace.sm).padding(.vertical, WbSpace.xxs)
                    .background(WbStatus.neutral.container, in: RoundedRectangle(cornerRadius: WbRadius.xs))
            }
        }
        .padding(.horizontal, WbSpace.md)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WbColor.selected : Color.clear, in: RoundedRectangle(cornerRadius: WbRadius.sm))
        .contentShape(Rectangle())
    }
}
