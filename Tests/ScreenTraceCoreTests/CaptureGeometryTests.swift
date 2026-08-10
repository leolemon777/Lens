import CoreGraphics
import XCTest
@testable import ScreenTraceCore

final class CaptureGeometryTests: XCTestCase {
    func testLocalRegionMapsIntoOffsetDisplaySpace() {
        let display = CGRect(x: 1_920, y: -180, width: 1_440, height: 900)
        let local = CGRect(x: 120, y: 80, width: 640, height: 360)

        XCTAssertEqual(
            CaptureGeometry.globalRect(fromLocalRect: local, displayBounds: display),
            CGRect(x: 2_040, y: -100, width: 640, height: 360)
        )
    }

    func testWindowSpanningDisplaysIsClippedToLocalOverlay() {
        let display = CGRect(x: 1_440, y: 0, width: 1_440, height: 900)
        let window = CGRect(x: 1_320, y: 100, width: 420, height: 500)

        XCTAssertEqual(
            CaptureGeometry.localIntersection(of: window, displayBounds: display),
            CGRect(x: 0, y: 100, width: 300, height: 500)
        )
    }

    func testNonIntersectingWindowHasNoLocalRect() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let window = CGRect(x: 1_800, y: 100, width: 400, height: 300)

        XCTAssertNil(CaptureGeometry.localIntersection(of: window, displayBounds: display))
    }

    func testTopmostWindowWinsAtOverlappingPoint() {
        let back = candidate(id: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), order: 4)
        let front = candidate(id: 20, frame: CGRect(x: 100, y: 100, width: 500, height: 400), order: 1)

        XCTAssertEqual(
            CaptureGeometry.topmostWindow(at: CGPoint(x: 250, y: 250), candidates: [back, front])?.id,
            front.id
        )
    }

    func testSmallerWindowBreaksAnAmbiguousStackingTie() {
        let large = candidate(id: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), order: 1)
        let small = candidate(id: 20, frame: CGRect(x: 100, y: 100, width: 300, height: 200), order: 1)

        XCTAssertEqual(
            CaptureGeometry.topmostWindow(at: CGPoint(x: 200, y: 150), candidates: [large, small])?.id,
            small.id
        )
    }

    func testPointOutsideAllWindowsReturnsNil() {
        let window = candidate(id: 10, frame: CGRect(x: 0, y: 0, width: 100, height: 100), order: 0)

        XCTAssertNil(CaptureGeometry.topmostWindow(at: CGPoint(x: 101, y: 50), candidates: [window]))
    }

    func testScreenshotModeRawValuesAreStableForProjectAndShortcutRouting() {
        XCTAssertEqual(ScreenshotCaptureMode.allCases.map(\.rawValue), ["region", "window", "display"])
    }

    func testRecordingModesRemainStableForCrossPlatformRouting() {
        XCTAssertEqual(RecordingCaptureMode.allCases.map(\.rawValue), ["region", "window", "display"])
    }

    func testLegacyCaptureMetadataDecodesWithoutFrameRate() throws {
        let json = """
        {
          "mode": "display",
          "displayID": 7,
          "globalBounds": { "x": 0, "y": 0, "width": 1440, "height": 900 }
        }
        """
        let metadata = try JSONDecoder().decode(
            TraceCaptureMetadata.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metadata.mode, .display)
        XCTAssertNil(metadata.framesPerSecond)
    }

    func testRegionRecordingSourceClipsLocallyAndPreservesGlobalOffset() throws {
        let display = CGRect(x: 1_440, y: -120, width: 1_440, height: 900)
        let source = try XCTUnwrap(CaptureGeometry.regionRecordingSource(
            displayID: 7,
            localRect: CGRect(x: -20, y: 80, width: 660, height: 360),
            displayBounds: display
        ))

        XCTAssertEqual(source.mode, .region)
        XCTAssertEqual(source.displayID, 7)
        XCTAssertEqual(source.sourceRect, CGRect(x: 0, y: 80, width: 640, height: 360))
        XCTAssertEqual(source.captureBounds, CGRect(x: 1_440, y: -40, width: 640, height: 360))
    }

    func testRecordingPixelDimensionsUseRetinaScaleAndEvenCodecSizes() {
        XCTAssertEqual(
            CaptureGeometry.recordingPixelDimensions(
                pointSize: CGSize(width: 641.2, height: 359.1),
                pointPixelScale: 2
            ),
            TraceDimensions(width: 1_284, height: 720)
        )
    }

    func testPointerNormalizationRejectsEventsOutsideRecordingCrop() {
        let bounds = CGRect(x: 2_000, y: -100, width: 800, height: 500)

        XCTAssertEqual(
            CaptureGeometry.normalizedPoint(CGPoint(x: 2_400, y: 150), in: bounds),
            TracePoint(x: 0.5, y: 0.5)
        )
        XCTAssertNil(
            CaptureGeometry.normalizedPoint(CGPoint(x: 1_999, y: 150), in: bounds)
        )
    }

    private func candidate(id: UInt32, frame: CGRect, order: Int) -> WindowSelectionCandidate {
        WindowSelectionCandidate(
            id: id,
            globalFrame: frame,
            frontToBackOrder: order,
            title: "Window \(id)",
            applicationName: "Test"
        )
    }
}
