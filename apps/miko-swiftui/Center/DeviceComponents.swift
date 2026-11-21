// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

// Shared navigation treatment for settings and tool categories.
struct MikoNavigationItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: WbSpace.md) {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
                .wbFont(WbType.body.weighted(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WbSpace.md).padding(.vertical, WbSpace.sm)
                .background(selected ? WbColor.selected : Color.clear,
                            in: RoundedRectangle(cornerRadius: WbRadius.sm))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A path and its related controls stay together, including for long paths.
struct PathSetting<Actions: View>: View {
    let title: String
    let path: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            Text(title).wbFont(WbType.body.weighted(.medium))
            Text(path).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: WbSpace.sm, content: actions)
        }.padding(.vertical, WbSpace.xs)
    }
}

struct DeviceArt: View {
    let name: String
    let width: CGFloat
    var body: some View {
        Group {
            if let image = WbImageCache.image(named: name) {
                Image(nsImage:image).resizable().scaledToFit().frame(width:width)
            }
        }.accessibilityHidden(true)
    }
}

// MARK: - Shared sheet chrome

/// Shared title and device subtitle for device sheets and tools.
struct DeviceSheetHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .wbFont(WbType.headline)
                .foregroundStyle(WbColor.textPrimary)
            Text(subtitle)
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WbSpace.xl)
        .padding(.top, WbSpace.lg)
        .padding(.bottom, WbSpace.md)
    }
}

/// Bottom bar: explanatory note on the left, actions on the right.
struct DeviceSheetFooter<Actions: View>: View {
    var note: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            WbDivider()
            HStack(alignment: .center, spacing: WbSpace.sm) {
                Text(note)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WbSpace.sm)
                actions()
            }
            .padding(.horizontal, WbSpace.xl)
            .padding(.vertical, WbSpace.md)
        }
    }
}
