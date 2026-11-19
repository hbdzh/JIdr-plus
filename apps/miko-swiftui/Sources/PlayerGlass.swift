// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Native Liquid Glass on macOS 26, with a system material on older macOS.
struct PlayerGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// A readable glass surface above the device canvas, including black frames.
struct PlayerCanvasGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: cornerRadius))
            .modifier(PlayerGlassSurface(cornerRadius: cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}

enum PlayerScriptControlMetrics {
    static let height: CGFloat = 44
}
