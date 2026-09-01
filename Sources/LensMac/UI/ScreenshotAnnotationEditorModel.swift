import Foundation
import LensCore

enum ScreenshotClipboardFeedback: Equatable {
    case copied
    case failed
}

@MainActor
final class ScreenshotAnnotationEditorModel: ObservableObject {
    let sourceDimensions: LensDimensions

    @Published var selectedTool: ScreenshotAnnotationKind = .arrow
    @Published var selectedColor: LensColor = .red
    @Published var selectedGradientEndColor: LensColor?
    @Published var effectIntensity = 0.014
    @Published var textDraft = "重点"
    @Published private(set) var annotations: [ScreenshotAnnotation]
    @Published private(set) var canvasStyle: ScreenshotCanvasStyle?
    @Published private(set) var draftAnnotation: ScreenshotAnnotation?
    @Published private(set) var isSelectionMode = false
    @Published private(set) var selectedAnnotationID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isRendering = false
    @Published private(set) var clipboardFeedback: ScreenshotClipboardFeedback?

    private struct EditorSnapshot: Equatable {
        let annotations: [ScreenshotAnnotation]
        let canvasStyle: ScreenshotCanvasStyle?
    }

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var draftID = UUID()
    private var draftPathPoints: [LensPoint] = []
    private var selectionInteractionActive = false
    private var activeTransform: ActiveTransform?
    private var canvasAdjustmentBaseline: EditorSnapshot?

    private struct ActiveTransform {
        enum Operation {
            case move
            case resize(ScreenshotAnnotationResizeHandle)
        }

        let baseline: [ScreenshotAnnotation]
        let original: ScreenshotAnnotation
        let startPoint: LensPoint
        let operation: Operation
    }

    init(
        sourceDimensions: LensDimensions,
        existingPlan: ScreenshotEditPlan? = nil,
        suggestedRedactions: [ScreenshotAnnotation] = [],
        ocrFullText: String? = nil
    ) {
        self.sourceDimensions = sourceDimensions
        if existingPlan?.sourceDimensions == sourceDimensions {
            annotations = existingPlan?.annotations ?? []
            canvasStyle = existingPlan?.canvasStyle
        } else {
            annotations = []
            canvasStyle = nil
        }
        pendingRedactionSuggestions = suggestedRedactions
        self.ocrFullText = ocrFullText
    }

    let ocrFullText: String?

    var showsCodeCardExport: Bool {
        ocrFullText.map { CodeCardRenderer.isLikelyCode($0) } == true
    }

    @Published private(set) var pendingRedactionSuggestions: [ScreenshotAnnotation] = []

    var suggestedRedactionCount: Int { pendingRedactionSuggestions.count }

    /// Applies the auto-detected sensitive-text redactions in one tap. The
    /// inserted annotations are ordinary pixelate objects: reviewable,
    /// movable, and undoable like any hand-drawn one.
    func applySuggestedRedactions() {
        guard !pendingRedactionSuggestions.isEmpty else { return }
        recordUndoPoint()
        annotations.append(contentsOf: pendingRedactionSuggestions)
        pendingRedactionSuggestions = []
    }

    /// Applies one suggestion after the user has inspected its highlighted
    /// bounds. Keeping this operation separate from the bulk action makes the
    /// review surface genuinely selective instead of silently accepting every
    /// OCR hit at once.
    func applySuggestedRedaction(_ id: UUID) {
        guard let index = pendingRedactionSuggestions.firstIndex(where: { $0.id == id }) else {
            return
        }
        recordUndoPoint()
        annotations.append(pendingRedactionSuggestions.remove(at: index))
    }

    /// Dismisses one suggestion without changing the screenshot edit plan.
    /// Suggestions are regenerated from OCR the next time the editor opens.
    func dismissSuggestedRedaction(_ id: UUID) {
        pendingRedactionSuggestions.removeAll { $0.id == id }
    }

    var plan: ScreenshotEditPlan {
        ScreenshotEditPlan(
            sourceDimensions: sourceDimensions,
            annotations: annotations,
            canvasStyle: canvasStyle
        )
    }

    var selectedAnnotation: ScreenshotAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    func beginRendering() -> Bool {
        guard !isRendering else { return false }
        isRendering = true
        return true
    }

    func endRendering() {
        isRendering = false
    }

    func showClipboardFeedback(succeeded: Bool) {
        let feedback: ScreenshotClipboardFeedback = succeeded ? .copied : .failed
        clipboardFeedback = feedback
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, self?.clipboardFeedback == feedback else { return }
            self?.clipboardFeedback = nil
        }
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

    func updateDraft(start: LensPoint, end: LensPoint) {
        if selectedTool == .freehand {
            if draftPathPoints.isEmpty {
                appendDraftPathPoint(clamped(start))
            }
            appendDraftPathPoint(clamped(end))
            draftAnnotation = makeFreehandAnnotation(id: draftID, points: draftPathPoints)
            return
        }
        draftAnnotation = makeAnnotation(
            id: draftID,
            start: clamped(start),
            end: clamped(end)
        )
    }

