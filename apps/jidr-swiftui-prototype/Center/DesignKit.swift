// SPDX-License-Identifier: GPL-3.0-only
// Shared visual components for the SwiftUI centre.
//
// This is the product-level layer on top of the D41 design tokens: card frames,
// form rows, status labels, thumbnails and button styles that the device center,
// settings window and sheets compose. It intentionally contains no page layout
// and no strings; callers pass localised text.
import AppKit
import SwiftUI

// MARK: - Surfaces

/// A raised card: the base material for panels and sheets.
struct WbCard<Content: View>: View {
    var padding: CGFloat = WbSpace.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.lg, style: .continuous))
    }
}

extension View {
    /// Card material without an extra layout wrapper, for views that already
    /// manage their own padding.
    func wbCardSurface(radius: CGFloat = WbRadius.lg) -> some View {
        background(WbColor.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func wbDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(WbColor.borderSubtle).frame(height: 1)
        }
    }
}

struct WbDivider: View {
    var body: some View {
        Rectangle().fill(WbColor.borderSubtle).frame(height: 1)
    }
}

// MARK: - Headers and labels

/// Small uppercase-style label above a group of rows.
struct WbGroupLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .wbFont(WbType.label)
            .foregroundStyle(WbColor.textSecondary)
            .padding(.leading, WbSpace.xxs)
    }
}

/// A card header: title on the left, an optional trailing control on the right.
struct WbCardHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: WbSpace.sm) {
            Text(title)
                .wbFont(WbType.title)
                .foregroundStyle(WbColor.textPrimary)
            Spacer(minLength: WbSpace.sm)
            trailing()
        }
    }
}

extension WbCardHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

// MARK: - Status

enum WbStatusTone {
    case running, starting, stopped, error, busy, neutral

    var color: Color {
        switch self {
        case .running: return WbColor.positive
        case .starting: return WbColor.warning
        case .busy: return WbColor.warning
        case .error: return WbColor.negative
        case .stopped, .neutral: return WbColor.textTertiary
        }
    }
}

/// Status is a small dot plus a label, never a saturated pill.
struct WbStatusLabel: View {
    var text: String
    var tone: WbStatusTone

    var body: some View {
        HStack(spacing: WbSpace.xxs + 2) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(text)
                .wbFont(WbType.label)
                .foregroundStyle(tone == .stopped || tone == .neutral ? WbColor.textSecondary : tone.color)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Device thumbnail

/// AppKit-drawn device artwork inside a rounded bezel, matching the card system.
struct WbDeviceThumbnail: View {
    var name: String = "device-list"
    var width: CGFloat = 52
    var height: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WbRadius.sm + 2, style: .continuous)
                .fill(WbColor.bezel)
            DeviceArt(name: name, width: width)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: WbRadius.sm + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WbRadius.sm + 2, style: .continuous)
                .strokeBorder(WbColor.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - App tile

struct WbAppIcon: View {
    var symbol: String
    var imagePath: String? = nil
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let imagePath, let image = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(WbColor.control)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(WbColor.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

// MARK: - Buttons

/// A compact flat action used in the "common actions" strip: icon + label with
/// a hover background and no permanent fill.
struct WbFlatActionLabel: View {
    var title: String
    var icon: String

    var body: some View {
        HStack(spacing: WbSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WbColor.accentText)
            Text(title)
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textPrimary)
        }
        .padding(.horizontal, WbSpace.sm)
        .frame(height: 28)
        .contentShape(RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous))
    }
}

// MARK: - Form rows

/// One settings row: label (+ optional detail) on the left, a control on the right.
struct WbFormRow<Control: View>: View {
    var label: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .wbFont(WbType.body)
                    .foregroundStyle(WbColor.textPrimary)
                if let detail {
                    Text(detail)
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: WbSpace.md)
            control()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, WbSpace.lg)
    }
}

extension WbFormRow where Control == EmptyView {
    init(label: String, detail: String? = nil) {
        self.init(label: label, detail: detail, control: { EmptyView() })
    }
}

/// A grouped card of form rows with hairline separators between them.
struct WbFormGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .wbCardSurface()
    }
}

/// Row divider inset from the card edge, for grouped form rows.
struct WbRowDivider: View {
    var inset: CGFloat = WbSpace.lg
    var body: some View {
        Rectangle()
            .fill(WbColor.borderSubtle)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

// MARK: - Sidebar

/// One navigation row in the settings window.
struct WbSidebarRow: View {
    var title: String
    var icon: String
    var selected: Bool

    var body: some View {
        HStack(spacing: WbSpace.sm + 1) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? WbColor.accentText : WbColor.textSecondary)
                .frame(width: 17)
            Text(title)
                .wbFont(selected ? WbType.body.weighted(.medium) : WbType.body)
                .foregroundStyle(selected ? WbColor.textPrimary : WbColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WbSpace.sm)
        .frame(height: 31)
        .background(
            RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous)
                .fill(selected ? WbColor.accentContainer : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous)
                .strokeBorder(selected ? WbColor.accentText.opacity(0.18) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: WbRadius.sm, style: .continuous))
    }
}

// MARK: - Progress

struct WbProgressLine: View {
    var text: String
    var value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.xs) {
            HStack(spacing: WbSpace.xs) {
                if value != nil {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(1)
            }
            if let value {
                ProgressView(value: min(max(value, 0), 1))
                    .progressViewStyle(.linear)
            }
        }
    }
}
