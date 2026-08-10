import AppKit
import CoreGraphics
import XCTest
@testable import ScreenTraceMac

@MainActor
final class CaptureOverlayViewTests: XCTestCase {
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

    private func makeRegionView() -> (CaptureOverlayView, SelectionDelegate) {
        let view = CaptureOverlayView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayID: 1,
            displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: .region(
                action: .screenshot,
                snapRects: [CGRect(x: 100, y: 0, width: 600, height: 600)]
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
}