    @discardableResult
    func commitDraft(start: LensPoint, end: LensPoint) -> Bool {
        let start = clamped(start)
        let end = clamped(end)
        let annotation: ScreenshotAnnotation?
        if selectedTool == .freehand {
            if draftPathPoints.isEmpty {
                appendDraftPathPoint(start)
            }
            appendDraftPathPoint(end)
            annotation = makeFreehandAnnotation(id: draftID, points: draftPathPoints)
        } else {
            annotation = makeAnnotation(id: draftID, start: start, end: end)
        }
        guard let annotation else {
            cancelDraft()
            return false
        }
        recordUndoPoint()
        annotations.append(annotation)
        selectedAnnotationID = nil
        draftAnnotation = nil
        draftID = UUID()
        draftPathPoints.removeAll(keepingCapacity: true)
        return true
    }

    func cancelDraft() {
        draftAnnotation = nil
        draftID = UUID()
        draftPathPoints.removeAll(keepingCapacity: true)
    }

    func undo() {
        cancelSelectionInteraction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        apply(previous)
        sanitizeSelection()
        updateHistoryFlags()
    }

    func redo() {
        cancelSelectionInteraction()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        apply(next)
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
        at point: LensPoint,
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
        selectedGradientEndColor = hit.style.gradientEndColor
        if hit.kind == .blur || hit.kind == .pixelate {
            effectIntensity = hit.style.intensity
        }
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

    func updateSelectionInteraction(to point: LensPoint) {
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

    func setColor(_ color: LensColor) {
        selectedColor = color
        selectedGradientEndColor = nil
        guard isSelectionMode,
              let selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else {
            return
        }
        guard annotations[index].style.color != color
                || annotations[index].style.gradientEndColor != nil else { return }
        recordUndoPoint()
        annotations[index].style.color = color
        annotations[index].style.gradientEndColor = nil
        if let fill = annotations[index].style.fillColor {
            annotations[index].style.fillColor = LensColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: fill.alpha
            )
        }
    }

    func setGradient(start: LensColor, end: LensColor) {
        selectedColor = start
        selectedGradientEndColor = end
        guard isSelectionMode,
              let selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) else {
            return
        }
        guard annotations[index].style.color != start
                || annotations[index].style.gradientEndColor != end else { return }
        recordUndoPoint()
        annotations[index].style.color = start
        annotations[index].style.gradientEndColor = end
        if let fill = annotations[index].style.fillColor {
            annotations[index].style.fillColor = LensColor(
                red: start.red,
                green: start.green,
                blue: start.blue,
                alpha: fill.alpha
            )
        }
    }

