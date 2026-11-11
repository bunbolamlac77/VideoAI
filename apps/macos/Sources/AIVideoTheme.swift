//
// AIVideoTheme.swift — Design system for the AIVideo macOS app.
//
// One place for the visual language: canvas, panel surface, spacing, corner
// radii, chips and button styles. Screens should compose these tokens instead
// of hard-coding colors/paddings, so the app looks like one product.
//
// Brand: deep teal #0F766E (light) / mint #5EEAD4 (dark), per 10-UI-UX-MACOS.md.
//

import SwiftUI
import AppKit

enum Theme {
    // Spacing scale 4 / 8 / 12 / 16 / 24 / 32
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    static let radiusCard: CGFloat = 16
    static let radiusControl: CGFloat = 10
    static let pageWidth: CGFloat = 1080
}

extension Color {
    /// Panel surface that works in both light and dark mode.
    static func panelSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.72)
            : Color(nsColor: .controlBackgroundColor)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }
}

/// Soft brand-tinted canvas behind every screen (subtle, not a gradient banner).
struct AppCanvas: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.brandTeal.opacity(scheme == .dark ? 0.12 : 0.07),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.brandTeal.opacity(scheme == .dark ? 0.07 : 0.04), Color.clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 760
            )
        }
        .ignoresSafeArea()
    }
}

/// Elevated panel with a hairline edge and a soft shadow.
struct PanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Theme.radiusCard

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.panelSurface(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(scheme == .dark ? 0.12 : 0.65),
                                Color.hairline(scheme)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.07), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func panel(radius: CGFloat = Theme.radiusCard) -> some View {
        modifier(PanelBackground(radius: radius))
    }
}

/// Small uppercase pill used for step numbers and mode labels.
struct StepChip: View {
    let text: String
    var tint: Color = .brandTeal

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.22)))
    }
}

/// Primary call-to-action: teal gradient, white label, generous height.
struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(Color.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.brandTeal, Color.brandTeal.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18))
            )
            .shadow(color: Color.brandTeal.opacity(0.35), radius: 8, x: 0, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Quiet secondary action for the same toolbars.
struct GhostActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10))
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
