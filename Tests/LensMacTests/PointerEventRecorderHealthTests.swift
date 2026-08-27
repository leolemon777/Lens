import AppKit
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class PointerEventRecorderHealthTests: XCTestCase {
    func testDeniedInputMonitoringUsesEmbeddedCursorFallback() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            inputMonitoringPreflight: { false }
        )

        try recorder.start(session: fixture.session, captureBounds: fixture.bounds)

        XCTAssertTrue(recorder.requiresEmbeddedCursorFallback)
        XCTAssertEqual(
            recorder.eventCaptureSnapshot.health,
            .degraded(.inputMonitoringDenied)
        )
        await recorder.stop()
    }

    func testMissingMonitorIsReportedInsteadOfFailingSilently() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in nil },
            removeMonitorOverride: { _ in },
            inputMonitoringPreflight: { true }
        )

        try recorder.start(session: fixture.session, captureBounds: fixture.bounds)

        XCTAssertTrue(recorder.requiresEmbeddedCursorFallback)
        XCTAssertEqual(
            recorder.eventCaptureSnapshot.health,
            .degraded(.monitorUnavailable)
        )
        await recorder.stop()
    }

    func testPhysicalPointerMovementWithoutDeliveredEventsBecomesDegraded() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var mouseLocation = CGPoint(x: 10, y: 10)
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            inputMonitoringPreflight: { true },
            mouseLocationProvider: { mouseLocation }
        )
        try recorder.start(session: fixture.session, captureBounds: fixture.bounds)
        XCTAssertEqual(recorder.eventCaptureSnapshot.health, .waitingForActivity)

        mouseLocation = CGPoint(x: 24, y: 10)

        XCTAssertEqual(
            recorder.eventCaptureSnapshot.health,
            .degraded(.eventsNotDelivered)
        )
        await recorder.stop()
    }

    func testDeliveredPointerEventTransitionsHealthToHealthy() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            inputMonitoringPreflight: { true }
        )
        try recorder.start(session: fixture.session, captureBounds: fixture.bounds)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))

        recorder.handle(event)

        XCTAssertEqual(
            recorder.eventCaptureSnapshot.health,
            .healthy(pointerCount: 1, clickCount: 0)
        )
        await recorder.stop()
        XCTAssertEqual(
            recorder.eventCaptureSnapshot.health,
            .healthy(pointerCount: 1, clickCount: 0)
        )
    }

    func testRecorderPersistsPrivacySafeSystemCursorShape() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            inputMonitoringPreflight: { true },
            cursorShapeProvider: { .pointingHand }
        )
        try recorder.start(session: fixture.session, captureBounds: fixture.bounds)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 240, y: 180),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0
        ))

        recorder.handle(event)
        await recorder.stop()

        let events = try LensEventReader.read(
            PointerEvent.self,
            from: fixture.session.pointerEventsURL
        )
        XCTAssertEqual(events.first?.cursorShape, .pointingHand)
    }

    func testSystemCursorMatcherRecognizesStandardActualShapes() {
        _ = NSApplication.shared
        XCTAssertEqual(SystemCursorShapeMatcher.shape(for: NSCursor.arrow), .arrow)
        XCTAssertEqual(
            SystemCursorShapeMatcher.shape(for: NSCursor.pointingHand),
            .pointingHand
        )
        XCTAssertEqual(SystemCursorShapeMatcher.shape(for: NSCursor.iBeam), .iBeam)
        XCTAssertEqual(SystemCursorShapeMatcher.shape(for: NSCursor.openHand), .openHand)
        XCTAssertEqual(SystemCursorShapeMatcher.shape(for: NSCursor.closedHand), .closedHand)
        XCTAssertNil(SystemCursorShapeMatcher.shape(for: nil))
    }

    private func makeSession() throws -> (
        root: URL,
        session: RecordingLensSession,
        bounds: CGRect
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensEventHealth-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1280, height: 720)
        return (
            root,
            session,
            CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
    }
}
