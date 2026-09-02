import LensCore
import SwiftUI

struct VideoEditorInspectorView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    @Binding var inspectorScrollPosition: VideoEditorInspectorSection?
    @Binding var isCaptionCueEditorExpanded: Bool
    @Binding var isAdvancedCameraExpanded: Bool
    @Binding var isCursorDetailExpanded: Bool
    @Binding var isClickDetailExpanded: Bool
    @Binding var showsAdvancedEditingTools: Bool
    @Binding var inspectorMode: VideoEditorInspectorMode
    let initialInspectorSection: VideoEditorInspectorSection?
    let onRegenerateCamera: () -> Void
    let onRefreshPreview: () -> Void
    let onExport: () -> Void
    let onExportStepDocument: () -> Void
    let onExportNarrationDraft: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            inspectorModePicker
            Divider().opacity(0.32)
            ScrollView {
                VStack(spacing: 12) {
                inspectorSection("画面", symbol: "rectangle.inset.filled") {
                    Label(
                        playback.isShowingRenderedPreview
                            ? "当前是上次生成的成片；调整后自动切到实时预览"
                            : "画布正在实时预览",
                        systemImage: playback.isShowingRenderedPreview
                            ? "clock.arrow.circlepath"
                            : "bolt.fill"
                    )
                    .font(.system(size: LensType.micro, weight: .medium))
                    .foregroundStyle(
                        playback.isShowingRenderedPreview ? Color.secondary : LensGlassPalette.accent
                    )
                    Toggle("背景画布", isOn: Binding(
                        get: { model.canvasEnabled },
                        set: { model.setCanvasEnabled($0) }
                    ))
                    valueSlider(
                        "留白",
                        value: Binding(
                            get: { model.plan.canvas?.margin ?? 0.055 },
                            set: { model.setCanvasMargin($0) }
                        ),
                        range: 0...0.18
                    )
                    valueSlider(
                        "圆角",
                        value: Binding(
                            get: { model.plan.canvas?.cornerRadius ?? 0.026 },
                            set: { model.setCanvasCornerRadius($0) }
                        ),
                        range: 0...0.12
                    )
                    valueSlider(
                        "阴影",
                        value: Binding(
                            get: { model.plan.canvas?.shadowOpacity ?? 0.24 },
                            set: { model.setCanvasShadowOpacity($0) }
                        ),
                        range: 0...0.65
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("背景")
                            Spacer()
                            Text(selectedCanvasPresetTitle)
                                .font(.system(size: LensType.micro, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: [GridItem(
                                .adaptive(minimum: 28, maximum: 28),
                                spacing: 10
                            )],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(VideoEditorCanvasBackgroundPreset.all) { preset in
                                canvasPresetButton(
                                    preset,
                                    selected: preset.matches(model.plan.canvas)
                                ) {
                                    model.setCanvasPreset(
                                        topHex: preset.topHex,
                                        bottomHex: preset.bottomHex
                                    )
                                }
                            }
                        }
                    }
                }

                inspectorSection("运镜与交互", symbol: "camera.metering.center.weighted") {
                    Toggle("自动运镜", isOn: Binding(
                        get: { model.cameraMotionEnabled },
                        set: {
                            model.setCameraMotionEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    Toggle("点击自动推近", isOn: Binding(
                        get: { model.plan.camera.clickToZoom },
                        set: {
                            model.setClickToZoomEnabled($0)
                            onRegenerateCamera()
                        }
                    ))
                    Toggle("无点击时跟随光标", isOn: Binding(
                        get: { model.plan.camera.followPointer },
                        set: {
                            model.setCameraFollowPointerEnabled($0)
                            onRegenerateCamera()
                        }
                    ))
                    valueSlider(
                        "推近倍率",
                        value: Binding(
                            get: { model.plan.camera.resolvedZoomScale },
                            set: { model.setAutomaticZoomScale($0) }
                        ),
                        range: 1...3,
                        step: 0.05,
                        suffix: "×",
                        onEditingEnded: onRegenerateCamera
                    )
                    Picker(
                        "生成强度",
                        selection: Binding(
                            get: { model.plan.camera.generationStrength },
                            set: {
                                model.setAutomaticCameraGenerationStrength($0)
                                onRegenerateCamera()
                            }
                        )
                    ) {
                        Text("克制").tag(AutoEditPlan.Camera.GenerationStrength.restrained)
                        Text("适中").tag(AutoEditPlan.Camera.GenerationStrength.balanced)
                        Text("积极").tag(AutoEditPlan.Camera.GenerationStrength.active)
                    }
                    .pickerStyle(.segmented)
                    Button(action: onRegenerateCamera) {
                        HStack(spacing: 6) {
                            if model.isRegeneratingCamera || model.isProcessing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            }
                            Text(cameraGenerationButtonTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRegeneratingCamera || model.isProcessing)
                    .help("点击后把目标平滑带到视觉中心；无点击演示才跟随光标")
                    Text(automaticCameraPlanSummary)
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)

                    DisclosureGroup(isExpanded: $isAdvancedCameraExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            valueSlider(
                                "运动模糊",
                                value: Binding(
                                    get: { model.plan.camera.motionBlurStrength },
                                    set: { model.setCameraMotionBlurStrength($0) }
                                ),
                                range: 0...1,
                                onEditingEnded: onRefreshPreview
                            )
                            Divider().opacity(0.28)
                            Label("手动点选镜头（不改变自动运镜）", systemImage: "scope")
                                .font(.system(size: LensType.micro, weight: .semibold))
                                .foregroundStyle(.secondary)
                            valueSlider(
                                "点选倍率",
                                value: $model.manualCameraScale,
                                range: 1.2...3
                            )
                            valueSlider(
                                "点选停留",
                                value: $model.manualCameraHoldSeconds,
                                range: 0.3...4
                            )
                            HStack(spacing: 6) {
                                Button {
                                    if model.isManualCameraFocusEditing {
                                        model.cancelManualCameraFocusEditing()
                                    } else {
                                        playback.showRawPreview()
                                        model.activateManualCameraFocusEditing()
                                    }
                                } label: {
                                    Label(
                                        model.isManualCameraFocusEditing
                                            ? "取消点选"
                                            : "点选缩放位置",
                                        systemImage: model.isManualCameraFocusEditing
                                            ? "xmark.circle"
                                            : "scope"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(model.isManualCameraFocusEditing ? LensGlassPalette.warning : LensGlassPalette.accent)
                                if model.manualCameraFocusCount > 0 {
                                    Button("清除 \(model.manualCameraFocusCount) 处") {
                                        model.clearManualCameraFocuses()
                                        onRefreshPreview()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            Text(model.isManualCameraFocusEditing
                                ? "已切到原始画面；点击预览即在当前播放头添加缩放。"
                                : "有点击时，镜头只以被点击目标构图并稳定停留；没有点击时，才会响应明确的光标移动。")
                                .font(.system(size: LensType.micro, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("高级运镜", systemImage: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }

                inspectorSection("光标与点击", symbol: "cursorarrow.rays") {
                    Toggle("重绘光标", isOn: Binding(
                        get: { model.cursorEnabled },
                        set: {
                            model.setCursorEnabled($0)
                            onRefreshPreview()
                        }
                    ))

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                        spacing: 7
                    ) {
                        ForEach(cursorAppearanceOptions, id: \.value) { option in
                            LensCursorStyleTileButton(
                                title: option.title,
                                help: option.help,
                                isSelected: model.plan.cursor.appearance == option.value
                            ) {
                                LensCursorAppearancePreview(
                                    appearance: option.value,
                                    accent: cursorAccent
                                )
                            } action: {
                                model.setCursorAppearance(option.value)
                                onRefreshPreview()
                            }
                            .disabled(!model.cursorEnabled)
                        }
                    }
                    Text(cursorAppearanceDescription)
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .disabled(!model.cursorEnabled)

                    HStack(spacing: 7) {
                        ForEach(cursorFollowStyleOptions, id: \.value) { option in
                            LensCursorStyleTileButton(
                                title: option.title,
                                help: option.help,
                                isSelected: (model.plan.cursor.followStyle ?? .custom) == option.value
                            ) {
                                LensCursorFollowPreview(
                                    style: option.value,
                                    accent: cursorAccent
                                )
                            } action: {
                                model.setCursorFollowStyle(option.value)
                                onRefreshPreview()
                            }
                        }
                    }
                    .disabled(!model.cursorEnabled)
                    Text(cursorFollowStyleDescription)
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                        .disabled(!model.cursorEnabled)

                    DisclosureGroup(isExpanded: $isCursorDetailExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            valueSlider(
                                "光标大小",
                                value: Binding(
                                    get: { model.plan.cursor.scale },
                                    set: { model.setCursorScale($0) }
                                ),
                                range: 0.7...2.2,
                                onEditingEnded: onRefreshPreview
                            )
                            HStack(spacing: 7) {
                                ForEach(cursorMotionEffectOptions, id: \.value) { option in
                                    LensCursorStyleTileButton(
                                        title: option.title,
                                        help: option.help,
                                        isSelected: model.plan.cursor.motionEffect == option.value
                                    ) {
                                        LensCursorMotionPreview(
                                            effect: option.value,
                                            accent: cursorAccent
                                        )
                                    } action: {
                                        model.setCursorMotionEffect(option.value)
                                        onRefreshPreview()
                                    }
                                }
                            }
                            valueSlider(
                                "特效强度",
                                value: Binding(
                                    get: { model.plan.cursor.motionEffectStrength },
                                    set: { model.setCursorMotionEffectStrength($0) }
                                ),
                                range: 0.1...1,
                                onEditingEnded: onRefreshPreview
                            )
                            .disabled(model.plan.cursor.motionEffect == .none)
                            .opacity(model.plan.cursor.motionEffect == .none ? 0.45 : 1)
                            HStack(spacing: 10) {
                                Text("特效颜色")
                                    .frame(width: 62, alignment: .leading)
                                ForEach(cursorAccentColors, id: \.hex) { option in
                                    let isSelected = model.plan.cursor.accentColorHex == option.hex
                                    Button {
                                        model.setCursorAccentColorHex(option.hex)
                                        onRefreshPreview()
                                    } label: {
                                        Circle()
                                            .fill(VideoEditorCanvasColor.color(
                                                hex: option.hex,
                                                fallback: LensGlassPalette.accent
                                            ))
                                            .frame(width: 18, height: 18)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.35),
                                                lineWidth: 0.8
                                            ))
                                            .overlay {
                                                if model.plan.cursor.accentColorHex == option.hex {
                                                    Circle().stroke(LensGlassPalette.accent, lineWidth: 2)
                                                        .frame(width: 23, height: 23)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help(option.name)
                                    .accessibilityLabel("光标特效颜色：\(option.name)")
                                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                                }
                            }
                            HStack(spacing: 8) {
                                Text("平滑窗口")
                                    .frame(width: 62, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: {
                                            model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                        },
                                        set: {
                                            model.setCursorSmoothingWindowMilliseconds($0)
                                        }
                                    ),
                                    in: 0...120,
                                    onEditingChanged: { isEditing in
                                        if !isEditing { onRefreshPreview() }
                                    }
                                )
                                .accessibilityLabel("光标平滑窗口")
                                .accessibilityValue(String(
                                    format: "%.0f 毫秒",
                                    model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                ))
                                Text(String(
                                    format: "%.0fms",
                                    model.plan.cursor.resolvedSmoothingWindowMilliseconds
                                ))
                                .font(.system(
                                    size: LensType.micro,
                                    weight: .medium,
                                    design: .monospaced
                                ))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                            }
                            .disabled(
                                model.plan.cursor.followStyle != nil
                                    && model.plan.cursor.followStyle != .custom
                            )
                            .opacity(
                                model.plan.cursor.followStyle == nil
                                    || model.plan.cursor.followStyle == .custom
                                    ? 1 : 0.45
                            )
                            Toggle("静止时隐藏", isOn: Binding(
                                get: { model.plan.cursor.hidesWhenIdle },
                                set: {
                                    model.setCursorHidesWhenIdle($0)
                                    onRefreshPreview()
                                }
                            ))
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("光标细节", systemImage: "cursorarrow.motionlines")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .disabled(!model.cursorEnabled)
                    .opacity(model.cursorEnabled ? 1 : 0.48)

                    Toggle("点击反馈", isOn: Binding(
                        get: { model.clickPulseEnabled },
                        set: {
                            model.setClickPulseEnabled($0)
                            onRefreshPreview()
                        }
                    ))

                    DisclosureGroup(isExpanded: $isClickDetailExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("显示按键", isOn: Binding(
                                get: { model.plan.interaction?.showsKeystrokes ?? false },
                                set: {
                                    model.setKeystrokesEnabled($0)
                                    onRefreshPreview()
                                }
                            ))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("点击效果")
                                    .font(.system(size: LensType.micro, weight: .medium))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 7) {
                                    ForEach(clickEffectOptions, id: \.value) { option in
                                        LensCursorStyleTileButton(
                                            title: option.title,
                                            help: option.help,
                                            isSelected: (model.plan.interaction?.clickEffect ?? .ripple) == option.value
                                        ) {
                                            LensClickEffectPreview(
                                                effect: option.value,
                                                accent: cursorAccent
                                            )
                                        } action: {
                                            model.setClickEffect(option.value)
                                            onRefreshPreview()
                                        }
                                    }
                                }
                            }
                            valueSlider(
                                "效果强度",
                                value: Binding(
                                    get: {
                                        model.plan.interaction?.clickEffectStrength ?? 1
                                    },
                                    set: { model.setClickEffectStrength($0) }
                                ),
                                range: 0.1...1,
                                onEditingEnded: onRefreshPreview
                            )
                            valueSlider(
                                "效果大小",
                                value: Binding(
                                    get: { model.plan.interaction?.clickPulseScale ?? 1.25 },
                                    set: { model.setClickPulseScale($0) }
                                ),
                                range: 0.5...2,
                                onEditingEnded: onRefreshPreview
                            )
                            valueSlider(
                                "效果时长",
                                value: Binding(
                                    get: { model.plan.interaction?.clickPulseDuration ?? 0.62 },
                                    set: { model.setClickPulseDuration($0) }
                                ),
                                range: 0.15...1.2,
                                onEditingEnded: onRefreshPreview
                            )
                            HStack(spacing: 10) {
                                Text("效果颜色")
                                    .frame(width: 62, alignment: .leading)
                                ForEach(clickPulseColors, id: \.hex) { option in
                                    let isSelected = model.plan.interaction?.clickPulseColorHex == option.hex
                                    Button {
                                        model.setClickPulseColorHex(option.hex)
                                        onRefreshPreview()
                                    } label: {
                                        Circle()
                                            .fill(VideoEditorCanvasColor.color(
                                                hex: option.hex,
                                                fallback: LensGlassPalette.accent
                                            ))
                                            .frame(width: 18, height: 18)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.35),
                                                lineWidth: 0.8
                                            ))
                                            .overlay {
                                                if model.plan.interaction?.clickPulseColorHex
                                                    == option.hex {
                                                    Circle().stroke(LensGlassPalette.accent, lineWidth: 2)
                                                        .frame(width: 23, height: 23)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help(option.name)
                                    .accessibilityLabel("点击反馈颜色：\(option.name)")
                                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                                }
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("点击特效细节", systemImage: "cursorarrow.click.2")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .disabled(!model.clickPulseEnabled)
                    .opacity(model.clickPulseEnabled ? 1 : 0.48)
                }

                    Button {
                        let nextShowsAdvanced = !showsAdvancedEditingTools
                        showsAdvancedEditingTools = nextShowsAdvanced
                        inspectorMode = nextShowsAdvanced ? .advanced : .quick
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(LensGlassPalette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(showsAdvancedEditingTools ? "收起更多工具" : "更多编辑工具")
                                .font(.system(size: LensType.caption, weight: .semibold))
                            Text("视频标注 · 讲解人像 · 字幕 · 导出预设")
                                .font(.system(size: LensType.micro, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: showsAdvancedEditingTools
                            ? "chevron.up"
                            : "chevron.down")
                            .font(.system(size: LensIcon.small, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: LensGlassMetrics.controlCornerRadius, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAdvancedEditingTools
                    ? "收起更多编辑工具"
                    : "展开更多编辑工具")
                .accessibilityValue(showsAdvancedEditingTools ? "已展开" : "已收起")

                if showsAdvancedEditingTools {
                    inspectorSection("视频标注", symbol: "pencil.and.outline") {
                    HStack(spacing: 6) {
                        Button {
                            model.activateVideoAnnotationSelection()
                        } label: {
                            Label("选择", systemImage: "cursorarrow")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.isVideoAnnotationSelectionMode ? LensGlassPalette.accent : LensGlassPalette.neutral)
                        Button {
                            if model.isVideoAnnotationEditing {
                                model.finishVideoAnnotationEditing()
                            } else {
                                model.activateVideoAnnotationTool(
                                    model.selectedVideoAnnotationTool
                                )
                            }
                        } label: {
                            Label(
                                model.isVideoAnnotationEditing ? "完成" : "画布编辑",
                                systemImage: model.isVideoAnnotationEditing
                                    ? "checkmark.circle.fill"
                                    : "hand.draw"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.isVideoAnnotationEditing ? LensGlassPalette.success : LensGlassPalette.accent)
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                        spacing: 5
                    ) {
                        ForEach(ScreenshotAnnotationKind.allCases, id: \.self) { tool in
                            annotationToolButton(tool)
                        }
                    }

                    HStack(spacing: 7) {
                        Text("颜色")
                        Spacer()
                        ForEach(videoAnnotationColors, id: \.name) { item in
                            Button {
                                model.setVideoAnnotationColor(item.color)
                            } label: {
                                Circle()
                                    .fill(item.color.swiftUIColor)
                                    .frame(width: 17, height: 17)
                                    .overlay(Circle().stroke(
                                        model.selectedVideoAnnotationColor == item.color
                                            ? Color.primary
                                            : Color.white.opacity(0.30),
                                        lineWidth: model.selectedVideoAnnotationColor == item.color
                                            ? 2
                                            : 1
                                    ))
                                    .padding(2)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel("\(item.name)视频标注颜色")
                            .accessibilityValue(
                                model.selectedVideoAnnotationColor == item.color ? "已选择" : "未选择"
                            )
                            .accessibilityHint("选择视频标注颜色")
                            .accessibilityAddTraits(
                                model.selectedVideoAnnotationColor == item.color
                                    ? .isSelected
                                    : []
                            )
                        }
                    }

                    if model.selectedVideoAnnotationTool == .text
                        || model.selectedVideoAnnotation?.annotation.kind == .text {
                        HStack(spacing: 6) {
                            TextField("标注文字", text: $model.videoAnnotationTextDraft)
                                .textFieldStyle(.roundedBorder)
                            if model.selectedVideoAnnotation?.annotation.kind == .text {
                                Button("应用", action: model.applyVideoAnnotationTextDraft)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }

                    valueSlider(
                        model.selectedVideoAnnotation == nil ? "默认时长" : "显示时长",
                        value: Binding(
                            get: {
                                model.selectedVideoAnnotation?.sourceDurationSeconds
                                    ?? model.defaultVideoAnnotationDurationSeconds
                            },
                            set: { model.setSelectedVideoAnnotationDuration($0) }
                        ),
                        range: 0.05...30
                    )

                    if let selected = model.selectedVideoAnnotation {
                        valueSlider(
                            "淡入淡出",
                            value: Binding(
                                get: { selected.fadeDurationSeconds },
                                set: { model.setSelectedVideoAnnotationFadeDuration($0) }
                            ),
                            range: 0...0.8
                        )
                        if selected.annotation.kind == .blur
                            || selected.annotation.kind == .pixelate {
                            valueSlider(
                                "效果强度",
                                value: Binding(
                                    get: { selected.annotation.style.intensity },
                                    set: { model.setSelectedVideoAnnotationIntensity($0) }
                                ),
                                range: 0.01...0.12
                            )
                        } else if selected.annotation.kind != .highlight
                            && selected.annotation.kind != .step
                            && selected.annotation.kind != .text {
                            valueSlider(
                                "线条粗细",
                                value: Binding(
                                    get: { selected.annotation.style.lineWidth },
                                    set: { model.setSelectedVideoAnnotationLineWidth($0) }
                                ),
                                range: 0.002...0.04
                            )
                        }
                        HStack {
                            Text(String(
                                format: "源素材 %.2f–%.2f s",
                                selected.sourceStartSeconds,
                                selected.sourceEndSeconds
                            ))
                            .font(.system(size: LensType.micro, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button("删除") {
                                model.deleteSelectedVideoAnnotation()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(LensGlassPalette.recording)
                        }
                    }

                    Text(model.isVideoAnnotationEditing
                        ? "在预览中拖动绘制；选择工具可移动并拖拽控制点缩放。"
                        : "标注使用源素材时间，剪切、变速与重排后仍会自动对齐。")
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                    inspectorSection("讲解人像", symbol: "person.crop.circle") {
                    Toggle("显示摄像头", isOn: Binding(
                        get: { model.presenterEnabled },
                        set: { model.setPresenterEnabled($0) }
                    ))
                    .disabled(!model.hasCameraTrack)
                    if model.hasCameraTrack {
                        HStack(spacing: 6) {
                            Text("形状")
                            Spacer()
                            choiceButton(
                                "圆形",
                                selected: model.plan.presenterCamera?.shape != .roundedRectangle
                            ) {
                                model.setPresenterShape(.circle)
                            }
                            choiceButton(
                                "圆角矩形",
                                selected: model.plan.presenterCamera?.shape == .roundedRectangle
                            ) {
                                model.setPresenterShape(.roundedRectangle)
                            }
                        }
                        HStack(spacing: 5) {
                            Text("位置")
                            Spacer()
                            ForEach([
                                ("左上", AutoEditPlan.PresenterCamera.Anchor.topLeading),
                                ("右上", AutoEditPlan.PresenterCamera.Anchor.topTrailing),
                                ("左下", AutoEditPlan.PresenterCamera.Anchor.bottomLeading),
                                ("右下", AutoEditPlan.PresenterCamera.Anchor.bottomTrailing)
                            ], id: \.0) { item in
                                choiceButton(
                                    item.0,
                                    selected: model.plan.presenterCamera?.position == nil
                                        && model.plan.presenterCamera?.anchor == item.1
                                ) {
                                    model.setPresenterAnchor(item.1)
                                }
                            }
                        }
                        valueSlider(
                            "大小",
                            value: Binding(
                                get: { model.plan.presenterCamera?.size ?? 0.19 },
                                set: { model.setPresenterSize($0) }
                            ),
                            range: 0.10...0.36
                        )
                        Toggle("镜像", isOn: Binding(
                            get: { model.plan.presenterCamera?.isMirrored != false },
                            set: { model.setPresenterMirrored($0) }
                        ))
                        Toggle("自动避让字幕与点击焦点", isOn: Binding(
                            get: { model.presenterAvoidanceEnabled },
                            set: { model.setPresenterAvoidanceEnabled($0) }
                        ))
                        Text("可直接在画布拖动人像，右下角控制点调整大小。")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            let hasKeyframe = model.hasPresenterKeyframe(
                                nearOutputTime: playback.currentTimeSeconds
                            )
                            Button {
                                if let time = model.previousPresenterKeyframeOutputTime(
                                    before: playback.currentTimeSeconds
                                ) {
                                    playback.seek(to: time)
                                }
                            } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.previousPresenterKeyframeOutputTime(
                                before: playback.currentTimeSeconds
                            ) == nil)
                            .accessibilityLabel("上一个讲解人像关键帧")
                            Button {
                                if let time = model.nextPresenterKeyframeOutputTime(
                                    after: playback.currentTimeSeconds
                                ) {
                                    playback.seek(to: time)
                                }
                            } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.nextPresenterKeyframeOutputTime(
                                after: playback.currentTimeSeconds
                            ) == nil)
                            .accessibilityLabel("下一个讲解人像关键帧")
                            Button(hasKeyframe ? "更新当前关键帧" : "添加当前关键帧") {
                                model.upsertPresenterKeyframe(
                                    atOutputTime: playback.currentTimeSeconds
                                )
                            }
                            .buttonStyle(.bordered)
                            if hasKeyframe {
                                Button("删除") {
                                    model.removePresenterKeyframe(
                                        nearOutputTime: playback.currentTimeSeconds
                                    )
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(LensGlassPalette.recording)
                            }
                            Spacer()
                            Text("\(model.presenterKeyframeCount) 帧")
                                .font(.system(size: LensType.micro, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .disabled(!model.presenterEnabled)
                        if let easing = model.presenterKeyframeEasing(
                            nearOutputTime: playback.currentTimeSeconds
                        ) {
                            Picker("关键帧过渡", selection: Binding(
                                get: { easing },
                                set: {
                                    model.setPresenterKeyframeEasing(
                                        $0,
                                        atOutputTime: playback.currentTimeSeconds
                                    )
                                }
                            )) {
                                Text("柔和弹性").tag("spring-gentle")
                                Text("平滑").tag("spring-smooth")
                                Text("线性").tag("linear")
                                Text("渐入").tag("ease-in")
                                Text("渐出").tag("ease-out")
                            }
                            .pickerStyle(.menu)
                        }
                    } else {
                        Text("这条录屏没有摄像头原始轨。")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    }
                }

                if inspectorMode == .advanced {
                    inspectorSection("声音", symbol: "waveform") {
                    Toggle("启用混音", isOn: Binding(
                        get: { model.audioEnabled },
                        set: {
                            model.setAudioEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    valueSlider(
                        "系统声音",
                        value: Binding(
                            get: { model.plan.audio?.systemVolume ?? 1 },
                            set: { model.setSystemVolume($0) }
                        ),
                        range: 0...1.5,
                        onEditingEnded: onRefreshPreview
                    )
                    if model.hasMicrophoneTrack {
                        Toggle("一键人声增强", isOn: Binding(
                            get: { model.appliedVoiceEnhancementLevel != nil },
                            set: {
                                model.setVoiceEnhancement($0 ? .standard : nil)
                                onRefreshPreview()
                            }
                        ))
                        if let level = model.appliedVoiceEnhancementLevel {
                            Picker("增强强度", selection: Binding(
                                get: { level },
                                set: {
                                    model.setVoiceEnhancement($0)
                                    onRefreshPreview()
                                }
                            )) {
                                Text("轻").tag(AutoEditPlan.Audio.VoiceEnhancementLevel.light)
                                Text("标准").tag(AutoEditPlan.Audio.VoiceEnhancementLevel.standard)
                                Text("强").tag(AutoEditPlan.Audio.VoiceEnhancementLevel.strong)
                            }
                            .pickerStyle(.segmented)
                        }
                        Toggle("试听未处理", isOn: Binding(
                            get: { model.isAuditioningUnprocessedAudio },
                            set: {
                                model.setUnprocessedAudition($0)
                                onRefreshPreview()
                            }
                        ))
                        .disabled(model.appliedVoiceEnhancementLevel == nil
                            && model.isAuditioningUnprocessedAudio == false)
                        valueSlider(
                            "麦克风",
                            value: Binding(
                                get: { model.plan.audio?.microphoneVolume ?? 1 },
                                set: { model.setMicrophoneVolume($0) }
                            ),
                            range: 0...1.5,
                            onEditingEnded: onRefreshPreview
                        )
                        Toggle("降低环境噪声", isOn: Binding(
                            get: { model.microphoneNoiseReductionEnabled },
                            set: {
                                model.setMicrophoneNoiseReductionEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        if model.microphoneNoiseReductionEnabled {
                            valueSlider(
                                "降噪强度",
                                value: Binding(
                                    get: { model.plan.audio?.noiseReductionAmount ?? 0.55 },
                                    set: { model.setNoiseReductionAmount($0) }
                                ),
                                range: 0...1,
                                onEditingEnded: onRefreshPreview
                            )
                        }
                        Toggle("统一人声与系统响度", isOn: Binding(
                            get: { model.loudnessNormalizationEnabled },
                            set: {
                                model.setLoudnessNormalizationEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        if model.loudnessNormalizationEnabled {
                            Picker("人声目标响度", selection: Binding(
                                get: { model.plan.audio?.targetLoudnessLUFS ?? -16 },
                                set: {
                                    model.setTargetLoudnessLUFS($0)
                                    onRefreshPreview()
                                }
                            )) {
                                Text("响亮 · −14 LUFS").tag(-14.0)
                                Text("标准 · −16 LUFS").tag(-16.0)
                                Text("舒缓 · −18 LUFS").tag(-18.0)
                                Text("保守 · −20 LUFS").tag(-20.0)
                            }
                            .pickerStyle(.menu)
                        }
                        Toggle("讲话时自动压低系统声", isOn: Binding(
                            get: { model.plan.audio?.ducksSystemUnderNarration != false },
                            set: {
                                model.setDuckingEnabled($0)
                                onRefreshPreview()
                            }
                        ))
                        Text("降噪与响度处理仅作用于生成的预览，原始麦克风轨保持不变。")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                    if model.hasMicrophoneTrack {
                        inspectorSection("旁白清理", symbol: "scissors") {
                            narrationTrimSection
                        }
                    }
                }

                if showsAdvancedEditingTools {
                    inspectorSection("字幕", symbol: "captions.bubble") {
                    Toggle("烧录字幕", isOn: Binding(
                        get: { model.captionsEnabled },
                        set: {
                            model.setCaptionsEnabled($0)
                            onRefreshPreview()
                        }
                    ))
                    .disabled(!model.hasTranscript)
                    if model.hasTranscript {
                        Toggle("逐词高亮", isOn: Binding(
                            get: { model.plan.captions?.highlightsSpokenWords ?? false },
                            set: {
                                model.setCaptionsWordHighlight($0)
                                onRefreshPreview()
                            }
                        ))
                        .disabled(!model.captionsEnabled)
                        Button(action: onExportNarrationDraft) {
                            Label("导出配音草稿…", systemImage: "waveform.badge.mic")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("用系统语音把转写合成为本地音频草稿（CAF），全程不离机")
                    }
                    if model.hasTranscript {
                        HStack(spacing: 5) {
                            Text("样式")
                            Spacer()
                            choiceButton(
                                "玻璃",
                                selected: (model.plan.captions?.style ?? .glass) == .glass
                            ) {
                                model.setCaptionStyle(.glass)
                                onRefreshPreview()
                            }
                            choiceButton(
                                "简洁",
                                selected: model.plan.captions?.style == .clean
                            ) {
                                model.setCaptionStyle(.clean)
                                onRefreshPreview()
                            }
                            choiceButton(
                                "高对比",
                                selected: model.plan.captions?.style == .highContrast
                            ) {
                                model.setCaptionStyle(.highContrast)
                                onRefreshPreview()
                            }
                        }
                        HStack(spacing: 5) {
                            Text("位置")
                            Spacer()
                            ForEach([
                                ("顶部", AutoEditPlan.Captions.Position.top),
                                ("居中", AutoEditPlan.Captions.Position.center),
                                ("底部", AutoEditPlan.Captions.Position.bottom)
                            ], id: \.0) { item in
                                choiceButton(
                                    item.0,
                                    selected: (model.plan.captions?.position ?? .bottom) == item.1
                                ) {
                                    model.setCaptionPosition(item.1)
                                    onRefreshPreview()
                                }
                            }
                        }
                        valueSlider(
                            "字号",
                            value: Binding(
                                get: { model.plan.captions?.fontScale ?? 1 },
                                set: { model.setCaptionFontScale($0) }
                            ),
                            range: 0.75...1.5,
                            onEditingEnded: onRefreshPreview
                        )
                        Text("时码基于原始录屏；剪切、变速、重排后会自动映射到成片。")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)

                        DisclosureGroup(isExpanded: $isCaptionCueEditorExpanded) {
                            LazyVStack(spacing: 8) {
                                ForEach(
                                    Array(model.captionSourceCues.enumerated()),
                                    id: \.offset
                                ) { index, cue in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 5) {
                                            Button {
                                                model.selectCaptionCue(at: index)
                                                if let time = model.primaryCaptionOutputTime(at: index) {
                                                    playback.seek(to: time)
                                                }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: LensIcon.small, weight: .bold))
                                                    Text(String(
                                                        format: "%@ – %@",
                                                        VideoEditorFormatting.captionTimeText(cue.sourceStartSeconds),
                                                        VideoEditorFormatting.captionTimeText(cue.sourceEndSeconds)
                                                    ))
                                                    .font(.system(
                                                        size: LensType.micro,
                                                        weight: .semibold,
                                                        design: .monospaced
                                                    ))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(
                                                model.selectedCaptionCueIndex == index
                                                    ? LensGlassPalette.accent
                                                    : Color.secondary
                                            )
                                            .accessibilityLabel("播放第 \(index + 1) 条字幕")
                                            .accessibilityValue(String(
                                                format: "%@ 到 %@",
                                                VideoEditorFormatting.captionTimeText(cue.sourceStartSeconds),
                                                VideoEditorFormatting.captionTimeText(cue.sourceEndSeconds)
                                            ))
                                            Spacer(minLength: 2)
                                            Text("入")
                                                .font(.system(size: LensType.micro, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                            TextField("", value: Binding(
                                                get: {
                                                    let cues = model.captionSourceCues
                                                    return cues.indices.contains(index)
                                                        ? cues[index].sourceStartSeconds
                                                        : 0
                                                },
                                                set: { model.setCaptionCueStart($0, at: index) }
                                            ), format: .number.precision(.fractionLength(2)))
                                            .multilineTextAlignment(.trailing)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 45)
                                            .onSubmit(onRefreshPreview)
                                            Text("出")
                                                .font(.system(size: LensType.micro, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                            TextField("", value: Binding(
                                                get: {
                                                    let cues = model.captionSourceCues
                                                    return cues.indices.contains(index)
                                                        ? cues[index].sourceEndSeconds
                                                        : 0
                                                },
                                                set: { model.setCaptionCueEnd($0, at: index) }
                                            ), format: .number.precision(.fractionLength(2)))
                                            .multilineTextAlignment(.trailing)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 45)
                                            .onSubmit(onRefreshPreview)
                                        }
                                        TextField("留空可隐藏这条字幕", text: Binding(
                                            get: {
                                                let cues = model.captionSourceCues
                                                return cues.indices.contains(index)
                                                    ? cues[index].text
                                                    : ""
                                            },
                                            set: { model.setCaptionCueText($0, at: index) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit(onRefreshPreview)
                                        HStack(spacing: 10) {
                                            Button("在播放头分割") {
                                                model.selectCaptionCue(at: index)
                                                model.splitCaptionCue(
                                                    at: index,
                                                    atOutputTime: playback.currentTimeSeconds
                                                )
                                                onRefreshPreview()
                                            }
                                            .disabled(!model.canSplitCaptionCue(
                                                at: index,
                                                atOutputTime: playback.currentTimeSeconds
                                            ))
                                            Button("与下一条合并") {
                                                model.selectCaptionCue(at: index)
                                                model.mergeCaptionCueWithNext(at: index)
                                                onRefreshPreview()
                                            }
                                            .disabled(index + 1 >= model.captionSourceCues.count)
                                            Spacer()
                                            Button(role: .destructive) {
                                                model.deleteCaptionCue(at: index)
                                                onRefreshPreview()
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .help("删除这条自定义字幕；原始转写仍会保留")
                                            .accessibilityLabel("删除第 \(index + 1) 条字幕")
                                            .accessibilityHint("原始转写仍会保留")
                                        }
                                        .font(.system(size: LensType.micro, weight: .semibold))
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(7)
                                    .background(
                                        model.selectedCaptionCueIndex == index
                                            ? LensGlassPalette.accent.opacity(0.08)
                                            : Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(
                                                model.selectedCaptionCueIndex == index
                                                    ? LensGlassPalette.accent.opacity(0.35)
                                                    : Color.primary.opacity(0.045),
                                                lineWidth: 0.7
                                            )
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectCaptionCue(at: index) }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("校对文字 · \(model.captionSourceCues.count) 条")
                                .font(.system(size: LensType.micro, weight: .semibold))
                        }
                        if model.plan.captions?.customCues != nil {
                            Button("恢复本机转写原文") {
                                model.restoreAutomaticCaptionText()
                                onRefreshPreview()
                            }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("先回到 Lens 库点击「转写」，本机识别后即可编辑和烧录。")
                            .font(.system(size: LensType.micro, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                    .id(VideoEditorInspectorSection.captions)

                    inspectorSection("导出", symbol: "square.and.arrow.up") {
                    Picker("质量预设", selection: Binding(
                        get: { model.exportPreset },
                        set: { model.setExportPreset($0) }
                    )) {
                        Text("原画").tag(AutoEditPlan.Export.Preset.source)
                        Text("平衡").tag(AutoEditPlan.Export.Preset.balanced)
                        Text("轻量").tag(AutoEditPlan.Export.Preset.compact)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text(exportPresetDescription)
                        .font(.system(size: LensType.micro, weight: .medium))
                        .foregroundStyle(.secondary)
                    let aspectRatioBinding = Binding<AutoEditPlan.Export.AspectRatio?>(
                        get: { model.plan.export?.aspectRatio },
                        set: { newValue in
                            model.setExportAspectRatio(newValue)
                            onRefreshPreview()
                        }
                    )
                    Picker("导出画幅", selection: aspectRatioBinding) {
                        Text("跟随源").tag(AutoEditPlan.Export.AspectRatio?.none)
                        Text("竖屏 9:16").tag(AutoEditPlan.Export.AspectRatio?.some(.vertical9x16))
                        Text("方形 1:1").tag(AutoEditPlan.Export.AspectRatio?.some(.square1x1))
                    }
                    .pickerStyle(.segmented)
                    Text("切换画幅时运镜自动重新构图，内容完整居中。")
                        .font(.system(size: LensType.micro))
                        .foregroundStyle(.secondary)
                    Label(
                        "MP4 · H.264 · 适合即时分享",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.success)
                    Divider().opacity(0.4)
                    Button(action: onExportStepDocument) {
                        Label("导出步骤文档…", systemImage: "list.number")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("把每次点击生成带截图的编号步骤（Markdown + PNG）")
                }
                    .id(VideoEditorInspectorSection.export)
                }

                Button("恢复到打开时的方案", action: model.resetToAutomaticPlan)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(LensSpacing.card)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $inspectorScrollPosition, anchor: .top)
            .defaultScrollAnchor(initialInspectorSection == nil ? .top : .bottom)
        }
        .frame(minWidth: 292, idealWidth: 320, maxWidth: 360)
        .lensGlassSurface(role: .chrome, cornerRadius: 0)
    }

    private var inspectorModePicker: some View {
        HStack(spacing: 8) {
            Label("编辑方式", systemImage: "wand.and.stars")
                .font(.system(size: LensType.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("编辑方式", selection: $inspectorMode) {
                ForEach(VideoEditorInspectorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: inspectorMode) { _, mode in
                showsAdvancedEditingTools = mode == .advanced
            }
        }
        .padding(.horizontal, LensSpacing.card)
        .padding(.vertical, LensSpacing.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("编辑方式")
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
            Divider().opacity(0.3)
            content()
                .font(.system(size: LensType.micro, weight: .medium))
        }
        .padding(LensSpacing.m)
        .lensGlassSurface(role: .card, cornerRadius: LensGlassMetrics.cardCornerRadius)
    }


    private func annotationToolButton(
        _ tool: ScreenshotAnnotationKind
    ) -> some View {
        let selected = model.isVideoAnnotationEditing
            && !model.isVideoAnnotationSelectionMode
            && model.selectedVideoAnnotationTool == tool
        return Button {
            model.activateVideoAnnotationTool(tool)
        } label: {
            Label(tool.editorTitle, systemImage: tool.editorSymbol)
                .font(.system(size: LensType.micro, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(
                    selected ? LensGlassPalette.accent.opacity(0.78) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: LensGlassMetrics.badgeCornerRadius)
                )
        }
        .buttonStyle(.plain)
        .help(tool.editorTitle)
    }

    private var videoAnnotationColors: [(name: String, color: LensColor)] {
        [
            ("红色", .red),
            ("橙色", .orange),
            ("黄色", .yellow), // lens-token-exempt: 用户标注调色板选项
            ("蓝色", .blue),
            ("白色", .white)
        ]
    }

    private var clickPulseColors: [(name: String, hex: String)] {
        [
            ("青色", "#00D9FF"),
            ("珊瑚", "#FF684D"),
            ("紫色", "#A855F7"),
            ("黄色", "#FACC15"),
            ("白色", "#FFFFFF")
        ]
    }

    private var cursorAccentColors: [(name: String, hex: String)] {
        [
            ("冰蓝", "#5BD6FF"),
            ("珊瑚", "#FF684D"),
            ("紫色", "#A855F7"),
            ("青柠", "#A3E635"),
            ("白色", "#FFFFFF")
        ]
    }

    private var cursorAccent: Color {
        VideoEditorCanvasColor.color(
            hex: model.plan.cursor.accentColorHex,
            fallback: LensGlassPalette.accent
        )
    }

    private var cursorAppearanceOptions: [(
        value: AutoEditPlan.Cursor.Appearance,
        title: String,
        help: String
    )] {
        [
            (.recorded, "跟随系统", "按录制时的状态还原箭头、手形、文本等形态。"),
            (.macOS, "macOS 箭头", "始终使用系统箭头。"),
            (.highContrast, "高对比", "白色高对比箭头。"),
            (.pointingHand, "趣味手势", "拟物指向小手，教学与短视频亲和力拉满。"),
            (.magicWand, "仙女棒", "魔法星光杖，突出产品高亮与奇妙功能。"),
            (.laser, "激光演示", "专业演讲激光红点，聚焦演示重点。"),
            (.pixelHand, "复古像素", "8-Bit 像素手套，极客与复古怀旧风格。"),
            (.highlighterPencil, "荧光画笔", "文档阅读与代码走查的批注铅笔。"),
            (.crosshairHUD, "战术准星", "高精度科技感 HUD 准星，适合像素级演示。"),
            (.rocket, "冲天火箭", "流线型飞船与动力尾焰，带来飞速成长感。"),
            (.minimalDot, "极简圆点", "用强调色圆点替代箭头。"),
            (.ring, "圆环指引", "指针上叠加强调色激光圆环。"),
            (.glowDot, "柔光光点", "强调色光点带柔和光晕。")
        ]
    }

    private var cursorFollowStyleOptions: [(
        value: AutoEditPlan.Cursor.FollowStyle,
        title: String,
        help: String
    )] {
        [
            (.faithful, "跟手", "逐帧贴合真实轨迹，不追加平滑。"),
            (.smooth, "平滑", "轻微平滑，接近真实观感。"),
            (.elastic, "悠然", "明显滑行感，适合慢节奏演示。"),
            (.custom, "自定义", "手动控制平滑窗口。")
        ]
    }

    private var cursorMotionEffectOptions: [(
        value: AutoEditPlan.Cursor.MotionEffect,
        title: String,
        help: String
    )] {
        [
            (.none, "无", "移动时不加光效。"),
            (.halo, "柔光", "指针周围跟随一团柔光。"),
            (.trail, "拖尾", "移动方向留下渐隐的轨迹点。"),
            (.spotlight, "聚光", "大面积柔光突出指针所在区域。")
        ]
    }

    private var clickEffectOptions: [(
        value: AutoEditPlan.Interaction.ClickEffect,
        title: String,
        help: String
    )] {
        [
            (.ripple, "双层波纹", "点击处扩散两圈波纹。"),
            (.pulse, "触点脉冲", "点击处一个实心脉冲圈。"),
            (.spotlight, "聚光点击", "点击处亮起一团柔光。")
        ]
    }

    private var cursorAppearanceDescription: String {
        switch model.plan.cursor.appearance {
        case .recorded:
            model.plan.cursor.shapeKeyframes.isEmpty
                ? "这条旧录屏没有形态轨道，将安全回退为 macOS 箭头。"
                : "按录制时状态还原箭头、手形、文本和缩放光标。"
        case .macOS:
            "始终使用系统箭头，适合风格统一的产品演示。"
        case .highContrast:
            "白色高对比箭头，在深色和复杂画面上都清楚。"
        case .pointingHand:
            "友好指引手势，大幅提升教程或展示视频的互动感与亲和力。"
        case .magicWand:
            "梦幻星光魔法棒，让每一个点击和高亮如同施加魔法般吸睛。"
        case .laser:
            "极简发光激光红点，完全去除箭头干扰，专注聚焦屏幕重点。"
        case .pixelHand:
            "8-Bit 像素复古手套，非常适合独立开发、极客展示与怀旧游戏录屏。"
        case .highlighterPencil:
            "醒目荧光画笔，笔尖精准落点，极度适合文档拆解、网课与代码 Review。"
        case .crosshairHUD:
            "科技感极简十字准星，适合高精度 UI/UX 设计演示与技术细节拆解。"
        case .rocket:
            "动感冲天小火箭，尾部喷射微光焰光，适合路演、增长发布与产品演示。"
        case .minimalDot:
            "用强调色圆点替代箭头，适合简洁的教程成片。"
        case .ring:
            "强调色激光圆环叠在指针上，观众视线一眼锁定落点。"
        case .glowDot:
            "强调色光点带柔和光晕，暗色界面里尤其醒目。"
        }
    }

    private var cursorFollowStyleDescription: String {
        switch model.plan.cursor.followStyle ?? .custom {
        case .faithful:
            "逐帧贴合真实轨迹，不追加任何平滑。"
        case .smooth:
            "轻微平滑，接近真实观感，默认推荐。"
        case .elastic:
            "明显滑行感，适合演示节奏放慢的教程。"
        case .custom:
            "手动控制平滑窗口。"
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        suffix: String = "",
        onEditingEnded: (() -> Void)? = nil
    ) -> some View {
        LensInspectorSlider(
            title: title,
            value: value,
            range: range,
            step: step,
            suffix: suffix,
            onContinuousBegin: { model.beginContinuousEdit() },
            onContinuousEnd: { model.endContinuousEdit() },
            onEditingEnded: onEditingEnded
        )
    }

    private var selectedCanvasPresetTitle: String {
        VideoEditorCanvasBackgroundPreset.all.first {
            $0.matches(model.plan.canvas)
        }?.title ?? "自定义"
    }

    private var cameraGenerationButtonTitle: String {
        if model.isRegeneratingCamera { return "正在分析点击与光标" }
        if model.isProcessing { return "镜头已更新 · 正在生成预览" }
        return "重新分析点击与光标"
    }

    private var automaticCameraPlanSummary: String {
        let automaticFrames = model.plan.camera.keyframes.filter {
            switch $0.reason {
            case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
                false
            default:
                true
            }
        }
        let clickFocuses = automaticFrames.filter { $0.reason == .clickFocus }.count
        let pointerFrames = automaticFrames.filter { $0.reason == .pointerFollow }.count
        if clickFocuses == 0, pointerFrames == 0 {
            return "当前没有符合条件的点击或明确光标移动"
        }
        return "已生成 \(clickFocuses) 个点击聚焦 · \(pointerFrames) 个光标跟随点"
    }

    private func canvasPresetButton(
        _ preset: VideoEditorCanvasBackgroundPreset,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            VideoEditorCanvasColor.color(
                                hex: preset.topHex,
                                fallback: .gray
                            ),
                            VideoEditorCanvasColor.color(
                                hex: preset.bottomHex,
                                fallback: .black
                            )
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white.opacity(0.34), lineWidth: 0.8))
                if selected {
                    Circle()
                        .stroke(LensGlassPalette.accent, lineWidth: 2)
                        .frame(width: 29, height: 29)
                    Image(systemName: "checkmark")
                        .font(.system(size: LensIcon.small, weight: .black))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.48), in: Circle())
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("\(preset.title)渐变")
        .accessibilityLabel("\(preset.title)背景预设")
        .accessibilityValue(selected ? "已选择" : "")
    }

    @ViewBuilder
    private var narrationTrimSection: some View {
        switch model.narrationTrimDetectionState {
        case .detecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在分析静默与口头禅…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            if model.narrationTrimSuggestions.isEmpty {
                Text("未检测到需要清除的静默、口头禅或开头结尾空白。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                let suggestions = model.narrationTrimSuggestions
                let pendingSuggestions = suggestions.filter { $0.status == .pending }
                let acceptedSuggestions = suggestions.filter { $0.status == .accepted }
                let rejectedSuggestions = suggestions.filter { $0.status == .rejected }
                let pendingSeconds = pendingSuggestions
                    .reduce(0.0) { $0 + $1.durationSeconds }
                let acceptedSeconds = acceptedSuggestions
                    .reduce(0.0) { $0 + $1.durationSeconds }
                VStack(alignment: .leading, spacing: 4) {
                    if pendingSuggestions.isEmpty {
                        Text("本轮旁白清理已处理完")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        Text(String(
                            format: "待确认 %d 条 · 确认后预计缩短约 %.1f 秒",
                            pendingSuggestions.count,
                            pendingSeconds
                        ))
                        .font(.system(size: 10, weight: .semibold))
                    }
                    if acceptedSuggestions.isEmpty == false || rejectedSuggestions.isEmpty == false {
                        HStack(spacing: 8) {
                            if acceptedSuggestions.isEmpty == false {
                                Label(
                                    String(format: "已接受 %d 条 · 已缩短 %.1f 秒", acceptedSuggestions.count, acceptedSeconds),
                                    systemImage: "checkmark.circle"
                                )
                                .foregroundStyle(.secondary)
                            }
                            if rejectedSuggestions.isEmpty == false {
                                Label(
                                    String(format: "已跳过 %d 条", rejectedSuggestions.count),
                                    systemImage: "arrow.uturn.backward.circle"
                                )
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: LensType.micro, weight: .medium))
                    }
                    Text("建议只在确认后修改时间线，原始录制始终不变。")
                        .font(.system(size: LensType.micro))
                        .foregroundStyle(.secondary)
                    if pendingSuggestions.isEmpty == false {
                        Button("全部接受") {
                            model.acceptAllPendingNarrationTrims()
                        }
                        .controlSize(.small)
                        .help("只接受待确认建议，已接受和已跳过的建议不会重复处理")
                    }
                }
                ForEach(suggestions) { suggestion in
                    narrationTrimRow(suggestion)
                }
            }
        }
    }

    private func narrationTrimRow(_ suggestion: NarrationTrimSuggestion) -> some View {
        let isPending = suggestion.status == .pending
        return HStack(spacing: 6) {
            Button {
                guard let outputTime = model.outputTimes(
                    forNarrationTrim: suggestion
                ).first else { return }
                playback.seek(to: outputTime)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: narrationTrimSymbol(for: suggestion.kind))
                            .font(.system(size: LensIcon.small, weight: .semibold))
                            .foregroundStyle(isPending ? Color.primary : Color.secondary)
                        Text(narrationTrimTitle(for: suggestion))
                            .font(.system(size: LensType.micro, weight: .semibold))
                            .foregroundStyle(isPending ? Color.primary : Color.secondary)
                    }
                    Text(String(
                        format: "%@ – %@ · %.1f 秒",
                        VideoEditorFormatting.timeText(suggestion.startSeconds),
                        VideoEditorFormatting.timeText(suggestion.endSeconds),
                        suggestion.durationSeconds
                    ))
                    .font(.system(size: LensType.micro))
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(suggestion.status == .accepted)
            Spacer(minLength: 2)
            switch suggestion.status {
            case .pending:
                Button("跳过") {
                    model.rejectNarrationTrim(suggestion.id)
                }
                .controlSize(.mini)
                Button("接受") {
                    model.acceptNarrationTrim(suggestion.id)
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
            case .accepted:
                Label("已接受", systemImage: "checkmark")
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .rejected:
                Button("撤销跳过") {
                    model.restoreNarrationTrim(suggestion.id)
                }
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private func narrationTrimTitle(for suggestion: NarrationTrimSuggestion) -> String {
        switch suggestion.kind {
        case .silence:
            "静默段"
        case .fillerWord:
            "口头禅“\(suggestion.label ?? "")”"
        case .openingBuffer:
            "开头空白"
        case .closingBuffer:
            "结尾空白"
        }
    }

    private func narrationTrimSymbol(
        for kind: NarrationTrimSuggestion.Kind
    ) -> String {
        switch kind {
        case .silence: "waveform.slash"
        case .fillerWord: "text.bubble"
        case .openingBuffer: "arrow.up.to.line"
        case .closingBuffer: "arrow.down.to.line"
        }
    }

    private func choiceButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: LensType.micro, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    selected ? LensGlassPalette.accent.opacity(0.76) : Color.primary.opacity(0.055),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("切换到此选项")
    }

    private var exportPresetDescription: String {
        switch model.exportPreset {
        case .source:
            "保留源帧率与最高画质，适合归档和二次剪辑。"
        case .balanced:
            "最高 30 fps，在清晰度、生成速度和文件体积之间取平衡。"
        case .compact:
            "最高 24 fps 并压缩体积，适合消息与网页快速发送。"
        }
    }

}
