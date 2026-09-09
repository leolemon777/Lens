import SwiftUI

/// Featured control for the default automatic-camera punch-in.
/// Kept visually distinct so the zoom amount is obvious at a glance.
struct AutomaticCameraZoomPreferenceCard: View {
    enum Layout {
        case featured
        case compact
    }

    @Binding var scale: Double
    var onRestoreDefault: () -> Void
    var layout: Layout = .featured

    private var isDefault: Bool {
        abs(scale - RecordingExperiencePreset.defaultAutomaticZoomScale) < 0.001
    }

    var body: some View {
        Group {
            switch layout {
            case .featured:
                featuredContent
            case .compact:
                compactContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightFill, in: cardShape)
        .overlay {
            cardShape.strokeBorder(
                LensGlassPalette.accent.opacity(0.55),
                lineWidth: 1.4
            )
        }
        .overlay(alignment: .topTrailing) {
            accentRibbon
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("自动运镜推近")
    }

    private var featuredContent: some View {
        VStack(alignment: .leading, spacing: LensSpacing.m) {
            header
            preview
            slider
            footer
        }
        .padding(LensSpacing.card)
    }

    private var compactContent: some View {
        HStack(spacing: LensSpacing.m) {
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: LensIcon.large, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("自动运镜推近")
                    .font(.system(size: LensType.caption, weight: .semibold))
                Text("点击后画面放大多少")
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 118, alignment: .leading)
            sliderControl
            Text(String(format: "%.2f×", scale))
                .font(.system(size: LensType.body, weight: .semibold, design: .rounded))
                .foregroundStyle(LensGlassPalette.accent)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, LensSpacing.card)
        .padding(.vertical, LensSpacing.m)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: LensSpacing.m) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: LensGlassMetrics.badgeCornerRadius,
                    style: .continuous
                )
                .fill(LensGlassPalette.accent.opacity(0.18))
                .frame(width: 36, height: 36)
                Image(systemName: "camera.metering.center.weighted")
                    .font(.system(size: LensIcon.large, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: LensSpacing.s) {
                    Text("自动运镜推近")
                        .font(.system(size: LensType.body, weight: .semibold))
                    Text("成片默认")
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .foregroundStyle(LensGlassPalette.ink)
                        .padding(.horizontal, LensSpacing.s)
                        .padding(.vertical, 3)
                        .background(
                            LensGlassPalette.accent,
                            in: Capsule(style: .continuous)
                        )
                }
                Text("点击后镜头放大多少。数字越小，画面里能看到的界面越多。")
                    .font(.system(size: LensType.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LensSpacing.s)
            Text(String(format: "%.2f×", scale))
                .font(.system(size: LensType.title, weight: .semibold, design: .rounded))
                .foregroundStyle(LensGlassPalette.accent)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: LensSpacing.s) {
            HStack {
                Text("可见范围")
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(previewCaption)
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let insetX = geo.size.width * (1 - 1 / max(scale, 1)) / 2
                let insetY = geo.size.height * (1 - 1 / max(scale, 1)) / 2
                ZStack {
                    RoundedRectangle(
                        cornerRadius: LensGlassMetrics.thumbnailCornerRadius,
                        style: .continuous
                    )
                    .fill(.primary.opacity(0.06))
                    fakeScreenContent
                        .padding(LensSpacing.s)
                        .opacity(0.42)
                    RoundedRectangle(
                        cornerRadius: LensGlassMetrics.badgeCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(LensGlassPalette.accent, lineWidth: 1.6)
                    .background(
                        LensGlassPalette.accent.opacity(0.08),
                        in: RoundedRectangle(
                            cornerRadius: LensGlassMetrics.badgeCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, insetX)
                    .padding(.vertical, insetY)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 88)
            .animation(.easeInOut(duration: 0.18), value: scale)
        }
        .accessibilityHidden(true)
    }

    private var fakeScreenContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: LensGlassMetrics.chromeCornerRadius, style: .continuous)
                .fill(.primary.opacity(0.22))
                .frame(width: 92, height: 7)
            RoundedRectangle(cornerRadius: LensGlassMetrics.chromeCornerRadius, style: .continuous)
                .fill(.primary.opacity(0.12))
                .frame(height: 7)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: LensGlassMetrics.chromeCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.16))
                RoundedRectangle(cornerRadius: LensGlassMetrics.chromeCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: LensGlassMetrics.chromeCornerRadius, style: .continuous)
                    .fill(.primary.opacity(0.16))
            }
            .frame(height: 28)
            Spacer(minLength: 0)
        }
    }

    private var slider: some View {
        VStack(spacing: LensSpacing.s) {
            sliderControl
            HStack {
                Text("更广")
                Spacer()
                Text("适中")
                Spacer()
                Text("更近")
            }
            .font(.system(size: LensType.micro, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private var sliderControl: some View {
        Slider(
            value: $scale,
            in: RecordingExperiencePreset.automaticZoomScaleRange,
            step: 0.05
        )
        .tint(LensGlassPalette.accent)
        .accessibilityLabel("自动运镜推近")
        .accessibilityValue(String(format: "%.2f倍", scale))
        .accessibilityHint("点击后镜头放大画面的程度，数值越小看到的界面越多")
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: LensSpacing.s) {
            Text("新录屏默认用这个倍率；已经打开的成片仍可在编辑器里单独调整。")
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LensSpacing.s)
            if !isDefault {
                Button("恢复默认") {
                    onRestoreDefault()
                }
                .buttonStyle(.plain)
                .font(.system(size: LensType.caption, weight: .semibold))
                .foregroundStyle(LensGlassPalette.accent)
                .accessibilityHint("恢复为 \(RecordingExperiencePreset.defaultAutomaticZoomScale) 倍")
            }
        }
    }

    private var previewCaption: String {
        if scale <= 1.05 {
            return "几乎不放大，整屏都看得见"
        }
        if scale <= 1.35 {
            return "轻推一点，周围界面还在"
        }
        if scale <= 1.8 {
            return "明显聚焦到点击位置"
        }
        return "推得很近，只留下局部"
    }

    private var highlightFill: some ShapeStyle {
        LinearGradient(
            colors: [
                LensGlassPalette.accent.opacity(0.16),
                LensGlassPalette.accentDeep.opacity(0.08),
                .primary.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LensGlassMetrics.cardCornerRadius,
            style: .continuous
        )
    }

    private var accentRibbon: some View {
        Text("调节这项")
            .font(.system(size: LensType.micro, weight: .bold))
            .foregroundStyle(LensGlassPalette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                LensGlassPalette.accent,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: LensGlassMetrics.badgeCornerRadius,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: LensGlassMetrics.cardCornerRadius,
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
    }
}
