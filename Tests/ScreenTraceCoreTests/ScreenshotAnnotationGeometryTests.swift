import XCTest
@testable import ScreenTraceCore

final class ScreenshotAnnotationGeometryTests: XCTestCase {
    func testHitTestingChoosesTopmostObjectAndUsesArrowSegmentDistance() {
        let rectangle = annotation(
            kind: .rectangle,
            bounds: TraceRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        )
        let ellipse = annotation(
            kind: .ellipse,
            bounds: TraceRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        )
        let arrow = annotation(
            kind: .arrow,
            bounds: TraceRect(x: 0.1, y: 0.8, width: 0.8, height: 0.006),
            start: TracePoint(x: 0.1, y: 0.8),
            end: TracePoint(x: 0.9, y: 0.8)
        )

        XCTAssertEqual(
            ScreenshotAnnotationGeometry.topmostAnnotationID(
                in: [rectangle, ellipse],
                at: TracePoint(x: 0.3, y: 0.3)
            ),
            ellipse.id
        )
        XCTAssertEqual(
            ScreenshotAnnotationGeometry.topmostAnnotationID(
                in: [arrow],
                at: TracePoint(x: 0.5, y: 0.81),
                tolerance: 0.012
            ),
            arrow.id
        )
        XCTAssertNil(
            ScreenshotAnnotationGeometry.topmostAnnotationID(
                in: [arrow],
                at: TracePoint(x: 0.5, y: 0.86),
                tolerance: 0.012
            )
        )
    }

    func testMovingClampsAtCanvasEdgeAndPreservesArrowEndpoints() {
        let arrow = annotation(
            kind: .arrow,
            bounds: TraceRect(x: 0.75, y: 0.7, width: 0.2, height: 0.2),
            start: TracePoint(x: 0.75, y: 0.7),
            end: TracePoint(x: 0.95, y: 0.9)
        )

        let moved = ScreenshotAnnotationGeometry.moved(arrow, byX: 0.4, y: 0.5)

        XCTAssertEqual(moved.bounds.x, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(moved.bounds.y, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(moved.start, TracePoint(x: 0.8, y: 0.8))
        XCTAssertEqual(moved.end, TracePoint(x: 1, y: 1))
    }

    func testCornerResizeKeepsOppositeCornerFixedAndScalesText() {
        let text = annotation(
            kind: .text,
            bounds: TraceRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1),
            text: "重点",
            style: ScreenshotAnnotationStyle(fontSize: 0.04)
        )

        let resized = ScreenshotAnnotationGeometry.resized(
            text,
            handle: .bottomRight,
            to: TracePoint(x: 0.8, y: 0.4)
        )

        XCTAssertEqual(resized.bounds.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.y, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.width, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(resized.bounds.height, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(resized.style.fontSize, 0.08, accuracy: 0.000_001)
    }

    func testArrowEndpointHandlePreservesDirectionAndRebuildsBounds() {
        let arrow = annotation(
            kind: .arrow,
            bounds: TraceRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            start: TracePoint(x: 0.6, y: 0.2),
            end: TracePoint(x: 0.2, y: 0.6)
        )

        XCTAssertEqual(
            ScreenshotAnnotationGeometry.resizeHandle(
                for: arrow,
                at: TracePoint(x: 0.6, y: 0.2)
            ),
            .arrowStart
        )
        let resized = ScreenshotAnnotationGeometry.resized(
            arrow,
            handle: .arrowEnd,
            to: TracePoint(x: 0.85, y: 0.9)
        )

        XCTAssertEqual(resized.start, TracePoint(x: 0.6, y: 0.2))
        XCTAssertEqual(resized.end, TracePoint(x: 0.85, y: 0.9))
        XCTAssertEqual(resized.bounds, TraceRect(x: 0.6, y: 0.2, width: 0.25, height: 0.7))
    }

    private func annotation(
        kind: ScreenshotAnnotationKind,
        bounds: TraceRect,
        start: TracePoint? = nil,
        end: TracePoint? = nil,
        text: String? = nil,
        style: ScreenshotAnnotationStyle = ScreenshotAnnotationStyle()
    ) -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            kind: kind,
            bounds: bounds,
            start: start,
            end: end,
            text: text,
            style: style
        )
    }
}
