// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Packs full-sized controls into rows. Every action remains visible, including
/// long localized labels; resizing changes rows rather than hiding commands.
struct ActionFlowLayout: Layout {
    var spacing: CGFloat = 8

    static func arrange(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .greatestFiniteMagnitude
        let result = Self.arrange(sizes, width: width, spacing: spacing)
        return CGSize(width: proposal.width ?? result.size.width, height: result.size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = Self.arrange(sizes, width: bounds.width, spacing: spacing)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}
