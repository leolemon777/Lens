import SwiftUI

struct TraceGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
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
}
