import ScreenTraceCore
import SwiftUI

struct VideoAnnotationOverlayView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var playback: VideoEditorPlaybackController
    @ObservedObject private var clock: VideoEditorPlaybackClock
    let contentRect: CGRect

    init(
        model: VideoEditorModel,
        playback: VideoEditorPlaybackController,
        contentRect: CGRect
    ) {
        self.model = model
        self.playback = playback
        _clock = ObservedObject(wrappedValue: playback.clock)
        self.contentRect = contentRect
    }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                for visible in model.visibleVideoAnnotations(
                    atOutputTime: clock.currentTimeSeconds
                ) {
                    context.drawLayer { layer in
                        layer.opacity = visible.opacity
                        draw(
                            visible.item.annotation,
                            context: &layer,
                            isDraft: false
                        )
                    }
                }
                if let draft = model.videoAnnotationDraft {
                    draw(draft, context: &context, isDraft: true)
                }
                if model.isVideoAnnotationSelectionMode,
                   let selected = model.selectedVideoAnnotation,
                   model.visibleVideoAnnotations(
                       atOutputTime: clock.currentTimeSeconds
                   ).contains(where: { $0.item.id == selected.id }) {
                    drawSelection(selected.annotation, context: &context)
                }
            }
            .allowsHitTesting(false)

            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(annotationGesture)
                .allowsHitTesting(model.isVideoAnnotationEditing)
        }
        .frame(width: contentRect.width, height: contentRect.height)
        .position(x: contentRect.midX, y: contentRect.midY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频标注画布")
    }

    private var annotationGesture: some Gesture {
        DragGesture(
            minimumDistance: model.isVideoAnnotationSelectionMode
                || model.selectedVideoAnnotationTool == .text
                || model.selectedVideoAnnotationTool == .step ? 0 : 1
        )
        .onChanged { value in
            playback.pause()
            let start = normalizedPoint(value.startLocation)
            let end = normalizedPoint(value.location)
            if model.isVideoAnnotationSelectionMode {
                let shortestSide = max(min(contentRect.width, contentRect.height), 1)
                model.beginVideoAnnotationSelectionInteraction(
                    at: start,
                    outputTime: playback.currentTimeSeconds,
                    hitTolerance: 7 / shortestSide,
                    handleTolerance: 12 / shortestSide
                )
                model.updateVideoAnnotationSelectionInteraction(to: end)
            } else {
                model.updateVideoAnnotationDraft(start: start, end: end)
            }
        }
        .onEnded { value in
            if model.isVideoAnnotationSelectionMode {
                model.updateVideoAnnotationSelectionInteraction(
                    to: normalizedPoint(value.location)
                )
                model.endVideoAnnotationInteraction()
            } else {
                _ = model.commitVideoAnnotationDraft(
                    start: normalizedPoint(value.startLocation),
                    end: normalizedPoint(value.location),
                    atOutputTime: playback.currentTimeSeconds
                )
            }
        }
    }

    private func drawSelection(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext
    ) {
        let rect = viewRect(annotation.bounds).insetBy(dx: -3, dy: -3)
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 5),
            with: .color(.cyan.opacity(0.96)),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )
        for handle in ScreenshotAnnotationResizeHandle.allCases {
            guard let point = ScreenshotAnnotationGeometry.point(
                for: handle,
                annotation: annotation
            ) else { continue }
            let center = viewPoint(point)
            let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: rect), with: .color(.white))
            context.stroke(Path(ellipseIn: rect), with: .color(.cyan), lineWidth: 2)
        }
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        isDraft: Bool
    ) {
        let color = annotation.style.color.swiftUIColor.opacity(isDraft ? 0.72 : 1)
        let lineWidth = max(
            2,
            annotation.style.lineWidth * min(contentRect.width, contentRect.height)
        )
        let rect = viewRect(annotation.bounds)
        switch annotation.kind {
        case .rectangle:
            context.fill(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(color.opacity(0.10))
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(color),
                lineWidth: lineWidth
            )
        case .ellipse:
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.10)))
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)
        case .arrow:
            drawArrow(
                annotation,
                context: &context,
                color: color,
                lineWidth: lineWidth
            )
        case .freehand:
            drawFreehand(
                annotation,
                context: &context,
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
                with: .color(.white.opacity(0.86)),
                lineWidth: max(1.5, lineWidth * 0.34)
            )
            context.draw(
                Text(annotation.text ?? "1")
                    .font(.system(size: max(12, diameter * 0.50), weight: .bold))
                    .foregroundStyle(.white),
                at: CGPoint(x: circle.midX, y: circle.midY)
            )
        case .text:
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -5, dy: -3), cornerRadius: 5),
                with: .color(.black.opacity(0.58))
            )
            context.draw(
                Text(annotation.text ?? "文字")
                    .font(.system(
                        size: max(
                            12,
                            annotation.style.fontSize
                                * min(contentRect.width, contentRect.height)
                        ),
                        weight: .bold
                    ))
                    .foregroundStyle(color),
                at: CGPoint(x: rect.minX, y: rect.minY),
                anchor: .topLeading
            )
        case .blur, .pixelate:
            let symbol = annotation.kind == .blur ? "drop.fill" : "square.grid.3x3.fill"
            context.fill(
                Path(roundedRect: rect, cornerRadius: 6),
                with: .color(.white.opacity(0.18))
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 6),
                with: .color(.white.opacity(0.78)),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            context.draw(Image(systemName: symbol), at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard let points = annotation.points, let first = points.first else { return }
        var path = Path()
        path.move(to: viewPoint(first))
        for point in points.dropFirst() { path.addLine(to: viewPoint(point)) }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        context: inout GraphicsContext,
        color: Color,
        lineWidth: CGFloat
    ) {
        let start = viewPoint(
            annotation.start ?? TracePoint(x: annotation.bounds.x, y: annotation.bounds.y)
        )
        let end = viewPoint(
            annotation.end ?? TracePoint(
                x: annotation.bounds.x + annotation.bounds.width,
                y: annotation.bounds.y + annotation.bounds.height
            )
        )
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(
            line,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
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
        context.stroke(
            head,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func normalizedPoint(_ point: CGPoint) -> TracePoint {
        TracePoint(
            x: min(max(point.x / max(contentRect.width, 1), 0), 1),
            y: min(max(point.y / max(contentRect.height, 1), 0), 1)
        )
    }

    private func viewRect(_ rect: TraceRect) -> CGRect {
        CGRect(
            x: rect.x * contentRect.width,
            y: rect.y * contentRect.height,
            width: rect.width * contentRect.width,
            height: rect.height * contentRect.height
        ).standardized
    }

    private func viewPoint(_ point: TracePoint) -> CGPoint {
        CGPoint(x: point.x * contentRect.width, y: point.y * contentRect.height)
    }
}
