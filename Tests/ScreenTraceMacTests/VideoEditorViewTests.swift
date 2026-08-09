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
        plan.presenterCamera?.keyframes = [
            AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: 0,
                center: TracePoint(x: 0.78, y: 0.76),
                size: 0.19
            ),
            AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: 10,
                center: TracePoint(x: 0.22, y: 0.24),
                size: 0.23,
                easing: "ease-out"
            )
        ]
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 18,
            hasCameraTrack: true,
            hasMicrophoneTrack: true,
            transcript: TranscriptDocument(
                engine: "test",
                generatedAt: Date(timeIntervalSince1970: 0),
                localeIdentifier: "zh-Hans",
                isOnDevice: true,
                sourceRole: .microphone,
                segments: [
                    TranscriptSegment(
                        startSeconds: 0.5,
                        endSeconds: 1.4,
                        text: "这是一条可编辑的本机字幕。",
                        confidence: 1
                    )
                ]
            )
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
        if let snapshotPath = ProcessInfo.processInfo.environment[
            "SCREENTRACE_VIDEO_EDITOR_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_260)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 780)
        XCTAssertGreaterThan(png?.count ?? 0, 35_000)
    }
}
