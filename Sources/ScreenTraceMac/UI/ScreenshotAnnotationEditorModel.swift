import Foundation
import ScreenTraceCore

@MainActor
final class ScreenshotAnnotationEditorModel: ObservableObject {
    let sourceDimensions: TraceDimensions

    @Published var selectedTool: ScreenshotAnnotationKind = .arrow
    @Published var selectedColor: TraceColor = .red
    @Published var textDraft = "重点"
    @Published private(set) var annotations: [ScreenshotAnnotation]
    @Published private(set) var draftAnnotation: ScreenshotAnnotation?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var draftID = UUID()

    init(sourceDimensions: TraceDimensions, existingPlan: ScreenshotEditPlan? = nil) {
        self.sourceDimensions = sourceDimensions
        if existingPlan?.sourceDimensions == sourceDimensions {
            annotations = existingPlan?.annotations ?? []
        } else {
            annotations = []
        }
    }

    var plan: ScreenshotEditPlan {
        ScreenshotEditPlan(sourceDimensions: sourceDimensions, annotations: annotations)
    }

    func updateDraft(start: TracePoint, end: TracePoint) {
        draftAnnotation = makeAnnotation(
            id: draftID,
            start: clamped(start),
            end: clamped(end)
        )
    }

    @discardableResult
    func commitDraft(start: TracePoint, end: TracePoint) -> Bool {
        let start = clamped(start)
        let end = clamped(end)
        guard let annotation = makeAnnotation(id: draftID, start: start, end: end) else {
            cancelDraft()
            return false
        }
        recordUndoPoint()
        annotations.append(annotation)
        draftAnnotation = nil
        draftID = UUID()
        return true
    }

    func cancelDraft() {
        draftAnnotation = nil
        draftID = UUID()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        updateHistoryFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        updateHistoryFlags()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        recordUndoPoint()
        annotations.removeAll()
    }

    private func makeAnnotation(
        id: UUID,
        start: TracePoint,
        end: TracePoint
    ) -> ScreenshotAnnotation? {
        let deltaX = abs(end.x - start.x)
        let deltaY = abs(end.y - start.y)
        let distance = hypot(end.x - start.x, end.y - start.y)

        let minimumExtent = 0.006
        let bounds: TraceRect
        if selectedTool == .text && deltaX < minimumExtent && deltaY < minimumExtent {
            bounds = TraceRect(
                x: min(start.x, 0.72),
                y: min(start.y, 0.92),
                width: 0.26,
                height: 0.08
            )
        } else {
            guard deltaX >= minimumExtent || deltaY >= minimumExtent else { return nil }
            bounds = TraceRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(deltaX, minimumExtent),
                height: max(deltaY, minimumExtent)
            )
        }

        if selectedTool == .arrow, distance < 0.012 { return nil }
        let fillColor: TraceColor? = switch selectedTool {
        case .rectangle, .ellipse:
            TraceColor(
                red: selectedColor.red,
                green: selectedColor.green,
                blue: selectedColor.blue,
                alpha: 0.10
            )
        default:
            nil
        }
        let style = ScreenshotAnnotationStyle(
            lineWidth: 0.006,
            fontSize: 0.045,
            color: selectedColor,
            fillColor: fillColor,
            intensity: selectedTool == .pixelate ? 0.055 : 0.035
        )
        return ScreenshotAnnotation(
            id: id,
            kind: selectedTool,
            bounds: bounds,
            start: selectedTool == .arrow ? start : nil,
            end: selectedTool == .arrow ? end : nil,
            text: selectedTool == .text ? normalizedTextDraft : nil,
            style: style
        )
    }

    private var normalizedTextDraft: String {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "文字" : trimmed
    }

    private func clamped(_ point: TracePoint) -> TracePoint {
        TracePoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    private func recordUndoPoint() {
        undoStack.append(annotations)
        if undoStack.count > 50 {
            undoStack.removeFirst(undoStack.count - 50)
        }
        redoStack.removeAll()
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
