import AppKit
import LensCore
import SwiftUI

struct ScreenshotAnnotationEditorView: View {
    @ObservedObject var model: ScreenshotAnnotationEditorModel
    let image: NSImage
    let onSave: (ScreenshotEditPlan) -> Void
    let onCopy: (ScreenshotEditPlan) -> Void
    let onExport: (ScreenshotEditPlan, ScreenshotExportFormat) -> Void
    let onExportCodeCard: () -> Void
    let onCancel: () -> Void

    @State private var showsRedactionReview = false

    init(
        model: ScreenshotAnnotationEditorModel,
        image: NSImage,
        onSave: @escaping (ScreenshotEditPlan) -> Void,
        onCopy: @escaping (ScreenshotEditPlan) -> Void,
        onExport: @escaping (ScreenshotEditPlan, ScreenshotExportFormat) -> Void,
        onExportCodeCard: @escaping () -> Void = {},
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.image = image
        self.onSave = onSave
        self.onCopy = onCopy
        self.onExport = onExport
        self.onExportCodeCard = onExportCodeCard
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            toolbar
                .disabled(model.isRendering)
            Divider().opacity(0.35)
            backgroundToolbar
                .disabled(model.isRendering)
            Divider().opacity(0.35)
            canvas
                .allowsHitTesting(!model.isRendering)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .frame(minWidth: 900, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(LensGlassPalette.accent.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: LensIcon.medium, weight: .semibold))
                    .foregroundStyle(LensGlassPalette.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("标注截图")
                    .font(.system(size: LensType.title, weight: .semibold))
                Text(annotationPrivacySubtitle)
                    .font(.system(size: LensType.caption, weight: .medium))
                    .foregroundStyle(annotationPrivacySubtitleColor)
            }
            Spacer()
            if let feedback = model.clipboardFeedback {
                Label(
                    feedback == .copied ? "已复制到剪贴板" : "复制未完成",
                    systemImage: feedback == .copied
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.system(size: LensType.micro, weight: .semibold))
                .foregroundStyle(feedback == .copied ? LensGlassPalette.success : LensGlassPalette.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.055), in: Capsule())
                .accessibilityLabel(
                    feedback == .copied
                        ? "已复制到剪贴板，可使用 Command-V 粘贴"
                        : "复制未完成"
                )
            } else if model.isRendering {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在渲染标注结果")
                Text("正在渲染…")
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUndo || model.isRendering)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销")
            .accessibilityLabel("撤销")
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRedo || model.isRendering)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做")
            .accessibilityLabel("重做")
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Menu {
                ForEach(ScreenshotExportFormat.allCases, id: \.self) { format in
                    Button {
                        onExport(model.plan, format)
                    } label: {
                        Label(format.editorTitle, systemImage: format.editorSymbol)
                    }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .disabled(model.isRendering)
            Button {
                onCopy(model.plan)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(model.isRendering)
            .keyboardShortcut("c", modifiers: .command)
            .help("复制当前标注结果（Command-C），随后可用 Command-V 粘贴")
            Button {
                onSave(model.plan)
            } label: {
                Label("完成并复制", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(LensGlassPalette.accent)
            .disabled(model.isRendering)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, LensSpacing.section)
        .padding(.vertical, LensSpacing.m)
        .lensGlassSurface(role: .chrome, cornerRadius: LensGlassMetrics.chromeCornerRadius)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.activateSelectionTool()
            } label: {
                Label("选择", systemImage: "cursorarrow")
                    .font(.system(size: LensType.micro, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(
                        model.isSelectionMode
                            ? LensGlassPalette.accent.opacity(0.16)
                            : Color.primary.opacity(0.045),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isSelectionMode ? LensGlassPalette.accent : .primary)
            .help("选择、移动或缩放对象")

            if model.suggestedRedactionCount > 0 {
                Button {
                    showsRedactionReview.toggle()
                } label: {
                    Label(
                        "复核 \(model.suggestedRedactionCount) 处",
                        systemImage: "eye.slash"
                    )
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.18), in: Capsule()) // lens-token-exempt: 敏感信息建议是内容状态
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange) // lens-token-exempt: 敏感信息建议是内容状态
                .accessibilityLabel("复核 \(model.suggestedRedactionCount) 处可能的敏感信息")
                .accessibilityHint("打开逐项复核面板；确认后才会加入可移动、可撤销的像素化标注")
                .help("对 OCR 识别到的邮箱、电话、证件号、卡号与凭据生成可撤销的像素化标注；像素化仅适合演示，不等于安全脱敏")
                .popover(isPresented: $showsRedactionReview, arrowEdge: .bottom) {
                    redactionReviewPanel
                }
            }

            if model.showsCodeCardExport {
                Button(action: onExportCodeCard) {
                    Label("导出代码卡片", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(LensGlassPalette.accent.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LensGlassPalette.accent)
                .help("把识别到的代码渲染成深色等宽卡片（PNG）")
            }

            Divider().frame(height: 25)

            ForEach(ScreenshotAnnotationKind.allCases, id: \.self) { tool in
                Button {
                    model.activateDrawingTool(tool)
                } label: {
                    Label(tool.editorTitle, systemImage: tool.editorSymbol)
                        .font(.system(size: LensType.micro, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(
                            !model.isSelectionMode && model.selectedTool == tool
                                ? LensGlassPalette.accent.opacity(0.16)
                                : Color.primary.opacity(0.045),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(!model.isSelectionMode && model.selectedTool == tool ? LensGlassPalette.accent : .primary)
                .help(tool.editorTitle)
            }

            Divider().frame(height: 25)

            Menu {
                Section("纯色") {
                    ForEach(editorColors, id: \.name) { item in
                        Button {
                            model.setColor(item.color)
                        } label: {
                            Text(item.name)
                        }
                    }
                }
                Section("渐变") {
                    ForEach(editorGradients, id: \.name) { item in
                        Button {
                            model.setGradient(start: item.start, end: item.end)
                        } label: {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: LensGlassMetrics.badgeCornerRadius, style: .continuous)
                        .fill(selectedColorStyle)
                        .frame(width: 25, height: 17)
                        .overlay(
                            RoundedRectangle(cornerRadius: LensGlassMetrics.badgeCornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.45), lineWidth: 1)
                        )
                    Text("颜色")
                        .font(.system(size: LensType.micro, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("标注颜色")
            .help("选择纯色或渐变标注颜色")

            if activeEffectAnnotation != nil {
                HStack(spacing: 5) {
                    Text("强度")
                        .font(.system(size: 10, weight: .medium))
                    Slider(
                        value: Binding(
                            get: { model.effectIntensity },
                            set: { model.setEffectIntensity($0) }
                        ),
                        in: 0.004...0.06
                    )
                    .frame(width: 78)
                    .accessibilityLabel("\(activeEffectAnnotation?.editorTitle ?? "效果")强度")
                    .accessibilityValue(String(format: "%.2f", model.effectIntensity))
                }
            }

            if !model.isSelectionMode && model.selectedTool == .text {
                TextField("标注文字", text: $model.textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 190)
            }

            Spacer(minLength: 6)
            if model.isSelectionMode {
                Button {
                    model.deleteSelected()
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: LensType.micro, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedAnnotation == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }
            Button {
                model.clear()
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: LensType.micro, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(model.annotations.isEmpty)
        }
        .padding(.horizontal, LensSpacing.l)
        .padding(.vertical, 9)
        .lensGlassSurface(role: .chrome, cornerRadius: LensGlassMetrics.chromeCornerRadius)
    }

    private var backgroundToolbar: some View {
        ScreenshotCanvasToolbar(model: model)
    }

    private var annotationPrivacySubtitle: String {
        if model.suggestedRedactionCount > 0 {
            return "检测到敏感信息建议 · 像素化可撤销，不等于安全脱敏"
        }
        if model.annotations.contains(where: { $0.kind == .pixelate }) {
            return "像素化仅适合演示 · 不等于安全脱敏，原图始终保留"
        }
        return "所有标注均非破坏性，原图始终保留"
    }

    private var annotationPrivacySubtitleColor: Color {
        model.suggestedRedactionCount > 0 || model.annotations.contains(where: { $0.kind == .pixelate })
            ? LensGlassPalette.warning
            : .secondary
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let layout = ScreenshotCanvasPlanner.layout(
                sourceDimensions: model.sourceDimensions,
                style: model.canvasStyle
            )
            let canvasRect = aspectFitRect(
                imageSize: CGSize(
                    width: layout.outputDimensions.width,
                    height: layout.outputDimensions.height
                ),
                containerSize: proxy.size,
                margin: 34
            )
            let imageRect = sourceRect(layout: layout, canvasRect: canvasRect)
            ZStack {
                Color.black.opacity(0.88)
                canvasBackground(style: model.canvasStyle)
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .position(x: canvasRect.midX, y: canvasRect.midY)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .clipShape(RoundedRectangle(
                        cornerRadius: CGFloat(model.canvasStyle?.normalized.cornerRadius ?? 0)
                            * min(imageRect.width, imageRect.height),
                        style: .continuous
                    ))
                    .shadow(
                        color: .black.opacity(model.canvasStyle?.normalized.shadowOpacity ?? 0),
                        radius: CGFloat(model.canvasStyle?.normalized.shadowRadius ?? 0)
                            * min(imageRect.width, imageRect.height),
                        y: CGFloat(model.canvasStyle == nil ? 0 : 0.018)
                            * min(imageRect.width, imageRect.height)
                    )

                Canvas { context, _ in
                    for (index, suggestion) in model.pendingRedactionSuggestions.enumerated() {
                        drawPendingRedaction(
                            suggestion,
                            index: index,
                            context: &context,
                            imageRect: imageRect
                        )
                    }
                    for annotation in model.annotations {
                        draw(annotation, context: &context, imageRect: imageRect)
                    }
                    if let draft = model.draftAnnotation {
                        draw(draft, context: &context, imageRect: imageRect, isDraft: true)
                    }
                    if model.isSelectionMode, let selected = model.selectedAnnotation {
                        drawSelection(selected, context: &context, imageRect: imageRect)
                    }
                }
                .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .gesture(annotationGesture(in: imageRect))
                // SwiftUI's transparent gesture target is reported as
                // AXUnknown on macOS and drops its value. Keep the gesture
                // target visual-only for AX and add a native group proxy that
                // reliably exposes the canvas name, value, and hint.
                ScreenshotCanvasAccessibilityProxy(
                    label: "截图标注画布",
                    value: canvasAccessibilityValue,
                    hint: canvasAccessibilityHint
                )
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func canvasBackground(style: ScreenshotCanvasStyle?) -> some View {
        if let style = style?.normalized {
            switch style.backgroundKind {
            case .solid:
                style.primaryColor.swiftUIColor
            case .gradient:
                LinearGradient(
                    colors: [
                        style.primaryColor.swiftUIColor,
                        style.secondaryColor.swiftUIColor
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            Color.clear
        }
    }

    private func sourceRect(
        layout: ScreenshotCanvasLayout,
        canvasRect: CGRect
    ) -> CGRect {
        let outputWidth = max(CGFloat(layout.outputDimensions.width), 1)
        let outputHeight = max(CGFloat(layout.outputDimensions.height), 1)
        return CGRect(
            x: canvasRect.minX + CGFloat(layout.sourceFrame.x) / outputWidth * canvasRect.width,
            y: canvasRect.minY + CGFloat(layout.sourceFrame.y) / outputHeight * canvasRect.height,
            width: CGFloat(layout.sourceFrame.width) / outputWidth * canvasRect.width,
            height: CGFloat(layout.sourceFrame.height) / outputHeight * canvasRect.height
        )
    }

    private var footer: some View {
        HStack {
            if model.isSelectionMode {
                Label("点选对象，拖动移动；拖动控制点缩放", systemImage: "cursorarrow.motionlines")
                Text("·")
                Text("Delete 删除")
            } else {
                Label("拖动添加标注", systemImage: "cursorarrow.motionlines")
                Text("·")
                Text("文字工具可单击放置")
            }
            if model.suggestedRedactionCount > 0 {
                Text("·")
                Label("待复核 \(model.suggestedRedactionCount) 处", systemImage: "eye")
                    .accessibilityLabel("待复核 \(model.suggestedRedactionCount) 处敏感信息建议")
            }
            Spacer()
            Text("\(model.annotations.count) 个对象")
        }
        .font(.system(size: LensType.caption, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 8)
        .lensGlassSurface(role: .chrome, cornerRadius: LensGlassMetrics.chromeCornerRadius)
    }

    private var canvasAccessibilityValue: String {
        if model.suggestedRedactionCount > 0 {
            return "\(model.annotations.count) 个标注对象，\(model.suggestedRedactionCount) 个待复核敏感信息建议"
        }
        return "\(model.annotations.count) 个标注对象"
    }

    private var canvasAccessibilityHint: String {
        if model.suggestedRedactionCount > 0 {
            return "先查看画布上的橙色虚线框，再从复核面板逐项应用或跳过"
        }
        return model.isSelectionMode
            ? "使用指针选择、移动或缩放标注对象"
            : "使用指针拖动添加\(model.selectedTool.editorTitle)"
    }

    private var redactionReviewPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Label("敏感信息建议", systemImage: "eye.slash")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.suggestedRedactionCount) 处")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange) // lens-token-exempt: 敏感信息建议是内容状态
            }
            Text("橙色虚线框只表示 OCR 建议。请先检查位置，再逐项应用；原图始终保留，像素化不等于安全脱敏。")
                .font(.system(size: LensType.micro, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.pendingRedactionSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        HStack(spacing: 7) {
                            Text("\(index + 1)")
                                .font(.system(size: LensType.micro, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(LensGlassPalette.warning, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text("建议 \(index + 1)")
                                    .font(.system(size: LensType.micro, weight: .semibold))
                                Text(redactionBoundsText(suggestion.bounds))
                                    .font(.system(size: LensType.micro, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            Button("跳过") {
                                model.dismissSuggestedRedaction(suggestion.id)
                            }
                            .controlSize(.mini)
                            Button("应用") {
                                model.applySuggestedRedaction(suggestion.id)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderedProminent)
                            .tint(LensGlassPalette.warning)
                            Button("安全遮挡") {
                                model.applySuggestedRedaction(
                                    suggestion.id,
                                    application: .opaque
                                )
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                            .help("使用不透明黑色遮挡；原图仍保留在 Lens 项目中")
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button("全部应用") {
                    model.applySuggestedRedactions()
                    showsRedactionReview = false
                }
                .buttonStyle(.borderedProminent)
                .tint(LensGlassPalette.warning)
                Button("全部安全遮挡") {
                    model.applySuggestedRedactions(application: .opaque)
                    showsRedactionReview = false
                }
                .buttonStyle(.bordered)
                .help("用不透明黑色遮挡全部建议；原图仍保留")
                Button("关闭") {
                    showsRedactionReview = false
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(LensSpacing.card)
        .frame(width: 360)
    }

    private func redactionBoundsText(_ bounds: LensRect) -> String {
        String(
            format: "画布 %.0f%%, %.0f%% · %.0f%% × %.0f%%",
            bounds.x * 100,
            bounds.y * 100,
            bounds.width * 100,
            bounds.height * 100
        )
    }

    private func annotationGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(
            minimumDistance: model.isSelectionMode
                || model.selectedTool == .text
                || model.selectedTool == .step ? 0 : 1
        )
            .onChanged { value in
                let start = normalizedPoint(value.startLocation, in: imageRect)
                let end = normalizedPoint(value.location, in: imageRect)
                if model.isSelectionMode {
                    let shortestSide = max(min(imageRect.width, imageRect.height), 1)
                    model.beginSelectionInteraction(
                        at: start,
                        hitTolerance: 7 / shortestSide,
                        handleTolerance: 12 / shortestSide
                    )
                    model.updateSelectionInteraction(to: end)
                } else {
                    model.updateDraft(start: start, end: end)
                }
            }
            .onEnded { value in
                if model.isSelectionMode {
                    model.updateSelectionInteraction(
                        to: normalizedPoint(value.location, in: imageRect)
                    )
                    model.endSelectionInteraction()
                } else {
                    _ = model.commitDraft(
                        start: normalizedPoint(value.startLocation, in: imageRect),
                        end: normalizedPoint(value.location, in: imageRect)
                    )
                }
            }
    }

    private func drawSelection(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        let rect = viewRect(annotation.bounds, in: imageRect).insetBy(dx: -3, dy: -3)
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 5), // lens-token-exempt: 画布内容渲染（选区轮廓），非 UI 表面
            with: .color(.cyan.opacity(0.92)), // lens-token-exempt: 同上
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )

        for handle in ScreenshotAnnotationResizeHandle.allCases {
            guard let point = ScreenshotAnnotationGeometry.point(
                for: handle,
                annotation: annotation
            ) else { continue }
            let center = viewPoint(point, in: imageRect)
            let handleRect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: handleRect), with: .color(.white))
            context.stroke(Path(ellipseIn: handleRect), with: .color(.cyan), lineWidth: 2) // lens-token-exempt: 画布内容渲染（缩放手柄），非 UI 表面
        }
    }

    private func drawPendingRedaction(
        _ annotation: ScreenshotAnnotation,
        index: Int,
        context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        let rect = viewRect(annotation.bounds, in: imageRect).insetBy(dx: -2, dy: -2)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 5), // lens-token-exempt: 画布内容渲染（待复核建议框与序号徽标），非 UI 表面
            with: .color(.orange.opacity(0.10)) // lens-token-exempt: 画布内容渲染（待复核建议填充），非 UI 表面
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 5), // lens-token-exempt: 同上，画布内容渲染
            with: .color(.orange.opacity(0.95)), // lens-token-exempt: 画布内容渲染（待复核建议描边），非 UI 表面
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
        )
        let badge = CGRect(x: rect.minX, y: rect.minY, width: 18, height: 18)
        context.fill(Path(ellipseIn: badge), with: .color(.orange)) // lens-token-exempt: 画布内容渲染（待复核序号徽标），非 UI 表面
        context.draw(
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .monospaced)) // lens-token-exempt: 画布徽标文字，非 UI 表面
                .foregroundStyle(.white),
            at: CGPoint(x: badge.midX, y: badge.midY)
        )
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> LensPoint {
        LensPoint(
            x: min(max((point.x - rect.minX) / max(rect.width, 1), 0), 1),
            y: min(max((point.y - rect.minY) / max(rect.height, 1), 0), 1)
        )
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        imageRect: CGRect,
        isDraft: Bool = false
    ) {
        let color = annotation.style.color.swiftUIColor.opacity(isDraft ? 0.72 : 1)
        let shading = annotationShading(annotation, in: imageRect, opacity: isDraft ? 0.72 : 1)
        let lineWidth = max(2, annotation.style.lineWidth * min(imageRect.width, imageRect.height))
        let rect = viewRect(annotation.bounds, in: imageRect)
        switch annotation.kind {
        case .rectangle:
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: annotationShading(annotation, in: rect, opacity: 0.10)) // lens-token-exempt: 画布内容渲染（矩形标注形状），非 UI 表面
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: shading, lineWidth: lineWidth) // lens-token-exempt: 同上
        case .ellipse:
            context.fill(Path(ellipseIn: rect), with: annotationShading(annotation, in: rect, opacity: 0.10))
            context.stroke(Path(ellipseIn: rect), with: shading, lineWidth: lineWidth)
        case .arrow:
            drawArrow(annotation, context: &context, imageRect: imageRect, shading: shading, lineWidth: lineWidth)
        case .freehand:
            drawFreehand(
                annotation,
                context: &context,
                imageRect: imageRect,
                shading: shading,
                lineWidth: lineWidth
            )
        case .highlight:
            context.fill(
                Path(roundedRect: rect, cornerRadius: max(2, rect.height * 0.12)),
                with: annotationShading(
                    annotation,
                    in: rect,
                    opacity: annotation.style.fillColor?.alpha ?? 0.28
                )
            )
        case .step:
            let diameter = min(rect.width, rect.height)
            let circle = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: circle), with: annotationShading(annotation, in: circle, opacity: 1))
            context.stroke(
                Path(ellipseIn: circle.insetBy(dx: 1, dy: 1)),
                with: .color(.white.opacity(0.85)),
                lineWidth: max(1.5, lineWidth * 0.34)
            )
            context.draw(
                Text(annotation.text ?? "1")
                    .font(.system(size: max(12, diameter * 0.50), weight: .bold))
                    .foregroundStyle(.white),
                at: CGPoint(x: circle.midX, y: circle.midY)
            )
        case .text:
            let text = Text(annotation.text ?? "文字")
                .font(.system(size: max(12, annotation.style.fontSize * min(imageRect.width, imageRect.height)), weight: .bold))
                .foregroundStyle(color)
            context.draw(text, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
        case .blur, .pixelate:
            let symbol = annotation.kind == .blur ? "drop.fill" : "square.grid.3x3.fill"
            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.white.opacity(0.18))) // lens-token-exempt: 画布内容渲染（模糊/像素化标注形状），非 UI 表面
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 6), // lens-token-exempt: 同上
                with: .color(.white.opacity(0.72)),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            context.draw(
                Image(systemName: symbol),
                at: CGPoint(x: rect.midX, y: rect.midY)
            )
        }
    }

    private func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        imageRect: CGRect,
        shading: GraphicsContext.Shading,
        lineWidth: CGFloat
    ) {
        guard let points = annotation.points, let first = points.first else { return }
        var path = Path()
        path.move(to: viewPoint(first, in: imageRect))
        for point in points.dropFirst() {
            path.addLine(to: viewPoint(point, in: imageRect))
        }
        context.stroke(
            path,
            with: shading,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        imageRect: CGRect,
        shading: GraphicsContext.Shading,
        lineWidth: CGFloat
    ) {
        let start = viewPoint(
            annotation.start ?? LensPoint(x: annotation.bounds.x, y: annotation.bounds.y),
            in: imageRect
        )
        let end = viewPoint(
            annotation.end ?? LensPoint(
                x: annotation.bounds.x + annotation.bounds.width,
                y: annotation.bounds.y + annotation.bounds.height
            ),
            in: imageRect
        )
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(10, lineWidth * 4)
        let spread = CGFloat.pi / 6.5
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        head.move(to: end)
        head.addLine(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        context.stroke(head, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func viewRect(_ rect: LensRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.x * imageRect.width,
            y: imageRect.minY + rect.y * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        ).standardized
    }

    private func viewPoint(_ point: LensPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }

    private func aspectFitRect(
        imageSize: CGSize,
        containerSize: CGSize,
        margin: CGFloat
    ) -> CGRect {
        let available = CGSize(
            width: max(containerSize.width - margin * 2, 1),
            height: max(containerSize.height - margin * 2, 1)
        )
        let scale = min(
            available.width / max(imageSize.width, 1),
            available.height / max(imageSize.height, 1)
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var editorColors: [(name: String, color: LensColor)] {
        [
            ("红色", .red),
            ("橙色", .orange),
            ("黄色", .yellow), // lens-token-exempt: 用户标注调色板选项
            ("绿色", .green),
            ("青色", .cyan), // lens-token-exempt: 用户标注调色板选项
            ("蓝色", .blue),
            ("紫色", .purple), // lens-token-exempt: 用户标注调色板选项
            ("粉色", .pink), // lens-token-exempt: 用户标注调色板选项
            ("白色", .white),
            ("黑色", .black)
        ]
    }

    private var editorGradients: [(name: String, start: LensColor, end: LensColor)] {
        [
            ("日落橙粉", .orange, .pink), // lens-token-exempt: 用户标注渐变选项
            ("海蓝青紫", .cyan, .purple), // lens-token-exempt: 用户标注渐变选项
            ("暖阳红橙", .red, .orange),
            ("薄荷青蓝", .green, .blue)
        ]
    }

    private var selectedColorStyle: AnyShapeStyle {
        if let end = model.selectedGradientEndColor {
            return AnyShapeStyle(LinearGradient(
                colors: [model.selectedColor.swiftUIColor, end.swiftUIColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(model.selectedColor.swiftUIColor)
    }

    private var activeEffectAnnotation: ScreenshotAnnotationKind? {
        if model.isSelectionMode {
            guard let kind = model.selectedAnnotation?.kind,
                  kind == .blur || kind == .pixelate else { return nil }
            return kind
        }
        return model.selectedTool == .blur || model.selectedTool == .pixelate
            ? model.selectedTool
            : nil
    }

    private func annotationShading(
        _ annotation: ScreenshotAnnotation,
        in rect: CGRect,
        opacity: Double
    ) -> GraphicsContext.Shading {
        let start = annotation.style.color.swiftUIColor.opacity(opacity)
        guard let endColor = annotation.style.gradientEndColor else {
            return .color(start)
        }
        return .linearGradient(
            Gradient(colors: [start, endColor.swiftUIColor.opacity(opacity)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
        )
    }

}

/// A small AppKit-backed accessibility element used for the canvas only. A
/// native view is necessary here because SwiftUI's accessibilityValue is not
/// surfaced on a transparent gesture shape as an AXGroup on macOS.
private struct ScreenshotCanvasAccessibilityProxy: NSViewRepresentable {
    let label: String
    let value: String
    let hint: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityHelp(hint)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityHelp(hint)
    }
}

extension ScreenshotAnnotationKind {
    var editorTitle: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .freehand: "画笔"
        case .highlight: "高亮"
        case .step: "编号"
        case .text: "文字"
        case .blur: "模糊"
        case .pixelate: "像素"
        }
    }

    var editorSymbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .freehand: "pencil.tip"
        case .highlight: "highlighter"
        case .step: "1.circle"
        case .text: "textformat"
        case .blur: "drop"
        case .pixelate: "square.grid.3x3"
        }
    }
}

extension LensColor {
    var swiftUIColor: Color {
        Color(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            opacity: min(max(alpha, 0), 1)
        )
    }
}

extension ScreenshotCanvasAspectRatio {
    var editorTitle: String {
        switch self {
        case .automatic: "自动"
        case .square: "1:1"
        case .landscape4x3: "4:3"
        case .widescreen16x9: "16:9"
        case .portrait9x16: "9:16"
        }
    }
}

extension ScreenshotExportFormat {
    var editorTitle: String {
        switch self {
        case .png: "PNG 图像"
        case .jpeg: "JPEG 图像"
        }
    }

    var editorSymbol: String {
        switch self {
        case .png: "photo"
        case .jpeg: "photo.badge.arrow.down"
        }
    }
}
