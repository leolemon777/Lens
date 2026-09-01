import XCTest
import LensCore
@testable import LensMac

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
            start: LensPoint(x: 0.8, y: 0.7),
            end: LensPoint(x: 0.2, y: 0.3)
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
            start: LensPoint(x: 0.4, y: 0.4),
            end: LensPoint(x: 0.405, y: 0.405)
        ))
        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.8, y: 0.7),
            end: LensPoint(x: 0.2, y: 0.3)
        ))

        XCTAssertEqual(model.annotations[0].start, LensPoint(x: 0.8, y: 0.7))
        XCTAssertEqual(model.annotations[0].end, LensPoint(x: 0.2, y: 0.3))
    }

    func testTextClickUsesDefaultBoundsAndFallbackText() {
        let model = makeModel()
        model.selectedTool = .text
        model.textDraft = "   "

        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.5, y: 0.5),
            end: LensPoint(x: 0.5, y: 0.5)
        ))

        XCTAssertEqual(model.annotations[0].text, "文字")
        XCTAssertEqual(model.annotations[0].bounds.width, 0.26)
    }

    func testStepToolNumbersClicksAndHighlightUsesTranslucentFill() {
        let model = makeModel()
        model.activateDrawingTool(.step)

        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.2, y: 0.25),
            end: LensPoint(x: 0.2, y: 0.25)
        ))
        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.7, y: 0.65),
            end: LensPoint(x: 0.7, y: 0.65)
        ))
        XCTAssertEqual(model.annotations.map(\.text), ["1", "2"])
        XCTAssertEqual(model.annotations[0].bounds.width, 0.075, accuracy: 0.000_001)

        model.activateDrawingTool(.highlight)
        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.1, y: 0.4),
            end: LensPoint(x: 0.8, y: 0.5)
        ))
        XCTAssertEqual(model.annotations.last?.kind, .highlight)
        XCTAssertEqual(model.annotations.last?.style.fillColor?.alpha, 0.28)
        XCTAssertEqual(model.annotations.last?.style.lineWidth, 0)
    }

    func testFreehandCollectsPathAndMovesAsOneObject() {
        let model = makeModel()
        model.activateDrawingTool(.freehand)
        model.updateDraft(
            start: LensPoint(x: 0.1, y: 0.2),
            end: LensPoint(x: 0.2, y: 0.3)
        )
        model.updateDraft(
            start: LensPoint(x: 0.1, y: 0.2),
            end: LensPoint(x: 0.35, y: 0.25)
        )

        XCTAssertTrue(model.commitDraft(
            start: LensPoint(x: 0.1, y: 0.2),
            end: LensPoint(x: 0.48, y: 0.4)
        ))
        XCTAssertEqual(model.annotations[0].kind, .freehand)
        XCTAssertEqual(model.annotations[0].points, [
            LensPoint(x: 0.1, y: 0.2),
            LensPoint(x: 0.2, y: 0.3),
            LensPoint(x: 0.35, y: 0.25),
            LensPoint(x: 0.48, y: 0.4)
        ])

        let originalFirst = model.annotations[0].points?.first
        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: LensPoint(x: 0.2, y: 0.3),
            hitTolerance: 0.08,
            handleTolerance: 0.01
        )
        model.updateSelectionInteraction(to: LensPoint(x: 0.3, y: 0.4))
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
            start: LensPoint(x: 0.1, y: 0.1),
            end: LensPoint(x: 0.4, y: 0.4)
        )
        model.selectedTool = .pixelate
        _ = model.commitDraft(
            start: LensPoint(x: 0.5, y: 0.5),
            end: LensPoint(x: 0.8, y: 0.8)
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
            start: LensPoint(x: 0.1, y: 0.1),
            end: LensPoint(x: 0.4, y: 0.4)
        )
        model.selectedTool = .ellipse
        _ = model.commitDraft(
            start: LensPoint(x: 0.2, y: 0.2),
            end: LensPoint(x: 0.5, y: 0.5)
        )
        let topmostID = model.annotations.last?.id

        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: LensPoint(x: 0.3, y: 0.3),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.updateSelectionInteraction(to: LensPoint(x: 0.5, y: 0.55))
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
            start: LensPoint(x: 0.2, y: 0.2),
            end: LensPoint(x: 0.4, y: 0.4)
        )
        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: LensPoint(x: 0.3, y: 0.3),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.endSelectionInteraction()

        model.beginSelectionInteraction(
            at: LensPoint(x: 0.4, y: 0.4),
            hitTolerance: 0.01,
            handleTolerance: 0.02
        )
        model.updateSelectionInteraction(to: LensPoint(x: 0.7, y: 0.8))
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

    func testGradientColorAndEffectStrengthApplyToNewAndSelectedAnnotations() {
        let model = makeModel()
        model.setGradient(start: .orange, end: .pink)
        model.activateDrawingTool(.arrow)
        _ = model.commitDraft(
            start: LensPoint(x: 0.1, y: 0.1),
            end: LensPoint(x: 0.7, y: 0.6)
        )
        XCTAssertEqual(model.annotations[0].style.color, .orange)
        XCTAssertEqual(model.annotations[0].style.gradientEndColor, .pink)

        model.activateDrawingTool(.pixelate)
        model.setEffectIntensity(0.026)
        _ = model.commitDraft(
            start: LensPoint(x: 0.2, y: 0.2),
            end: LensPoint(x: 0.5, y: 0.5)
        )
        XCTAssertEqual(model.annotations[1].style.intensity, 0.026, accuracy: 0.000_001)

        model.activateSelectionTool()
        model.beginSelectionInteraction(
            at: LensPoint(x: 0.35, y: 0.35),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.endSelectionInteraction()
        model.setEffectIntensity(0.012)
        XCTAssertEqual(model.selectedAnnotation?.style.intensity ?? 0, 0.012, accuracy: 0.000_001)
    }

    func testRenderingStateRejectsOverlappingCopySaveAndExportWork() {
        let model = makeModel()

        XCTAssertTrue(model.beginRendering())
        XCTAssertTrue(model.isRendering)
        XCTAssertFalse(model.beginRendering())

        model.endRendering()
        XCTAssertFalse(model.isRendering)
        XCTAssertTrue(model.beginRendering())
        model.endRendering()
    }

    func testClipboardFeedbackReportsTheLatestCopyOutcomeImmediately() {
        let model = makeModel()

        model.showClipboardFeedback(succeeded: true)
        XCTAssertEqual(model.clipboardFeedback, .copied)

        model.showClipboardFeedback(succeeded: false)
        XCTAssertEqual(model.clipboardFeedback, .failed)
    }

    func testSuggestedRedactionsCanBeReviewedIndividuallyAndUndoAppliedOne() {
        let first = ScreenshotAnnotation(
            id: UUID(),
            kind: .pixelate,
            bounds: LensRect(x: 0.1, y: 0.2, width: 0.2, height: 0.04)
        )
        let second = ScreenshotAnnotation(
            id: UUID(),
            kind: .pixelate,
            bounds: LensRect(x: 0.6, y: 0.7, width: 0.25, height: 0.04)
        )
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: LensDimensions(width: 1_000, height: 600),
            suggestedRedactions: [first, second]
        )

        model.applySuggestedRedaction(first.id)
        XCTAssertEqual(model.annotations.map(\.id), [first.id])
        XCTAssertEqual(model.pendingRedactionSuggestions.map(\.id), [second.id])
        model.undo()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertEqual(
            model.pendingRedactionSuggestions.map(\.id),
            [second.id]
        )

        model.dismissSuggestedRedaction(second.id)
        XCTAssertTrue(model.pendingRedactionSuggestions.isEmpty)
    }

    private func makeModel() -> ScreenshotAnnotationEditorModel {
        ScreenshotAnnotationEditorModel(
            sourceDimensions: LensDimensions(width: 1_000, height: 600)
        )
    }
}
