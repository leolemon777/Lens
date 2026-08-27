import SwiftUI

/// Shared visual tokens for every Lens window. Keeping these values in one
/// place prevents each tool from building a slightly different "glass" surface.
enum LensGlassPalette {
    static let ice = Color(red: 0.47, green: 0.88, blue: 1.00)
    static let blue = Color(red: 0.12, green: 0.48, blue: 1.00)
    static let coral = Color(red: 1.00, green: 0.31, blue: 0.32)
    static let midnight = Color(red: 0.025, green: 0.045, blue: 0.075)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [ice, blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum LensGlassMetrics {
    static let windowCornerRadius: CGFloat = 30
    static let panelCornerRadius: CGFloat = 24
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 13
}

enum LensMotionPolicy {
    static func pressedScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        reduceMotion || !isPressed ? 1 : 0.975
    }

    static func interactiveScale(
        isPressed: Bool,
        isHovering: Bool,
        reduceMotion: Bool
    ) -> CGFloat {
        guard !reduceMotion else { return 1 }
        if isPressed { return 0.975 }
        return isHovering ? 1.012 : 1
    }

    static func hoverOffset(isHovering: Bool, reduceMotion: Bool) -> CGFloat {
        reduceMotion || !isHovering ? 0 : -1
    }

    static func buttonAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78)
    }

    static func panelAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    static func meterAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.08)
    }
}

enum LensGlassSurfaceRole: String, CaseIterable {
    case window
    case panel
    case chrome
    case card
    case control

    /// Only top-level surfaces may request a system material. Cards and controls
    /// use static translucent fills so a window never stacks blur layers.
    var usesBackdropMaterial: Bool {
        self == .window || self == .panel || self == .chrome
    }

    var material: Material {
        switch self {
        case .window, .panel, .chrome: .ultraThin
        case .card, .control: .thin
        }
    }

    var fallbackOpacity: Double {
        switch self {
        case .window: 0.98
        case .panel: 0.97
        case .chrome: 0.96
        case .card: 0.94
        case .control: 0.92
        }
    }

    var highlightOpacity: Double {
        switch self {
        case .window: 0.34
        case .panel: 0.28
        case .chrome: 0.19
        case .card: 0.20
        case .control: 0.16
        }
    }

    var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .window: (0.28, 34, 18)
        case .panel: (0.24, 28, 14)
        case .chrome: (0.08, 10, 3)
        case .card: (0.10, 12, 5)
        case .control: (0.07, 7, 3)
        }
    }
}

private struct LensReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct LensReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var lensReduceTransparencyOverride: Bool? {
        get { self[LensReduceTransparencyOverrideKey.self] }
        set { self[LensReduceTransparencyOverrideKey.self] = newValue }
    }

    var lensReduceMotionOverride: Bool? {
        get { self[LensReduceMotionOverrideKey.self] }
        set { self[LensReduceMotionOverrideKey.self] = newValue }
    }
}

