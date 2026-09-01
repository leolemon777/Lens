import AppKit
import Foundation
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class RecordingCountdownTests: XCTestCase {
    override func tearDown() {
        RecordingCountdownWindowController.stepDurationOverride = nil
        super.tearDown()
    }

    private func makeSource() throws -> RecordingCaptureSource {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        return RecordingCaptureSource(
            mode: .display,
            displayID: screen.displayID,
            captureBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    func testDisabledPreferenceReturnsTrueImmediatelyWithoutDelay() async throws {
        let source = try makeSource()
        let controller = RecordingCountdownWindowController()
        let start = Date()

        let proceeds = await controller.run(source: source, isEnabled: false)

        XCTAssertTrue(proceeds, "a disabled countdown must never block recording from starting")
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.2,
            "disabling the countdown must be zero-delay, not merely a fast countdown"
        )
    }

    func testCountdownCompletesNaturallyAndReturnsTrue() async throws {
        RecordingCountdownWindowController.stepDurationOverride = .milliseconds(5)
        let source = try makeSource()
        let controller = RecordingCountdownWindowController()

        let proceeds = await controller.run(source: source, isEnabled: true)

        XCTAssertTrue(proceeds)
    }

    func testCancelDuringCountdownReturnsFalseAndStopsBeforeAllStepsElapse() async throws {
        RecordingCountdownWindowController.stepDurationOverride = .milliseconds(300)
        let source = try makeSource()
        let controller = RecordingCountdownWindowController()
        let start = Date()

        async let proceeds = controller.run(source: source, isEnabled: true)
        try await Task.sleep(for: .milliseconds(60))
        controller.cancel()
        let result = await proceeds

        XCTAssertFalse(result, "cancel() must prevent the caller from starting a recording")
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.9,
            "cancellation should stop well short of all three real steps (0.9s)"
        )
    }

    func testQuartzConversionFlipsYAroundMainDisplayHeight() {
        // A 1920x1080 main display, AppKit bottom-left origin: this exact
        // frame IS its own Quartz top-left origin (both start at (0, 0)).
        let mainFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            RecordingCountdownWindowController.quartzRect(
                forAppKitFrame: mainFrame,
                mainHeight: mainFrame.height
            ),
            mainFrame
        )

        // A secondary display placed above the main one in AppKit space
        // (y: 1080...1620) must land at negative Quartz Y (above the main
        // display's top edge), matching how a physically-higher monitor is
        // addressed in Quartz's top-left-anchored coordinate space.
        let secondaryFrame = CGRect(x: 0, y: 1080, width: 1600, height: 900)
        let secondaryQuartz = RecordingCountdownWindowController.quartzRect(
            forAppKitFrame: secondaryFrame,
            mainHeight: mainFrame.height
        )
        XCTAssertEqual(secondaryQuartz, CGRect(x: 0, y: -900, width: 1600, height: 900))
    }

    func testLocalBorderRectPlacesTopLeftRegionNearOriginAndBottomRegionNearScreenHeight() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // A region the capture pipeline describes as starting near the
        // Quartz top-left corner (small x/y) must render near the SwiftUI
        // view's own top-left corner (small x/y too) — both conventions
        // share the same handedness, unlike the AppKit frame above.
        let topLeftRegion = CGRect(x: 40, y: 30, width: 400, height: 300)
        let topLeftLocal = RecordingCountdownWindowController.localBorderRect(
            captureBounds: topLeftRegion,
            screenAppKitFrame: screenFrame,
            mainHeight: screenFrame.height
        )
        XCTAssertEqual(topLeftLocal, topLeftRegion)

        // A region near the bottom of the screen in Quartz space (large y,
        // close to the display height) must also land near the bottom of
        // the SwiftUI view (large y, close to the view's own height).
        let bottomRegion = CGRect(x: 100, y: 900, width: 300, height: 150)
        let bottomLocal = RecordingCountdownWindowController.localBorderRect(
            captureBounds: bottomRegion,
            screenAppKitFrame: screenFrame,
            mainHeight: screenFrame.height
        )
        XCTAssertEqual(bottomLocal, bottomRegion)
        XCTAssertGreaterThan(bottomLocal.maxY, screenFrame.height * 0.9)
    }

    func testCancelBeforeStartingHasNoEffectOnANewRun() async throws {
        // Guards against a stale `activeTask` reference from a previous run
        // silently cancelling the next one.
        RecordingCountdownWindowController.stepDurationOverride = .milliseconds(5)
        let source = try makeSource()
        let controller = RecordingCountdownWindowController()
        controller.cancel()

        let proceeds = await controller.run(source: source, isEnabled: true)

        XCTAssertTrue(proceeds)
    }
}
