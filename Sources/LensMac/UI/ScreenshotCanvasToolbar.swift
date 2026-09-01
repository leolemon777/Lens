import LensCore
import SwiftUI

struct ScreenshotCanvasToolbar: View {
    private struct Preset: Identifiable {
        let id: String
        let primary: LensColor
        let secondary: LensColor
    }

    @ObservedObject var model: ScreenshotAnnotationEditorModel

    var body: some View {
        HStack(spacing: 12) {
            enabledToggle
            if let style = model.canvasStyle {
                backgroundKindMenu(style)
                presetButtons
                aspectRatioMenu(style)
                adjustmentSlider(
                    title: "留白",
                    value: Binding(
                        get: { model.canvasStyle?.padding ?? style.padding },
                        set: { value in model.setCanvasPadding(value) }
                    ),
                    range: 0.02...0.24
                )
                adjustmentSlider(
                    title: "圆角",
                    value: Binding(
                        get: { model.canvasStyle?.cornerRadius ?? style.cornerRadius },
                        set: { value in model.setCanvasCornerRadius(value) }
                    ),
                    range: 0...0.10
                )
                shadowToggle(style)
            } else {
                Text("开启后可添加渐变或纯色画布、留白、圆角与阴影")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .lensGlassSurface(role: .chrome, cornerRadius: 0, tint: LensGlassPalette.ice)
    }

    private var enabledToggle: some View {
        Toggle("背景", isOn: Binding(
            get: { model.canvasStyle != nil },
            set: { enabled in model.setCanvasEnabled(enabled) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func backgroundKindMenu(_ style: ScreenshotCanvasStyle) -> some View {
        let current = model.canvasStyle?.backgroundKind ?? style.backgroundKind
        return Menu {
            Button("渐变") { model.setCanvasBackgroundKind(.gradient) }
            Button("纯色") { model.setCanvasBackgroundKind(.solid) }
        } label: {
            Label(current == .gradient ? "渐变" : "纯色", systemImage: "paintpalette")
        }
        .frame(width: 96)
    }

    private var presetButtons: some View {
        HStack(spacing: 5) {
            ForEach(presets) { preset in
                Button {
                    model.applyCanvasPreset(
                        primary: preset.primary,
                        secondary: preset.secondary
                    )
                } label: {
                    Circle()
                        .fill(LinearGradient(
                            colors: [
                                preset.primary.swiftUIColor,
                                preset.secondary.swiftUIColor
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 19, height: 19)
                        .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(preset.id)
                .accessibilityLabel("\(preset.id)背景预设")
                .accessibilityHint("应用截图画布背景颜色")
            }
        }
    }

    private func aspectRatioMenu(_ style: ScreenshotCanvasStyle) -> some View {
        let current = model.canvasStyle?.aspectRatio ?? style.aspectRatio
        return Menu {
            ForEach(ScreenshotCanvasAspectRatio.allCases, id: \.self) { ratio in
                Button(ratio.editorTitle) {
                    model.setCanvasAspectRatio(ratio)
                }
            }
        } label: {
            Label(current.editorTitle, systemImage: "aspectratio")
        }
        .frame(width: 96)
    }

    private func adjustmentSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Slider(value: value, in: range) { editing in
                if editing {
                    model.beginCanvasAdjustment()
                } else {
                    model.endCanvasAdjustment()
                }
            }
            .frame(width: 76)
            .accessibilityLabel("画布\(title)")
            .accessibilityValue(String(format: "%.2f", value.wrappedValue))
        }
    }

    private func shadowToggle(_ style: ScreenshotCanvasStyle) -> some View {
        Toggle("阴影", isOn: Binding(
            get: {
                let current = model.canvasStyle ?? style
                return current.shadowRadius > 0 && current.shadowOpacity > 0
            },
            set: { enabled in model.setCanvasShadowEnabled(enabled) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var presets: [Preset] {
        [
            Preset(
                id: "蓝紫",
                primary: LensColor(red: 0.20, green: 0.35, blue: 0.92),
                secondary: LensColor(red: 0.55, green: 0.22, blue: 0.88)
            ),
            Preset(
                id: "日落",
                primary: LensColor(red: 1.00, green: 0.36, blue: 0.29),
                secondary: LensColor(red: 0.98, green: 0.68, blue: 0.25)
            ),
            Preset(
                id: "薄荷",
                primary: LensColor(red: 0.08, green: 0.68, blue: 0.58),
                secondary: LensColor(red: 0.18, green: 0.42, blue: 0.88)
            ),
            Preset(
                id: "深色",
                primary: LensColor(red: 0.06, green: 0.07, blue: 0.11),
                secondary: LensColor(red: 0.19, green: 0.22, blue: 0.30)
            )
        ]
    }
}
