import AppKit
import SwiftUI
import XCTest
@testable import ScreenTraceMac

@MainActor
final class ActionCenterViewTests: XCTestCase {
    func testActionRoutingIncludesAllThreeRecordingSources() {
        XCTAssertTrue(ActionCenterAction.allCases.contains(.regionRecording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.windowRecording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.recording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.scrollingCapture))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.multiWindowScreenshot))
    }

    func testCaptureOverlayExplainsScreenshotAndRecordingIntentsSeparately() {
        XCTAssertTrue(CaptureOverlayAction.screenshot.windowGuidance.contains("截取"))
        XCTAssertTrue(CaptureOverlayAction.recording.windowGuidance.contains("开始录制"))
        XCTAssertTrue(CaptureOverlayAction.recording.regionGuidance.contains("录制区域"))
        XCTAssertTrue(CaptureOverlayAction.scrollingCapture.regionGuidance.contains("滚动内容"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("方向键微调"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("Option 暂停吸附"))
    }

    func testActionCenterRendersRecordingAndScreenshotMenusAtPanelSize() throws {
        let root = ActionCenterView(model: AppModel()) { _ in }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 688, height: 430)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create Action Center snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 688)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 430)
        XCTAssertGreaterThan(png?.count ?? 0, 18_000)
    }
}
