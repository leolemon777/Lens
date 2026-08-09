import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class ScreenshotAnnotationEditorModelTests: XCTestCase {
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

    private func makeModel() -> ScreenshotAnnotationEditorModel {
        ScreenshotAnnotationEditorModel(
            sourceDimensions: TraceDimensions(width: 1_000, height: 600)
        )
    }
}
