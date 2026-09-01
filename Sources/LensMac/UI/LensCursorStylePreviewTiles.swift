import LensCore
import SwiftUI

/// Graphical tiles for cursor style pickers: every option renders what it
/// actually looks like instead of a text menu entry.

// MARK: - 指针箭头形状

struct LensCursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0.10 * w, y: 0.03 * h))
        path.addLine(to: CGPoint(x: 0.10 * w, y: 0.82 * h))
        path.addLine(to: CGPoint(x: 0.30 * w, y: 0.63 * h))
        path.addLine(to: CGPoint(x: 0.43 * w, y: 0.95 * h))
        path.addLine(to: CGPoint(x: 0.53 * w, y: 0.90 * h))
        path.addLine(to: CGPoint(x: 0.40 * w, y: 0.60 * h))
        path.addLine(to: CGPoint(x: 0.67 * w, y: 0.60 * h))
        path.closeSubpath()
        return path
    }
}

// MARK: - 鼠标样式预览

struct LensCursorAppearancePreview: View {
    let appearance: AutoEditPlan.Cursor.Appearance
    let accent: Color

    var body: some View {
        ZStack {
            switch appearance {
            case .recorded:
                LensCursorArrowShape()
                    .fill(Color.primary)
                    .overlay(LensCursorArrowShape().stroke(.white, lineWidth: 1))
                    .frame(width: 15, height: 22)
                // Hint: recorded replays arrow / I-beam / hand shapes.
                VStack(spacing: 2) {
                    Capsule().fill(Color.secondary).frame(width: 1.6, height: 9)
                    Capsule().fill(Color.secondary).frame(width: 6, height: 1.4)
                    Capsule().fill(Color.secondary).frame(width: 6, height: 1.4)
                }
                .offset(x: 14, y: -4)
            case .macOS:
                LensCursorArrowShape()
                    .fill(Color.primary)
                    .overlay(LensCursorArrowShape().stroke(.white, lineWidth: 1))
                    .frame(width: 16, height: 24)
            case .highContrast:
                LensCursorArrowShape()
                    .fill(Color.white)
                    .overlay(LensCursorArrowShape().stroke(.black, lineWidth: 1.4))
                    .frame(width: 16, height: 24)
            case .minimalDot:
                Circle()
                    .fill(accent)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.6))
            case .ring:
                LensCursorArrowShape()
                    .fill(Color.primary)
                    .overlay(LensCursorArrowShape().stroke(.white, lineWidth: 0.8))
                    .frame(width: 11, height: 16)
                    .offset(x: -3, y: -2)
                Circle()
                    .stroke(accent, lineWidth: 2.4)
                    .background(Circle().fill(accent.opacity(0.10)))
                    .frame(width: 26, height: 26)
            case .glowDot:
                LensCursorArrowShape()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 10, height: 15)
                    .offset(x: -6, y: -4)
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .shadow(color: accent.opacity(0.85), radius: 5)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 44, height: 32)
    }
}

// MARK: - 跟随效果预览（轨迹）

struct LensCursorFollowPreview: View {
    let style: AutoEditPlan.Cursor.FollowStyle
    let accent: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let end = CGPoint(x: size.width - 7, y: size.height * 0.32)
            switch style {
            case .faithful:
                path.move(to: CGPoint(x: 5, y: size.height - 7))
                path.addLine(to: CGPoint(x: size.width * 0.48, y: 8))
                path.addLine(to: end)
            case .smooth:
                path.move(to: CGPoint(x: 5, y: size.height - 7))
                path.addQuadCurve(
                    to: end,
                    control: CGPoint(x: size.width * 0.42, y: size.height * 0.18)
                )
            case .elastic:
                path.move(to: CGPoint(x: 4, y: size.height - 6))
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: size.width * 0.30, y: size.height * 0.05),
                    control2: CGPoint(x: size.width * 0.55, y: size.height * 1.05)
                )
            case .custom:
                path.move(to: CGPoint(x: 5, y: size.height - 7))
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: size.width * 0.35, y: size.height * 0.55),
                    control2: CGPoint(x: size.width * 0.60, y: size.height * 0.15)
                )
            }
            var stroke = Path()
            stroke.addPath(path)
            if style == .custom {
                context.stroke(
                    path,
                    with: .color(Color.secondary),
                    style: StrokeStyle(lineWidth: 1.6, dash: [3, 2.4])
                )
            } else {
                context.stroke(
                    path,
                    with: .color(accent),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
            context.fill(
                Path(ellipseIn: CGRect(
                    x: end.x - 3,
                    y: end.y - 3,
                    width: 6,
                    height: 6
                )),
                with: .color(style == .custom ? Color.secondary : accent)
            )
        }
        .frame(width: 44, height: 32)
    }
}

// MARK: - 移动特效预览

struct LensCursorMotionPreview: View {
    let effect: AutoEditPlan.Cursor.MotionEffect
    let accent: Color

    var body: some View {
        ZStack {
            switch effect {
            case .none:
                arrow
            case .halo:
                Circle()
                    .fill(accent.opacity(0.20))
                    .frame(width: 24, height: 24)
                    .shadow(color: accent.opacity(0.5), radius: 4)
                arrow
            case .trail:
                ForEach(Array([0.18, 0.34, 0.5].enumerated()), id: \.offset) { index, alpha in
                    Circle()
                        .fill(accent.opacity(Double(alpha)))
                        .frame(width: 6 - CGFloat(index), height: 6 - CGFloat(index))
                        .offset(x: CGFloat(10 + index * 7), y: CGFloat(-2 + index * 5))
                }
                arrow.offset(x: -6, y: -6)
            case .spotlight:
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.34), accent.opacity(0.02)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 17
                        )
                    )
                    .frame(width: 32, height: 32)
                arrow
            }
        }
        .frame(width: 44, height: 32)
    }

    private var arrow: some View {
        LensCursorArrowShape()
            .fill(Color.primary)
            .overlay(LensCursorArrowShape().stroke(.white, lineWidth: 0.8))
            .frame(width: 11, height: 16)
    }
}

// MARK: - 点击效果预览

struct LensClickEffectPreview: View {
    let effect: AutoEditPlan.Interaction.ClickEffect
    let accent: Color

    var body: some View {
        ZStack {
            switch effect {
            case .ripple:
                Circle()
                    .stroke(accent.opacity(0.9), lineWidth: 1.8)
                    .frame(width: 24, height: 24)
                Circle()
                    .stroke(accent.opacity(0.5), lineWidth: 1.4)
                    .frame(width: 13, height: 13)
            case .pulse:
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Circle()
                    .stroke(accent.opacity(0.75), lineWidth: 2)
                    .frame(width: 18, height: 18)
            case .spotlight:
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.55), accent.opacity(0.03)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 16
                        )
                    )
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 44, height: 32)
    }
}

// MARK: - 通用样式图块按钮

struct LensCursorStyleTileButton<Content: View>: View {
    let title: String
    let help: String
    let isSelected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                content()
                    .frame(width: 48, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? LensGlassPalette.accent.opacity(0.16) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isSelected ? LensGlassPalette.accent : Color.primary.opacity(0.14),
                                lineWidth: isSelected ? 1.6 : 0.8
                            )
                    )
                Text(title)
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(isSelected ? LensGlassPalette.accent : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
