// SPDX-License-Identifier: GPL-3.0-only
// Command palette overlay (⌘K). The catalog, fuzzy filter and selection live
// in CommandPalette.swift; this file only draws them. Arrows/Return/Esc are
// handled by CenterModel.handleShortcutEvent, so the search field keeps
// normal typing behaviour.

import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: CenterModel
    @FocusState private var searchFocused: Bool

    private var entries: [PaletteEntry] { model.paletteFiltered }
    private var visible: [PaletteEntry] { Array(entries.prefix(model.paletteVisibleCount)) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(model.text("输入命令或设备名称", "Type a command or a device name"), text: $model.paletteQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                    Text("esc")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                Divider()
                if entries.isEmpty {
                    Text(model.paletteEmptyText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
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
                            }.padding(4)
                        }
                        .frame(height: CGFloat(visible.count) * 40 + 8)
                        .onChange(of: model.paletteSelection) { _, selection in
                            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(selection) }
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
            .padding(.top, 72)
        }
        .onAppear { searchFocused = true }
        .onDisappear { searchFocused = false }
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool

    private var symbol: String {
        switch entry.kind {
        case .device: return "smartphone"
        case .action: return "command"
        case .setting: return "slider.horizontal.3"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1).font(.system(size: 13))
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !entry.keyboard.isEmpty {
                Text(entry.keyboard)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
