import CoreGraphics
import XCTest
@testable import ScreenTraceMac

@MainActor
final class RecordingWindowPickerModelTests: XCTestCase {
    func testSameBundleWindowsAreExcludedEvenWhenTheyBelongToAnOlderProcess() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_280, height: 720)

        XCTAssertFalse(ScreenCaptureService.isEligibleWindow(
            isOnScreen: true,
            windowLayer: 0,
            frame: visibleFrame,
            processID: 9_002,
            bundleIdentifier: "app.screentrace.mac",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.screentrace.mac"
        ))
        XCTAssertTrue(ScreenCaptureService.isEligibleWindow(
            isOnScreen: true,
            windowLayer: 0,
            frame: visibleFrame,
            processID: 9_003,
            bundleIdentifier: "com.apple.Safari",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.screentrace.mac"
        ))
    }

    func testWindowOrderKeepsExistingCardsStableAndRanksRegularAppsFirst() {
        let order = RecordingWindowPickerModel.stableWindowOrder(
            previous: [30, 10, 20],
            available: [40, 20, 10, 30],
            priority: [40: 1, 20: 1, 10: 1, 30: 2]
        )

        XCTAssertEqual(order, [10, 20, 40, 30])
    }
}
