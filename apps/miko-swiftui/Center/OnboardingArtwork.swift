// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Decorative device imagery drawn with native shapes so it adapts to the
/// current appearance and never implies the state of an actual device.
struct OnboardingArtwork: View {
    let step: Int
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }
    private var card: Color { Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.92 : 0.96) }
    private var outline: Color { Color.primary.opacity(dark ? 0.09 : 0.06) }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color(red: 0.36, green: 0.55, blue: 0.96).opacity(dark ? 0.20 : 0.15))
                .frame(width: 300, height: 245).blur(radius: 48)
                .offset(x: 15, y: 30)
            Ellipse()
                .fill(Color(red: 0.72, green: 0.56, blue: 0.96).opacity(dark ? 0.12 : 0.11))
                .frame(width: 190, height: 135).blur(radius: 48)
                .offset(x: -95, y: 82)

            floatingImageCard
                .rotationEffect(.degrees(-4)).offset(x: -112, y: -55)
            device
                .rotationEffect(.degrees(-3)).offset(x: 5, y: 0)
            floatingControlCard
                .rotationEffect(.degrees(3)).offset(x: 117, y: 83)
        }
        .frame(width: 420, height: 400)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var floatingImageCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: step == 0 ? "square.3.layers.3d" : "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.35, green: 0.48, blue: 0.88))
                Spacer()
                Circle().fill(outline).frame(width: 6, height: 6)
            }
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(dark ? 0.22 : 0.13)).frame(width: 65, height: 6)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(dark ? 0.10 : 0.06)).frame(width: 94, height: 5)
            HStack(spacing: 5) {
                Capsule().fill(Color(red: 0.43, green: 0.59, blue: 0.94).opacity(0.20)).frame(width: 38, height: 12)
                Capsule().fill(Color.primary.opacity(0.06)).frame(width: 28, height: 12)
            }
        }
        .padding(15).frame(width: 145, height: 116, alignment: .topLeading)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(outline))
        .shadow(color: .black.opacity(dark ? 0.22 : 0.08), radius: 20, y: 9)
    }

    private var device: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.34, blue: 0.43), Color(red: 0.12, green: 0.15, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 29, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.93, blue: 1), Color(red: 0.73, green: 0.82, blue: 0.98), Color(red: 0.83, green: 0.80, blue: 0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(6)
            VStack(spacing: 0) {
                Capsule().fill(Color(red: 0.12, green: 0.15, blue: 0.21)).frame(width: 45, height: 6).padding(.top, 15)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(.white.opacity(0.73)).frame(width: 68, height: 68)
                    Image(systemName: step == 0 ? "square.stack.3d.up" : "slider.horizontal.3")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(Color(red: 0.30, green: 0.43, blue: 0.77))
                }
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(index == 1 ? 0.75 : 0.46)).frame(width: 25, height: 25)
                    }
                }
                .padding(.bottom, 19)
                Capsule().fill(Color.black.opacity(0.28)).frame(width: 48, height: 4).padding(.bottom, 12)
            }
            .padding(.horizontal, 12)
        }
        .frame(width: 170, height: 324)
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.24)))
        .shadow(color: Color(red: 0.22, green: 0.32, blue: 0.58).opacity(dark ? 0.24 : 0.21), radius: 28, y: 18)
    }

    private var floatingControlCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.48, green: 0.62, blue: 0.96).opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: step == 0 ? "arrow.down.circle" : "checkmark.circle")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Color(red: 0.34, green: 0.48, blue: 0.86))
            }
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(dark ? 0.22 : 0.14)).frame(width: 70, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(dark ? 0.10 : 0.06)).frame(width: 49, height: 5)
            }
        }
        .padding(14).frame(width: 160, height: 70)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(outline))
        .shadow(color: .black.opacity(dark ? 0.24 : 0.08), radius: 20, y: 10)
    }
}

