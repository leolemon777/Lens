import AppKit
import ScreenTraceCore
import SwiftUI
import XCTest
@testable import ScreenTraceMac

@MainActor
final class VideoEditorViewTests: XCTestCase {
    func testUnifiedEditorRendersPreviewTimelineAndInspectorAtDesktopSize() throws {
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 18,
            hasCameraTrack: true,
            hasMicrophoneTrack: true
        )
        model.split(atOutputTime: 7)
        model.setSelectedPlaybackRate(1.5)
        let playback = VideoEditorPlaybackController()
        let root = VideoEditorView(
            model: model,
            playback: playback,
            title: "Safari 产品演示",
            onSave: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_260, height: 780)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("Unable to create video editor snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_260)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 780)
        XCTAssertGreaterThan(png?.count ?? 0, 35_000)
    }
}