    func setEffectIntensity(_ intensity: Double) {
        let normalized = min(max(intensity, 0.004), 0.06)
        effectIntensity = normalized
        guard isSelectionMode,
              let selectedAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }),
              annotations[index].kind == .blur || annotations[index].kind == .pixelate else {
            return
        }
        guard annotations[index].style.intensity != normalized else { return }
        recordUndoPoint()
        annotations[index].style.intensity = normalized
    }

    func setCanvasEnabled(_ enabled: Bool) {
        guard enabled != (canvasStyle != nil) else { return }
        recordUndoPoint()
        canvasStyle = enabled ? ScreenshotCanvasStyle() : nil
    }

    func setCanvasBackgroundKind(_ kind: ScreenshotCanvasBackgroundKind) {
        mutateCanvas { $0.backgroundKind = kind }
    }

    func setCanvasAspectRatio(_ aspectRatio: ScreenshotCanvasAspectRatio) {
        mutateCanvas { $0.aspectRatio = aspectRatio }
    }

    func applyCanvasPreset(primary: LensColor, secondary: LensColor) {
        mutateCanvas {
            $0.primaryColor = primary
            $0.secondaryColor = secondary
        }
    }

    func beginCanvasAdjustment() {
        guard canvasAdjustmentBaseline == nil else { return }
        canvasAdjustmentBaseline = currentSnapshot
    }

    func setCanvasPadding(_ value: Double) {
        mutateCanvas(recordHistory: canvasAdjustmentBaseline == nil) {
            $0.padding = value
        }
    }

    func setCanvasCornerRadius(_ value: Double) {
        mutateCanvas(recordHistory: canvasAdjustmentBaseline == nil) {
            $0.cornerRadius = value
        }
    }

    func endCanvasAdjustment() {
        guard let baseline = canvasAdjustmentBaseline else { return }
        canvasAdjustmentBaseline = nil
        guard baseline != currentSnapshot else { return }
        recordUndoSnapshot(baseline)
    }

    func setCanvasShadowEnabled(_ enabled: Bool) {
        mutateCanvas {
            $0.shadowRadius = enabled ? 0.035 : 0
            $0.shadowOpacity = enabled ? 0.32 : 0
        }
    }

    private func makeAnnotation(
        id: UUID,
        start: LensPoint,
        end: LensPoint
    ) -> ScreenshotAnnotation? {
        let deltaX = abs(end.x - start.x)
        let deltaY = abs(end.y - start.y)
        let distance = hypot(end.x - start.x, end.y - start.y)

        let minimumExtent = 0.006
        let bounds: LensRect
        if (selectedTool == .text || selectedTool == .step)
            && deltaX < minimumExtent && deltaY < minimumExtent {
            let defaultSize = selectedTool == .step ? 0.075 : 0.08
            let defaultWidth = selectedTool == .step ? defaultSize : 0.26
            bounds = LensRect(
                x: min(max(start.x - (selectedTool == .step ? defaultSize / 2 : 0), 0), 1 - defaultWidth),
                y: min(max(start.y - (selectedTool == .step ? defaultSize / 2 : 0), 0), 1 - defaultSize),
                width: defaultWidth,
                height: defaultSize
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
        let fillColor: LensColor? = switch selectedTool {
        case .rectangle, .ellipse:
            LensColor(
                red: selectedColor.red,
                green: selectedColor.green,
                blue: selectedColor.blue,
                alpha: 0.10
            )
        case .highlight:
            LensColor(
                red: selectedColor.red,
                green: selectedColor.green,
                blue: selectedColor.blue,
                alpha: 0.28
            )
        case .step:
            selectedColor
        default:
            nil
        }
        let style = ScreenshotAnnotationStyle(
            lineWidth: selectedTool == .highlight ? 0 : 0.006,
            fontSize: 0.045,
            color: selectedColor,
            gradientEndColor: selectedGradientEndColor,
            fillColor: fillColor,
            intensity: selectedTool == .pixelate
                ? max(effectIntensity, 0.018)
                : effectIntensity
        )
        let annotationText: String? = switch selectedTool {
        case .text: normalizedTextDraft
        case .step: String(nextStepNumber)
        default: nil
        }
        return ScreenshotAnnotation(
            id: id,
            kind: selectedTool,
            bounds: bounds,
            start: selectedTool == .arrow ? start : nil,
            end: selectedTool == .arrow ? end : nil,
            text: annotationText,
            style: style
        )
    }

    private func makeFreehandAnnotation(
        id: UUID,
        points: [LensPoint]
    ) -> ScreenshotAnnotation? {
        let simplified = simplifyPath(points, minimumDistance: 0.0015)
        guard simplified.count >= 2,
              let bounds = ScreenshotAnnotationGeometry.bounds(for: simplified),
              let first = simplified.first,
              let last = simplified.last,
              hypot(last.x - first.x, last.y - first.y) >= 0.006
                || pathLength(simplified) >= 0.012 else {
            return nil
        }
        return ScreenshotAnnotation(
            id: id,
            kind: .freehand,
            bounds: bounds,
            points: simplified,
            style: ScreenshotAnnotationStyle(
                lineWidth: 0.006,
                color: selectedColor,
                gradientEndColor: selectedGradientEndColor
            )
        )
    }

    private var nextStepNumber: Int {
        annotations
            .filter { $0.kind == .step }
            .compactMap { $0.text.flatMap(Int.init) }
            .max()
            .map { $0 + 1 }
            ?? 1
    }

    private func appendDraftPathPoint(_ point: LensPoint) {
        guard let last = draftPathPoints.last else {
            draftPathPoints.append(point)
            return
        }
        guard hypot(point.x - last.x, point.y - last.y) >= 0.0008 else { return }
        draftPathPoints.append(point)
    }

    private func simplifyPath(
        _ points: [LensPoint],
        minimumDistance: Double
    ) -> [LensPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() {
            guard let last = result.last else { continue }
            if hypot(point.x - last.x, point.y - last.y) >= minimumDistance {
                result.append(point)
            }
        }
        if let last = points.last, result.last != last {
            result.append(last)
        }
        return result
    }

    private func pathLength(_ points: [LensPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    private var normalizedTextDraft: String {
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "文字" : trimmed
    }

    private func clamped(_ point: LensPoint) -> LensPoint {
        LensPoint(
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

    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(annotations: annotations, canvasStyle: canvasStyle)
    }

    private func apply(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        canvasStyle = snapshot.canvasStyle
    }

    private func mutateCanvas(
        recordHistory: Bool = true,
        mutation: (inout ScreenshotCanvasStyle) -> Void
    ) {
        var style = canvasStyle ?? ScreenshotCanvasStyle()
        let original = style
        mutation(&style)
        style = style.normalized
        guard style != original || canvasStyle == nil else { return }
        if recordHistory {
            recordUndoPoint()
        }
        canvasStyle = style
    }

    private func recordUndoPoint(_ annotationSnapshot: [ScreenshotAnnotation]? = nil) {
        recordUndoSnapshot(EditorSnapshot(
            annotations: annotationSnapshot ?? annotations,
            canvasStyle: canvasStyle
        ))
    }

    private func recordUndoSnapshot(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
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
