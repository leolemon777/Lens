import CoreGraphics
import XCTest
@testable import LensMac

@MainActor
final class RecordingWindowPickerModelTests: XCTestCase {
    func testSameBundleWindowsAreExcludedEvenWhenTheyBelongToAnOlderProcess() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_280, height: 720)

        XCTAssertFalse(ScreenCaptureService.isEligibleWindow(
            isOnScreen: true,
            isRegularApplication: true,
            hasWindowTitle: true,
            windowLayer: 0,
            frame: visibleFrame,
            processID: 9_002,
            bundleIdentifier: "app.lens.mac",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.lens.mac"
        ))
        XCTAssertTrue(ScreenCaptureService.isEligibleWindow(
            isOnScreen: true,
            isRegularApplication: true,
            hasWindowTitle: true,
            windowLayer: 0,
            frame: visibleFrame,
            processID: 9_003,
            bundleIdentifier: "com.apple.Safari",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.lens.mac"
        ))
    }

    func testOffscreenTitledRegularAppWindowRemainsSelectable() {
        XCTAssertTrue(ScreenCaptureService.isEligibleWindow(
            isOnScreen: false,
            isRegularApplication: true,
            hasWindowTitle: true,
            windowLayer: 0,
            frame: CGRect(x: 0, y: 117, width: 1_280, height: 715),
            processID: 9_003,
            bundleIdentifier: "com.google.Chrome",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.lens.mac"
        ))
    }

    func testOffscreenUntitledBrowserSubwindowIsExcluded() {
        XCTAssertFalse(ScreenCaptureService.isEligibleWindow(
            isOnScreen: false,
            isRegularApplication: true,
            hasWindowTitle: false,
            windowLayer: 0,
            frame: CGRect(x: 0, y: 117, width: 1_280, height: 47),
            processID: 9_003,
            bundleIdentifier: "com.google.Chrome",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.lens.mac"
        ))
    }

    func testOffscreenAccessoryAppWindowIsExcluded() {
        XCTAssertFalse(ScreenCaptureService.isEligibleWindow(
            isOnScreen: false,
            isRegularApplication: false,
            hasWindowTitle: true,
            windowLayer: 0,
            frame: CGRect(x: 0, y: 117, width: 1_280, height: 715),
            processID: 9_004,
            bundleIdentifier: "com.example.helper",
            excludingProcessID: 9_001,
            excludingBundleIdentifier: "app.lens.mac"
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