/// A cheap, static depth backdrop. It deliberately avoids animated blur and
/// nested visual-effect views so editor playback and recording controls stay fast.
struct LensGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.lensReduceTransparencyOverride) private var reduceTransparencyOverride

    var body: some View {
        Group {
            if reduceTransparencyOverride ?? reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(
                        colors: [
                            LensGlassPalette.ice.opacity(0.075),
                            .clear,
                            LensGlassPalette.blue.opacity(0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [LensGlassPalette.ice.opacity(0.10), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct LensGlassSurface: ViewModifier {
    let role: LensGlassSurfaceRole
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.lensReduceTransparencyOverride) private var reduceTransparencyOverride

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shouldReduceTransparency = reduceTransparencyOverride ?? reduceTransparency

        if !role.usesBackdropMaterial {
            decorated(
                content.background(
                    Color.primary.opacity(role == .card ? 0.040 : 0.055),
                    in: shape
                ),
                shape: shape,
                reducedTransparency: shouldReduceTransparency
            )
        } else if shouldReduceTransparency {
            decorated(
                content.background(
                    Color(nsColor: .windowBackgroundColor).opacity(role.fallbackOpacity),
                    in: shape
                ),
                shape: shape,
                reducedTransparency: true
            )
        } else if #available(macOS 26.0, *) {
            decorated(
                // Large window surfaces must stay geometrically stable while they
                // are being captured. Interactive Liquid Glass is intended for
                // controls and can temporarily warp the outer rim under the pointer.
                content.glassEffect(.regular, in: shape),
                shape: shape,
                reducedTransparency: false
            )
        } else {
            decorated(
                content
                    .background(role.material, in: shape)
                    .background(
                        LinearGradient(
                            colors: [
                                LensGlassPalette.ice.opacity(role == .window ? 0.055 : 0.025),
                                .clear,
                                LensGlassPalette.blue.opacity(role == .window ? 0.04 : 0.018)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: shape
                    ),
                shape: shape,
                reducedTransparency: false
            )
        }
    }

    private func decorated<V: View>(
        _ content: V,
        shape: RoundedRectangle,
        reducedTransparency: Bool
    ) -> some View {
        let shadow = role.shadow
        return content
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(reducedTransparency ? 0.20 : role.highlightOpacity),
                            .white.opacity(reducedTransparency ? 0.08 : 0.07),
                            LensGlassPalette.ice.opacity(reducedTransparency ? 0.07 : 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
            .shadow(
                color: .black.opacity(shadow.opacity),
                radius: shadow.radius,
                y: shadow.y
            )
    }
}

struct LensGlassButtonStyle: ButtonStyle {
    var tint: Color = LensGlassPalette.ice
    var isSelected = false
    var cornerRadius: CGFloat = LensGlassMetrics.controlCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        LensGlassButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isSelected: isSelected,
            tint: tint,
            cornerRadius: cornerRadius
        )
    }
}

private struct LensGlassButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isSelected: Bool
    let tint: Color
    let cornerRadius: CGFloat

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lensReduceMotionOverride) private var reduceMotionOverride

    var body: some View {
        let shouldReduceMotion = reduceMotionOverride ?? reduceMotion
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        label
            .background(shape.fill(backgroundColor))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isPressed || isSelected ? 0.28 : 0.14),
                            tint.opacity(isSelected ? 0.48 : isHovering ? 0.26 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(
                color: tint.opacity(isHovering && !shouldReduceMotion ? 0.15 : 0),
                radius: 9,
                y: 3
            )
            .scaleEffect(LensMotionPolicy.interactiveScale(
                isPressed: isPressed,
                isHovering: isHovering,
                reduceMotion: shouldReduceMotion
            ))
            .offset(y: LensMotionPolicy.hoverOffset(
                isHovering: isHovering,
                reduceMotion: shouldReduceMotion
            ))
            .opacity(isEnabled ? 1 : 0.42)
            .animation(
                LensMotionPolicy.buttonAnimation(reduceMotion: shouldReduceMotion),
                value: isPressed
            )
            .animation(
                LensMotionPolicy.buttonAnimation(reduceMotion: shouldReduceMotion),
                value: isHovering
            )
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isPressed { return tint.opacity(0.19) }
        if isSelected { return tint.opacity(0.13) }
        if isHovering { return tint.opacity(0.085) }
        return .primary.opacity(0.045)
    }
}

struct LensGlassSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let content: Content

    init(
        _ title: String,
        symbol: String,
        tint: Color = LensGlassPalette.ice,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
            content
        }
        .padding(14)
        .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
    }
}

extension View {
    func lensGlassSurface(
        role: LensGlassSurfaceRole = .panel,
        cornerRadius: CGFloat = LensGlassMetrics.panelCornerRadius
    ) -> some View {
        modifier(LensGlassSurface(role: role, cornerRadius: cornerRadius))
    }

    func lensGlassPanel(cornerRadius: CGFloat = 28) -> some View {
        lensGlassSurface(role: .panel, cornerRadius: cornerRadius)
    }

    func lensAccessibilityOverrides(
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil
    ) -> some View {
        environment(\.lensReduceTransparencyOverride, reduceTransparency)
            .environment(\.lensReduceMotionOverride, reduceMotion)
    }
}
