import AppKit
import ScreenTraceCore
import SwiftUI

struct ScreenshotAnnotationEditorView: View {
    @ObservedObject var model: ScreenshotAnnotationEditorModel
    let image: NSImage
    let onSave: (ScreenshotEditPlan) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            toolbar
            Divider().opacity(0.35)
            canvas
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .frame(minWidth: 900, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("标注截图")
                    .font(.system(size: 14, weight: .semibold))
                Text("所有标注均非破坏性，原图始终保留")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销")
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做")
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
            Button {
                onSave(model.plan)
            } label: {
                Label("完成并复制", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.activateSelectionTool()
            } label: {
                Label("选择", systemImage: "cursorarrow")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background(
                        model.isSelectionMode
                            ? Color.cyan.opacity(0.16)
                            : Color.primary.opacity(0.045),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.isSelectionMode ? .cyan : .primary)
            .help("选择、移动或缩放对象")

            Divider().frame(height: 25)

            ForEach(ScreenshotAnnotationKind.allCases, id: \.self) { tool in
                Button {
                    model.activateDrawingTool(tool)
                } label: {
                    Label(tool.editorTitle, systemImage: tool.editorSymbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(
                            !model.isSelectionMode && model.selectedTool == tool
                                ? Color.cyan.opacity(0.16)
                                : Color.primary.opacity(0.045),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(!model.isSelectionMode && model.selectedTool == tool ? .cyan : .primary)
                .help(tool.editorTitle)
            }

            Divider().frame(height: 25)

            ForEach(editorColors, id: \.name) { item in
                Button {
                    model.setColor(item.color)
                } label: {
                    Circle()
                        .fill(item.color.swiftUIColor)
                        .frame(width: 17, height: 17)
                        .overlay(
                            Circle().stroke(
                                model.selectedColor == item.color ? Color.primary : Color.white.opacity(0.28),
                                lineWidth: model.selectedColor == item.color ? 2 : 1
                            )
                        )
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help(item.name)
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
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedAnnotation == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }
            Button {
                model.clear()
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(model.annotations.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(
                imageSize: image.size,
                containerSize: proxy.size,
                margin: 34
            )
            ZStack {
                Color.black.opacity(0.88)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.42), radius: 22, y: 10)

                Canvas { context, _ in
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
            }
        }
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
            Spacer()
            Text("\(model.annotations.count) 个对象")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 17)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
            Path(roundedRect: rect, cornerRadius: 5),
            with: .color(.cyan.opacity(0.92)),
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
            context.stroke(Path(ellipseIn: handleRect), with: .color(.cyan), lineWidth: 2)
        }
    }

    private func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> TracePoint {
        TracePoint(
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
        let lineWidth = max(2, annotation.style.lineWidth * min(imageRect.width, imageRect.height))
        let rect = viewRect(annotation.bounds, in: imageRect)
        switch annotation.kind {
        case .rectangle:
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.10)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: lineWidth)
        case .ellipse:
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.10)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)
        case .arrow:
            drawArrow(annotation, context: &context, imageRect: imageRect, color: color, lineWidth: lineWidth)
        case .freehand:
            drawFreehand(
                annotation,
                context: &context,
                imageRect: imageRect,
                color: color,
                lineWidth: lineWidth
            )
        case .highlight:
            context.fill(
                Path(roundedRect: rect, cornerRadius: max(2, rect.height * 0.12)),
                with: .color(color.opacity(annotation.style.fillColor?.alpha ?? 0.28))
            )
        case .step:
            let diameter = min(rect.width, rect.height)
            let circle = CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: circle), with: .color(color))
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
            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.white.opacity(0.18)))
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 6),
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
        color: Color,
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
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        imageRect: CGRect,
        color: Color,
        lineWidth: CGFloat
    ) {
        let start = viewPoint(
            annotation.start ?? TracePoint(x: annotation.bounds.x, y: annotation.bounds.y),
            in: imageRect
        )
        let end = viewPoint(
            annotation.end ?? TracePoint(
                x: annotation.bounds.x + annotation.bounds.width,
                y: annotation.bounds.y + annotation.bounds.height
            ),
            in: imageRect
        )
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

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
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func viewRect(_ rect: TraceRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.x * imageRect.width,
            y: imageRect.minY + rect.y * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        ).standardized
    }

    private func viewPoint(_ point: TracePoint, in imageRect: CGRect) -> CGPoint {
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

    private var editorColors: [(name: String, color: TraceColor)] {
        [
            ("红色", .red),
            ("橙色", .orange),
            ("黄色", .yellow),
            ("蓝色", .blue),
            ("白色", .white),
            ("黑色", .black)
        ]
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

extension TraceColor {
    var swiftUIColor: Color {
        Color(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            opacity: min(max(alpha, 0), 1)
        )
    }
}
