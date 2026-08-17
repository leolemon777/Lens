import SwiftUI

/// Shared visual tokens for every ScreenTrace window. Keeping these values in one
/// place prevents each tool from building a slightly different "glass" surface.
enum TraceGlassPalette {
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

enum TraceGlassMetrics {
    static let windowCornerRadius: CGFloat = 30
    static let panelCornerRadius: CGFloat = 24
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 13
}

enum TraceMotionPolicy {
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

enum TraceGlassSurfaceRole: String, CaseIterable {
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

private struct TraceReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct TraceReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var traceReduceTransparencyOverride: Bool? {
        get { self[TraceReduceTransparencyOverrideKey.self] }
        set { self[TraceReduceTransparencyOverrideKey.self] = newValue }
    }

    var traceReduceMotionOverride: Bool? {
        get { self[TraceReduceMotionOverrideKey.self] }
        set { self[TraceReduceMotionOverrideKey.self] = newValue }
    }
}

/// A cheap, static depth backdrop. It deliberately avoids animated blur and
/// nested visual-effect views so editor playback and recording controls stay fast.
struct TraceGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.traceReduceTransparencyOverride) private var reduceTransparencyOverride

    var body: some View {
        Group {
            if reduceTransparencyOverride ?? reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(
                        colors: [
                            TraceGlassPalette.ice.opacity(0.075),
                            .clear,
                            TraceGlassPalette.blue.opacity(0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [TraceGlassPalette.ice.opacity(0.10), .clear],
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

struct TraceGlassSurface: ViewModifier {
    let role: TraceGlassSurfaceRole
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.traceReduceTransparencyOverride) private var reduceTransparencyOverride

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
                                TraceGlassPalette.ice.opacity(role == .window ? 0.055 : 0.025),
                                .clear,
                                TraceGlassPalette.blue.opacity(role == .window ? 0.04 : 0.018)
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
                            TraceGlassPalette.ice.opacity(reducedTransparency ? 0.07 : 0.14)
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

struct TraceGlassButtonStyle: ButtonStyle {
    var tint: Color = TraceGlassPalette.ice
    var isSelected = false
    var cornerRadius: CGFloat = TraceGlassMetrics.controlCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        TraceGlassButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isSelected: isSelected,
            tint: tint,
            cornerRadius: cornerRadius
        )
    }
}

private struct TraceGlassButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isSelected: Bool
    let tint: Color
    let cornerRadius: CGFloat

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.traceReduceMotionOverride) private var reduceMotionOverride

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
            .scaleEffect(TraceMotionPolicy.interactiveScale(
                isPressed: isPressed,
                isHovering: isHovering,
                reduceMotion: shouldReduceMotion
            ))
            .offset(y: TraceMotionPolicy.hoverOffset(
                isHovering: isHovering,
                reduceMotion: shouldReduceMotion
            ))
            .opacity(isEnabled ? 1 : 0.42)
            .animation(
                TraceMotionPolicy.buttonAnimation(reduceMotion: shouldReduceMotion),
                value: isPressed
            )
            .animation(
                TraceMotionPolicy.buttonAnimation(reduceMotion: shouldReduceMotion),
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

struct TraceGlassSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let content: Content

    init(
        _ title: String,
        symbol: String,
        tint: Color = TraceGlassPalette.ice,
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
        .traceGlassSurface(role: .card, cornerRadius: TraceGlassMetrics.cardCornerRadius)
    }
}

extension View {
    func traceGlassSurface(
        role: TraceGlassSurfaceRole = .panel,
        cornerRadius: CGFloat = TraceGlassMetrics.panelCornerRadius
    ) -> some View {
        modifier(TraceGlassSurface(role: role, cornerRadius: cornerRadius))
    }

    func traceGlassPanel(cornerRadius: CGFloat = 28) -> some View {
        traceGlassSurface(role: .panel, cornerRadius: cornerRadius)
    }

    func traceAccessibilityOverrides(
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil
    ) -> some View {
        environment(\.traceReduceTransparencyOverride, reduceTransparency)
            .environment(\.traceReduceMotionOverride, reduceMotion)
    }
}
