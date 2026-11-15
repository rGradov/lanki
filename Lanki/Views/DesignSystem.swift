import SwiftUI

/// Shared visual language for Lanki – clean cards + glass settings.
enum Theme {
    static let cornerRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 14
    static let glassRadius: CGFloat = 16

    static let accent = Color(red: 0.22, green: 0.45, blue: 0.96)

    static let ink = Color(light: Color(red: 0.11, green: 0.12, blue: 0.16),
                           dark: Color(red: 0.95, green: 0.96, blue: 0.98))
    static let inkText = Color(light: .white, dark: Color(red: 0.08, green: 0.09, blue: 0.12))

    static let card = Color(light: Color(red: 0.99, green: 0.99, blue: 1.0),
                            dark: Color(red: 0.13, green: 0.13, blue: 0.15))
    static let field = Color(light: Color(red: 0.945, green: 0.948, blue: 0.96),
                             dark: Color(red: 0.19, green: 0.19, blue: 0.22))
    static let fieldBorder = Color(light: Color(red: 0.86, green: 0.87, blue: 0.90),
                                   dark: Color(red: 0.30, green: 0.30, blue: 0.34))

    static let primaryText = Color(light: Color(red: 0.08, green: 0.09, blue: 0.12),
                                   dark: Color(red: 0.96, green: 0.97, blue: 0.99))
    static let secondaryText = Color(light: Color(red: 0.42, green: 0.44, blue: 0.49),
                                     dark: Color(red: 0.62, green: 0.64, blue: 0.70))

    /// Soft wash behind settings / glass panels.
    static let settingsCanvas = Color(light: Color(red: 0.945, green: 0.950, blue: 0.965),
                                      dark: Color(red: 0.09, green: 0.09, blue: 0.11))
    static let sidebarFill = Color(light: Color.white.opacity(0.55),
                                   dark: Color.white.opacity(0.06))
    static let glassStroke = Color(light: Color.white.opacity(0.7),
                                   dark: Color.white.opacity(0.10))
    static let rowHover = Color(light: Color.black.opacity(0.04),
                                dark: Color.white.opacity(0.06))
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }
}

struct FieldBackground: ViewModifier {
    var radius: CGFloat = Theme.fieldRadius
    func body(content: Content) -> some View {
        content
            .background(Theme.field, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 1)
            )
    }
}

extension View {
    func fieldStyle(radius: CGFloat = Theme.fieldRadius) -> some View {
        modifier(FieldBackground(radius: radius))
    }

    /// Liquid-glass style panel used in Settings.
    func glassPanel(radius: CGFloat = Theme.glassRadius) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Theme.sidebarFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Theme.glassStroke, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 18, y: 6)
            }
    }

    /// Floating popup chrome — frosted glass that samples the desktop behind it.
    /// Kept intentionally restrained: one material layer, a hairline edge and a
    /// single thin top highlight (per the macOS glass look).
    func popupGlassCard(radius: CGFloat = Theme.cornerRadius) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.glassStroke, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // Subtle specular highlight along the top edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), .clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .opacity(0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // NB: no SwiftUI drop shadow here — the borderless panel casts a
            // native window shadow that follows the rounded alpha mask. A
            // SwiftUI shadow would be clipped to the square window bounds.
    }

    /// Inset control surface (dropdowns, chips) on a glass card.
    func glassChip(radius: CGFloat = 10) -> some View {
        self
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.glassStroke.opacity(0.6), lineWidth: 0.8)
            )
    }
}

/// Primary action on glass cards — solid ink pill with a soft outer glow.
struct PrimaryButtonStyle: ButtonStyle {
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .fill(Theme.ink.opacity(disabled ? 0.4 : 1))
                    .shadow(color: Theme.ink.opacity(disabled ? 0 : 0.22), radius: 10, y: 4)
            }
            .foregroundStyle(Theme.inkText)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
