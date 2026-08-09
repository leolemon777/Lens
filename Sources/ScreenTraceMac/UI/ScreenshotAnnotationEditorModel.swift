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
    @Published private(set) var isSelectionMode = false
    @Published private(set) var selectedAnnotationID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var draftID = UUID()
    private var selectionInteractionActive = false
    private var activeTransform: ActiveTransform?

    private struct ActiveTransform {
        enum Operation {
            case move
            case resize(ScreenshotAnnotationResizeHandle)
        }

        let baseline: [ScreenshotAnnotation]
        let original: ScreenshotAnnotation
        let startPoint: TracePoint
        let operation: Operation
    }

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

    var selectedAnnotation: ScreenshotAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    func activateSelectionTool() {
        cancelDraft()
        cancelSelectionInteraction()
        isSelectionMode = true
    }

    func activateDrawingTool(_ tool: ScreenshotAnnotationKind) {
        cancelDraft()
        cancelSelectionInteraction()
        selectedTool = tool
        isSelectionMode = false
        selectedAnnotationID = nil
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
        selectedAnnotationID = nil
        draftAnnotation = nil
        draftID = UUID()
        return true
    }

    func cancelDraft() {
        draftAnnotation = nil
        draftID = UUID()
    }

    func undo() {
        cancelSelectionInteraction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        sanitizeSelection()
        updateHistoryFlags()
    }

    func redo() {
        cancelSelectionInteraction()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        sanitizeSelection()
        updateHistoryFlags()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        cancelSelectionInteraction()
        recordUndoPoint()
        annotations.removeAll()
        selectedAnnotationID = nil
    }

    func beginSelectionInteraction(
        at point: TracePoint,
        hitTolerance: Double,
        handleTolerance: Double
    ) {
        guard isSelectionMode, !selectionInteractionActive else { return }
        selectionInteractionActive = true
        let point = clamped(point)

        if let selected = selectedAnnotation,
           let handle = ScreenshotAnnotationGeometry.resizeHandle(
               for: selected,
               at: point,
               tolerance: handleTolerance
           ) {
            activeTransform = ActiveTransform(
                baseline: annotations,
                original: selected,
                startPoint: point,
                operation: .resize(handle)
            )
            return
        }

        guard let hitID = ScreenshotAnnotationGeometry.topmostAnnotationID(
            in: annotations,
            at: point,
            tolerance: hitTolerance
        ), let hit = annotations.first(where: { $0.id == hitID }) else {
            selectedAnnotationID = nil
            activeTransform = nil
            return
        }

        selectedAnnotationID = hitID
        selectedColor = hit.style.color
        if hit.kind == .text, let text = hit.text {
            textDraft = text
        }
        activeTransform = ActiveTransform(
            baseline: annotations,
            original: hit,
            startPoint: point,
            operation: .move
        )
    }

    func updateSelectionInteraction(to point: TracePoint) {
        guard selectionInteractionActive, let activeTransform else { return }
        let updated: ScreenshotAnnotation
        switch activeTransform.operation {
        case .move:
            updated = ScreenshotAnnotationGeometry.moved(
                activeTransform.original,
                byX: clamped(point).x - activeTransform.startPoint.x,
                y: clamped(point).y - activeTransform.startPoint.y
            )
        case let .resize(handle):
            updated = ScreenshotAnnotationGeometry.resized(
                activeTransform.original,
                handle: handle,
                to: clamped(point)
            )
        }
        replaceAnnotation(updated)
    }

    func endSelectionInteraction() {
        guard selectionInteractionActive else { return }
        selectionInteractionActive = false
        guard let activeTransform else { return }
        self.activeTransform = nil
        if activeTransform.baseline != annotations {
            recordUndoPoint(activeTransform.baseline)
        }
    }

    func cancelSelectionInteraction() {
        selectionInteractionActive = false
        guard let activeTransform else { return }
        annotations = activeTransform.baseline
        self.activeTransform = nil
    }

    func deleteSelected() {
        guard let selectedAnnotationID,
              annotations.contains(where: { $0.id == selectedAnnotationID }) else { return }
        cancelSelectionInteraction()
        recordUndoPoint()
        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
    }

    func setColor(_ color: TraceColor) {
        selectedColor = color
        guard isSelectionMode,
              let selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else {
            return
        }
        guard annotations[index].style.color != color else { return }
        recordUndoPoint()
        annotations[index].style.color = color
        if let fill = annotations[index].style.fillColor {
            annotations[index].style.fillColor = TraceColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: fill.alpha
            )
        }
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
            bounds = ScreenshotAnnotationGeometry.bounds(
                from: start,
                to: end,
                minimumExtent: minimumExtent
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

    private func replaceAnnotation(_ annotation: ScreenshotAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    private func sanitizeSelection() {
        guard let selectedAnnotationID else { return }
        if !annotations.contains(where: { $0.id == selectedAnnotationID }) {
            self.selectedAnnotationID = nil
        }
    }

    private func recordUndoPoint(_ snapshot: [ScreenshotAnnotation]? = nil) {
        undoStack.append(snapshot ?? annotations)
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
