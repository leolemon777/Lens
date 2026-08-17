import AppKit
import CoreGraphics
import XCTest
@testable import ScreenTraceMac

@MainActor
final class CaptureOverlayViewTests: XCTestCase {
    func testOverlayAcceptsTheFirstLightClickAcrossInformationalLabels() {
        let (view, _) = makeRegionView()

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.hitTest(CGPoint(x: 400, y: 300)) === view)
    }

    func testRegionDragSnapsBothHorizontalEdgesBeforeDelivery() throws {
        let (view, delegate) = makeRegionView()

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 97, y: 500)))
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 703, y: 100)))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 703, y: 100)))

        let selection = try XCTUnwrap(delegate.selection)
        XCTAssertEqual(selection.minX, 100)
        XCTAssertEqual(selection.maxX, 700)
        XCTAssertEqual(selection.height, 400)
    }

    func testLightTapAnchorsSelectionAndSecondTapCompletesIt() throws {
        let (view, delegate) = makeRegionView()

        view.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 97, y: 500)
        ))
        view.mouseUp(with: mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 97, y: 500)
        ))
        XCTAssertNil(delegate.selection)

        view.mouseMoved(with: mouseEvent(
            type: .mouseMoved,
            location: CGPoint(x: 703, y: 100)
        ))
        let anchoredGuidance = view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "再轻点完成 · 600 × 400" }
        XCTAssertNotNil(anchoredGuidance)

        view.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 703, y: 100)
        ))
        view.mouseUp(with: mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 703, y: 100)
        ))

        let selection = try XCTUnwrap(delegate.selection)
        XCTAssertEqual(selection.minX, 100)
        XCTAssertEqual(selection.maxX, 700)
        XCTAssertEqual(selection.height, 400)
    }

    func testOptionBypassesSnappingAndArrowAdjustmentSurvivesMouseUp() throws {
        let (optionView, optionDelegate) = makeRegionView()
        optionView.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 97, y: 500),
            modifiers: .option
        ))
        optionView.mouseDragged(with: mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 703, y: 100),
            modifiers: .option
        ))
        optionView.mouseUp(with: mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 703, y: 100),
            modifiers: .option
        ))
        XCTAssertEqual(try XCTUnwrap(optionDelegate.selection).width, 606)

        let (fineView, fineDelegate) = makeRegionView()
        fineView.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 97, y: 500)))
        fineView.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 703, y: 100)))
        fineView.keyDown(with: keyEvent(keyCode: 124))
        fineView.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 703, y: 100)))

        let adjusted = try XCTUnwrap(fineDelegate.selection)
        XCTAssertEqual(adjusted.minX, 100)
        XCTAssertEqual(adjusted.maxX, 701)
    }

    func testRegionDragUsesCompositorLayersWithoutInvalidatingTheFullView() {
        let (view, _) = makeRegionView()
        XCTAssertEqual(view.layerContentsRedrawPolicy, .never)
        XCTAssertTrue(
            view.layer?.sublayers?.contains { $0.name == "capture-region-dimming" } == true
        )

        view.needsDisplay = false
        view.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 80, y: 520)
        ))
        for index in 0..<240 {
            view.mouseDragged(with: mouseEvent(
                type: .leftMouseDragged,
                location: CGPoint(
                    x: 80 + CGFloat(index) * 2,
                    y: 520 - CGFloat(index)
                )
            ))
        }

        XCTAssertFalse(view.needsDisplay)
    }

    func testRegionDragReportsACompactPerformanceSummary() throws {
        let (view, delegate) = makeRegionView()

        view.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 80, y: 520)
        ))
        for index in 0..<12 {
            view.mouseDragged(with: mouseEvent(
                type: .leftMouseDragged,
                location: CGPoint(
                    x: 100 + CGFloat(index) * 10,
                    y: 500 - CGFloat(index) * 8
                )
            ))
        }
        view.mouseUp(with: mouseEvent(
            type: .leftMouseUp,
            location: CGPoint(x: 210, y: 412)
        ))

        let performance = try XCTUnwrap(delegate.dragPerformance)
        XCTAssertEqual(performance.eventCount, 12)
        XCTAssertGreaterThanOrEqual(performance.totalUpdateMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(performance.maximumUpdateMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(performance.averageUpdateMilliseconds, 0)
        XCTAssertLessThanOrEqual(
            performance.maximumUpdateMilliseconds,
            performance.totalUpdateMilliseconds
        )
    }

    func testRegionCompositorCutsARealHoleAndUpdatesTheDimensionLabel() throws {
        let (view, _) = makeRegionView()
        view.mouseDown(with: mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 100, y: 500)
        ))
        view.mouseDragged(with: mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 700, y: 100)
        ))

        let dimmingLayer = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.name == "capture-region-dimming" }
                as? CAShapeLayer
        )
        let dimmingPath = try XCTUnwrap(dimmingLayer.path)
        XCTAssertTrue(dimmingPath.contains(CGPoint(x: 20, y: 20), using: .evenOdd))
        XCTAssertFalse(dimmingPath.contains(CGPoint(x: 400, y: 300), using: .evenOdd))

        let dimensionLabel = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "600 × 400" }
        )
        XCTAssertFalse(dimensionLabel.isHidden)
        XCTAssertEqual(dimensionLabel.layer?.zPosition, 10)
    }

    func testSnapRectsCanArriveAfterTheOverlayIsAlreadyVisible() throws {
        let (view, delegate) = makeRegionView(snapRects: [])
        view.setRegionSnapRects([CGRect(x: 100, y: 0, width: 600, height: 600)])

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 97, y: 500)))
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 703, y: 100)))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 703, y: 100)))

        let selection = try XCTUnwrap(delegate.selection)
        XCTAssertEqual(selection.minX, 100)
        XCTAssertEqual(selection.maxX, 700)
    }

    private func makeRegionView(
        snapRects: [CGRect] = [CGRect(x: 100, y: 0, width: 600, height: 600)]
    ) -> (CaptureOverlayView, SelectionDelegate) {
        let view = CaptureOverlayView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayID: 1,
            displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: .region(
                action: .screenshot,
                snapRects: snapRects
            )
        )
        let delegate = SelectionDelegate()
        view.delegate = delegate
        return (view, delegate)
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func keyEvent(keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

@MainActor
private final class SelectionDelegate: CaptureOverlayViewDelegate {
    var selection: CGRect?
    var dragPerformance: CaptureOverlayDragPerformance?

    func captureOverlayDidCancel(_ view: CaptureOverlayView) {}

    func captureOverlay(
        _ view: CaptureOverlayView,
        didSelect rect: CGRect,
        displayID: CGDirectDisplayID
    ) {
        selection = rect
    }

    func captureOverlay(_ view: CaptureOverlayView, didSelectWindow windowID: CGWindowID) {}
    func captureOverlay(_ view: CaptureOverlayView, didToggleWindow windowID: CGWindowID) {}
    func captureOverlayDidConfirmWindows(_ view: CaptureOverlayView) {}

    func captureOverlay(
        _ view: CaptureOverlayView,
        didMeasureRegionDrag performance: CaptureOverlayDragPerformance
    ) {
        dragPerformance = performance
    }
}
