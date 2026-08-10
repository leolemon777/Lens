import AppKit
import AVKit
import ScreenTraceCore
import SwiftUI
import XCTest
@testable import ScreenTraceMac

@MainActor
final class VideoEditorViewTests: XCTestCase {
    func testLoadedPlayerUsesNativeAVPlayerViewWithoutSwiftUIVideoPlayerMetadata() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 2,
            hasCameraTrack: false,
            hasMicrophoneTrack: false,
            transcript: nil
        )
        let playback = VideoEditorPlaybackController()
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        let hostingView = NSHostingView(rootView: VideoEditorView(
            model: model,
            playback: playback,
            title: "已加载播放器回归",
            onSave: {},
            onClose: {}
        ))
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_260, height: 780)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        window.orderFront(nil)
        defer {
            playback.stop()
            window.orderOut(nil)
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        hostingView.layoutSubtreeIfNeeded()

        let playerView = try XCTUnwrap(firstSubview(of: AVPlayerView.self, in: hostingView))
        XCTAssertTrue(playerView.player === playback.player)
        XCTAssertEqual(playerView.controlsStyle, .none)
        XCTAssertFalse(playerView.isAccessibilityElement())
        XCTAssertTrue(playerView.isAccessibilityHidden())
    }

    func testUnifiedEditorRendersPreviewTimelineAndInspectorAtDesktopSize() throws {
        var plan = AutoEditPlan()
        let annotationID = UUID()
        plan.videoAnnotations = [
            VideoAnnotation(
                annotation: ScreenshotAnnotation(
                    id: annotationID,
                    kind: .arrow,
                    bounds: TraceRect(x: 0.18, y: 0.22, width: 0.48, height: 0.34),
                    start: TracePoint(x: 0.18, y: 0.56),
                    end: TracePoint(x: 0.66, y: 0.22),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.012, color: .red)
                ),
                sourceStartSeconds: 0,
                sourceEndSeconds: 15,
                fadeDurationSeconds: 0
            )
        ]
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
        if let firstID = model.activeSegments.first?.id {
            model.selectSegment(firstID)
            model.setSelectedTransitionKind(.crossDissolve)
            model.setSelectedTransitionDuration(0.55)
        }
        model.selectVideoAnnotation(annotationID)
        let playback = VideoEditorPlaybackController()
        let inspectorSnapshotPath = ProcessInfo.processInfo.environment[
            "SCREENTRACE_VIDEO_EDITOR_INSPECTOR_SNAPSHOT"
        ]
        let root = VideoEditorView(
            model: model,
            playback: playback,
            title: "Safari 产品演示",
            initialInspectorSection: inspectorSnapshotPath == nil ? nil : .captions,
            onSave: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_260, height: 780)
        let snapshotWindow: NSWindow? = if inspectorSnapshotPath == nil {
            nil
        } else {
            NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        }
        if let snapshotWindow {
            snapshotWindow.contentView = hostingView
            snapshotWindow.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
            snapshotWindow.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }
        defer { snapshotWindow?.orderOut(nil) }
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
        if let inspectorSnapshotPath {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            let inspectorRepresentation = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            )
            hostingView.cacheDisplay(
                in: hostingView.bounds,
                to: inspectorRepresentation
            )
            let inspectorPNG = try XCTUnwrap(inspectorRepresentation.representation(
                using: .png,
                properties: [:]
            ))
            try inspectorPNG.write(
                to: URL(fileURLWithPath: inspectorSnapshotPath),
                options: .atomic
            )
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_260)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 780)
        XCTAssertGreaterThan(png?.count ?? 0, 35_000)
    }

    private func firstSubview<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View {
            return match
        }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
