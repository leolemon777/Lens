import SwiftUI

enum TraceMotionPolicy {
    static func pressedScale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        reduceMotion || !isPressed ? 1 : 0.975
    }

    static func buttonAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78)
    }

    static func meterAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.08)
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

struct TraceGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.traceReduceTransparencyOverride) private var reduceTransparencyOverride

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparencyOverride ?? reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.97), in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
        }
    }
}

extension View {
    func traceGlassPanel(cornerRadius: CGFloat = 28) -> some View {
        modifier(TraceGlassPanel(cornerRadius: cornerRadius))
    }

    func traceAccessibilityOverrides(
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil
    ) -> some View {
        environment(\.traceReduceTransparencyOverride, reduceTransparency)
            .environment(\.traceReduceMotionOverride, reduceMotion)
    }
}
