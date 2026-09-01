import AppKit
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

    // Semantic roles. UI code should reach for these instead of a bare
    // system hue literal so color stops being used to distinguish feature
    // categories — only the four states below,
    // plus content itself, ever carry color; everything else is neutral.
    /// The single accent used for primary actions, selection and focus.
    static let accent = ice
    /// Recording state only — never a generic "this feature involves video" tint.
    static let recording = Color.red
    /// Warnings and items awaiting review.
    static let warning = Color.orange
    /// Completed/healthy state.
    static let success = Color.green
    /// Everything else: icons, secondary tags, non-primary buttons.
    static let neutral = Color.secondary

    // NSColor bridges for the small amount of AppKit drawing code (e.g. the
    // capture selection overlay) that isn't SwiftUI and can't take a
    // `Color` directly. `static let` so the bridging conversion happens once
    // per process, not on every draw call in a 60 Hz drag loop.
    static let accentColor = NSColor(accent)
    static let recordingColor = NSColor(recording)
    static let warningColor = NSColor(warning)
}

enum LensGlassMetrics {
    static let windowCornerRadius: CGFloat = 30
    static let panelCornerRadius: CGFloat = 24
    /// The action center's large primary-action tiles (screenshot, record,
    /// more). Distinct from `cardCornerRadius`: cards hold library/insight
    /// content, tiles are tappable launch targets.
    static let tileCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 13
    static let badgeCornerRadius: CGFloat = 8
    static let thumbnailCornerRadius: CGFloat = 10
    /// Every `role: .chrome` surface (toolbar strips flush against a window
    /// edge) uses this everywhere it appears; unlike the other surfaces,
    /// chrome is deliberately unrounded.
    static let chromeCornerRadius: CGFloat = 0
}

/// Text point sizes. Every label in the app should resolve to one of these
/// six values instead of a hand-picked literal; `LensDesignTokenLintTests`
/// enforces this so the type scale cannot silently drift again.
enum LensType {
    static let title: CGFloat = 15
    static let body: CGFloat = 13
    static let callout: CGFloat = 12
    /// macOS's own body-text floor; nothing user-facing should read smaller.
    static let caption: CGFloat = 11
    /// Reserved for short badges/pills (a few characters, semibold).
    static let micro: CGFloat = 10
    static let numeric: CGFloat = 13
}

/// SF Symbol point sizes, kept separate from `LensType` because
/// `Image(systemName:)` and `Text` share the same `.font(.system(size:))`
/// call site but scale on different axes.
enum LensIcon {
    static let small: CGFloat = 11
    static let medium: CGFloat = 13
    static let large: CGFloat = 17
    static let xlarge: CGFloat = 24
    static let hero: CGFloat = 34
}

enum LensSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
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
    var tint: Color? = nil
    var shadowOverride: (opacity: Double, radius: CGFloat, y: CGFloat)? = nil
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
                content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape),
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
        let shadow = shadowOverride ?? role.shadow
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
                .font(.system(size: LensType.caption, weight: .semibold))
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
        cornerRadius: CGFloat = LensGlassMetrics.panelCornerRadius,
        tint: Color? = nil,
        shadow: (opacity: Double, radius: CGFloat, y: CGFloat)? = nil
    ) -> some View {
        modifier(LensGlassSurface(role: role, cornerRadius: cornerRadius, tint: tint, shadowOverride: shadow))
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
