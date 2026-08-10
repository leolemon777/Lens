import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class ScreenshotAnnotationEditorModelTests: XCTestCase {
    func testCanvasChangesRoundTripAndUndoAsSingleSliderInteraction() {
        let model = makeModel()
        model.setCanvasEnabled(true)
        model.setCanvasAspectRatio(.square)
        model.beginCanvasAdjustment()
        model.setCanvasPadding(0.12)
        model.setCanvasPadding(0.18)
        model.endCanvasAdjustment()

        XCTAssertEqual(model.plan.canvasStyle?.aspectRatio, .square)
        XCTAssertEqual(model.plan.canvasStyle?.padding, 0.18)
        model.undo()
        XCTAssertEqual(model.canvasStyle?.padding, 0.08)
        model.redo()
        XCTAssertEqual(model.canvasStyle?.padding, 0.18)

        let reopened = ScreenshotAnnotationEditorModel(
            sourceDimensions: model.sourceDimensions,
            existingPlan: model.plan
        )
        XCTAssertEqual(reopened.canvasStyle, model.canvasStyle)
    }

    func testReverseDragCreatesStandardizedRectangleBounds() {
        let model = makeModel()
        model.selectedTool = .rectangle

        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.8, y: 0.7),
            end: TracePoint(x: 0.2, y: 0.3)
        ))

        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].bounds.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(model.annotations[0].bounds.y, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(model.annotations[0].bounds.width, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(model.annotations[0].bounds.height, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(model.annotations[0].style.fillColor?.alpha, 0.10)
    }

    func testArrowPreservesDirectionAndRejectsTinyGesture() {
        let model = makeModel()
        model.selectedTool = .arrow

        XCTAssertFalse(model.commitDraft(
            start: TracePoint(x: 0.4, y: 0.4),
            end: TracePoint(x: 0.405, y: 0.405)
        ))
        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.8, y: 0.7),
            end: TracePoint(x: 0.2, y: 0.3)
        ))

        XCTAssertEqual(model.annotations[0].start, TracePoint(x: 0.8, y: 0.7))
        XCTAssertEqual(model.annotations[0].end, TracePoint(x: 0.2, y: 0.3))
    }

    func testTextClickUsesDefaultBoundsAndFallbackText() {
        let model = makeModel()
        model.selectedTool = .text
        model.textDraft = "   "

        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.5, y: 0.5),
            end: TracePoint(x: 0.5, y: 0.5)
        ))

        XCTAssertEqual(model.annotations[0].text, "文字")
        XCTAssertEqual(model.annotations[0].bounds.width, 0.26)
    }

    func testStepToolNumbersClicksAndHighlightUsesTranslucentFill() {
        let model = makeModel()
        model.activateDrawingTool(.step)

        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.2, y: 0.25),
            end: TracePoint(x: 0.2, y: 0.25)
        ))
        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.7, y: 0.65),
            end: TracePoint(x: 0.7, y: 0.65)
        ))
        XCTAssertEqual(model.annotations.map(\.text), ["1", "2"])
        XCTAssertEqual(model.annotations[0].bounds.width, 0.075, accuracy: 0.000_001)

        model.activateDrawingTool(.highlight)
        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.1, y: 0.4),
            end: TracePoint(x: 0.8, y: 0.5)
        ))
        XCTAssertEqual(model.annotations.last?.kind, .highlight)
        XCTAssertEqual(model.annotations.last?.style.fillColor?.alpha, 0.28)
        XCTAssertEqual(model.annotations.last?.style.lineWidth, 0)
    }

    func testFreehandCollectsPathAndMovesAsOneObject() {
        let model = makeModel()
        model.activateDrawingTool(.freehand)
        model.updateDraft(
            start: TracePoint(x: 0.1, y: 0.2),
            end: TracePoint(x: 0.2, y: 0.3)
        )
        model.updateDraft(
            start: TracePoint(x: 0.1, y: 0.2),
            end: TracePoint(x: 0.35, y: 0.25)
        )

        XCTAssertTrue(model.commitDraft(
            start: TracePoint(x: 0.1, y: 0.2),
            end: TracePoint(x: 0.48, y: 0.4)
        ))
        XCTAssertEqual(model.annotations[0].kind, .freehand)
        XCTAssertEqual(model.annotations[0].points, [
            TracePoint(x: 0.1, y: 0.2),
            TracePoint(x: 0.2, y: 0.3),
            TracePoint(x: 0.35, y: 0.25),
            TracePoint(x: 0.48, y: 0.4)
        ])

        let originalFirst = model.annotations[0].points?.first
        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: TracePoint(x: 0.2, y: 0.3),
            hitTolerance: 0.08,
            handleTolerance: 0.01
        )
        model.updateSelectionInteraction(to: TracePoint(x: 0.3, y: 0.4))
        model.endSelectionInteraction()

        XCTAssertEqual(
            model.selectedAnnotation?.points?.first?.x ?? 0,
            (originalFirst?.x ?? 0) + 0.1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            model.selectedAnnotation?.points?.first?.y ?? 0,
            (originalFirst?.y ?? 0) + 0.1,
            accuracy: 0.000_001
        )
    }

    func testUndoRedoAndClearPreserveObjectHistory() {
        let model = makeModel()
        model.selectedTool = .ellipse
        _ = model.commitDraft(
            start: TracePoint(x: 0.1, y: 0.1),
            end: TracePoint(x: 0.4, y: 0.4)
        )
        model.selectedTool = .pixelate
        _ = model.commitDraft(
            start: TracePoint(x: 0.5, y: 0.5),
            end: TracePoint(x: 0.8, y: 0.8)
        )

        model.undo()
        XCTAssertEqual(model.annotations.map(\.kind), [.ellipse])
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.annotations.map(\.kind), [.ellipse, .pixelate])
        model.clear()
        XCTAssertTrue(model.annotations.isEmpty)
        model.undo()
        XCTAssertEqual(model.annotations.count, 2)
    }

    func testSelectionMovesTopmostObjectAndUndoRestoresItsPosition() {
        let model = makeModel()
        model.selectedTool = .rectangle
        _ = model.commitDraft(
            start: TracePoint(x: 0.1, y: 0.1),
            end: TracePoint(x: 0.4, y: 0.4)
        )
        model.selectedTool = .ellipse
        _ = model.commitDraft(
            start: TracePoint(x: 0.2, y: 0.2),
            end: TracePoint(x: 0.5, y: 0.5)
        )
        let topmostID = model.annotations.last?.id

        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: TracePoint(x: 0.3, y: 0.3),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.updateSelectionInteraction(to: TracePoint(x: 0.5, y: 0.55))
        model.endSelectionInteraction()

        XCTAssertEqual(model.selectedAnnotationID, topmostID)
        XCTAssertEqual(model.selectedAnnotation?.bounds.x ?? 0, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(model.selectedAnnotation?.bounds.y ?? 0, 0.45, accuracy: 0.000_001)

        model.undo()
        XCTAssertEqual(model.selectedAnnotation?.bounds.x ?? 0, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(model.selectedAnnotation?.bounds.y ?? 0, 0.2, accuracy: 0.000_001)
    }

    func testSelectionResizesRecolorsDeletesAndUndoRestoresObject() {
        let model = makeModel()
        model.selectedTool = .rectangle
        _ = model.commitDraft(
            start: TracePoint(x: 0.2, y: 0.2),
            end: TracePoint(x: 0.4, y: 0.4)
        )
        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: TracePoint(x: 0.3, y: 0.3),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.endSelectionInteraction()

        model.beginSelectionInteraction(
            at: TracePoint(x: 0.4, y: 0.4),
            hitTolerance: 0.01,
            handleTolerance: 0.02
        )
        model.updateSelectionInteraction(to: TracePoint(x: 0.7, y: 0.8))
        model.endSelectionInteraction()
        XCTAssertEqual(model.selectedAnnotation?.bounds.width ?? 0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(model.selectedAnnotation?.bounds.height ?? 0, 0.6, accuracy: 0.000_001)

        model.setColor(.blue)
        XCTAssertEqual(model.selectedAnnotation?.style.color, .blue)
        XCTAssertEqual(model.selectedAnnotation?.style.fillColor?.alpha, 0.10)

        model.deleteSelected()
        XCTAssertTrue(model.annotations.isEmpty)
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].style.color, .blue)
    }

    private func makeModel() -> ScreenshotAnnotationEditorModel {
        ScreenshotAnnotationEditorModel(
            sourceDimensions: TraceDimensions(width: 1_000, height: 600)
        )
    }
}
