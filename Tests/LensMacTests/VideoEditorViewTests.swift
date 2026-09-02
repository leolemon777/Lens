import AppKit
import AVKit
import Combine
import LensCore
import SwiftUI
import XCTest
@testable import LensMac

@MainActor
final class VideoEditorViewTests: XCTestCase {
    func testAccessibilityAuditRequiresNamedEditorSliders() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"转场时长\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"光标平滑窗口\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"预览播放位置\")"))
        XCTAssertTrue(source.contains("快速优化"))
        XCTAssertTrue(source.contains("全部设置"))
        XCTAssertTrue(source.contains("预览待更新"))
        XCTAssertTrue(source.contains("未保存"))
        XCTAssertTrue(source.contains("CameraPresentationMapping.aspectFitRect"))
    }

    func testExpensiveInspectorSliderWorkCommitsOnRelease() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains("model.setAutomaticZoomScale($0)"))
        XCTAssertTrue(source.contains("suffix: \"×\",\n                        onEditingEnded: onRegenerateCamera"))
        XCTAssertTrue(source.contains("model.setCameraMotionBlurStrength($0)"))
        XCTAssertTrue(source.contains("range: 0...1,\n                                onEditingEnded: onRefreshPreview"))
        XCTAssertTrue(source.contains("model.beginContinuousEdit()"))
        XCTAssertTrue(source.contains("model.endContinuousEdit()"))
    }

    func testColorChoicesExposeNamesAndSelectionStateToAccessibilityClients() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains("光标特效颜色：\\(option.name)"))
        XCTAssertTrue(source.contains("点击反馈颜色：\\(option.name)"))
        XCTAssertTrue(source.contains("视频标注颜色"))
        XCTAssertTrue(source.contains("accessibilityValue(isSelected ? \"已选择\" : \"未选择\")"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
    }

    func testChoiceButtonsExposeSelectionStateAndSwitchHint() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(source.contains(".accessibilityValue(selected ? \"已选择\" : \"未选择\")"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(source.contains(".accessibilityHint(\"切换到此选项\")"))
    }

    func testTimelineButtonsExplainWhereThePlayheadActionApplies() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(source.contains("timelineButtonHint(for: title)"))
        XCTAssertTrue(source.contains("把当前播放头设为所选片段的开始"))
        XCTAssertTrue(source.contains("在当前播放头位置分割所选片段"))
        XCTAssertTrue(source.contains("从成片中移出所选片段，原始录制仍保留"))
        XCTAssertTrue(source.contains("playback.seek(to: progress * total)"))
        XCTAssertTrue(source.contains("playback.settlePlayhead()"))
        XCTAssertTrue(source.contains("timelineTrimHandle"))
        XCTAssertTrue(source.contains("timelineZoom"))
        XCTAssertTrue(source.contains("timelineWaveform"))
        XCTAssertTrue(source.contains("moveManualCameraFocus"))
        XCTAssertTrue(source.contains("movePresenterKeyframe"))
    }

    func testSocialAspectPreviewMatchesDeliveryChoiceAndShowsSafeAreaGuide() throws {
        let source = try videoEditorUISource()

        XCTAssertTrue(source.contains(".aspectRatio(previewAspectRatio, contentMode: .fit)"))
        XCTAssertTrue(source.contains("VideoEditorSocialSafeAreaOverlay(aspectRatio: aspectRatio)"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"社交画幅安全区\")"))
        XCTAssertTrue(source.contains("字幕和关键内容尽量放在中间虚线框内"))
        XCTAssertTrue(source.contains("case .vertical9x16:"))
        XCTAssertTrue(source.contains("case .square1x1:"))
    }

    func testSocialSafeAreaOverlayRendersAtDeliveryAspect() throws {
        let root = ZStack {
            Color.black
            VideoEditorSocialSafeAreaOverlay(aspectRatio: .vertical9x16)
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["LENS_SAFE_AREA_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertGreaterThan(png.count, 2_000)
    }

    func testPlaybackClockTicksDoNotInvalidateTheWholeEditor() {
        let playback = VideoEditorPlaybackController()
        var editorInvalidations = 0
        let observation = playback.objectWillChange.sink {
            editorInvalidations += 1
        }

        playback.clock.update(0.25)
        playback.clock.update(0.50)
        playback.clock.update(0.75)

        XCTAssertEqual(editorInvalidations, 0)
        playback.settlePlayhead()
        XCTAssertEqual(editorInvalidations, 1)
        withExtendedLifetime(observation) {}
    }

    func testInvalidatingAlreadyRawPreviewDoesNotPublishOrPause() {
        let playback = VideoEditorPlaybackController()
        var invalidations = 0
        let observation = playback.objectWillChange.sink {
            invalidations += 1
        }

        playback.invalidateRenderedPreview()

        XCTAssertEqual(invalidations, 0)
        XCTAssertFalse(playback.isShowingRenderedPreview)
        XCTAssertFalse(playback.isPlaying)
        withExtendedLifetime(observation) {}
    }

    func testCompletedBackgroundPreviewCanWaitWithoutInterruptingRawPlayback() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lens-ready-preview-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data([0]).write(to: temporaryURL)
        let playback = VideoEditorPlaybackController()
        defer { playback.stop() }

        playback.updateRenderedPreview(
            url: temporaryURL,
            timeline: VideoEditTimeline(sourceDurationSeconds: 2),
            switchesImmediately: false
        )

        XCTAssertTrue(playback.canShowRenderedPreview)
        XCTAssertFalse(playback.isShowingRenderedPreview)
        XCTAssertFalse(playback.isLoading)
    }

    func testCanvasBackgroundPresetsAreVariedUniqueAndKeepCoreChoices() throws {
        let presets = VideoEditorCanvasBackgroundPreset.all

        XCTAssertEqual(presets.count, 12)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        XCTAssertEqual(
            Set(presets.map { "\($0.topHex)-\($0.bottomHex)" }).count,
            presets.count
        )
        XCTAssertTrue(presets.contains { $0.title == "雾灰" })
        XCTAssertTrue(presets.contains { $0.title == "蓝紫" })
        XCTAssertTrue(presets.contains { $0.title == "极光" })
        XCTAssertTrue(presets.contains { $0.title == "午夜" })

        let naturalCanvas = try XCTUnwrap(AutoEditPlan().canvas)
        XCTAssertEqual(presets.first { $0.matches(naturalCanvas) }?.title, "雾灰")
    }

    func testCanvasPreviewLayoutMatchesFinalRendererInsetsAndCornerRadius() {
        let size = CGSize(width: 1_000, height: 500)
        let rect = VideoEditorCanvasPreviewLayout.contentRect(in: size, margin: 0.07)

        XCTAssertEqual(rect.minX, 70, accuracy: 0.000_001)
        XCTAssertEqual(rect.minY, 35, accuracy: 0.000_001)
        XCTAssertEqual(rect.width, 860, accuracy: 0.000_001)
        XCTAssertEqual(rect.height, 430, accuracy: 0.000_001)
        XCTAssertEqual(
            VideoEditorCanvasPreviewLayout.cornerRadius(in: size, amount: 0.03),
            15,
            accuracy: 0.000_001
        )
    }

    func testCanvasPreviewLayoutClampsInvalidValuesLikeFinalRenderer() {
        let size = CGSize(width: 800, height: 400)

        XCTAssertEqual(
            VideoEditorCanvasPreviewLayout.contentRect(in: size, margin: 0.5),
            CGRect(x: 200, y: 100, width: 400, height: 200)
        )
        XCTAssertEqual(
            VideoEditorCanvasPreviewLayout.cornerRadius(in: size, amount: .infinity),
            0
        )
    }

    func testLivePreviewCameraTransformMatchesRenderedViewportCenter() {
        var camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true
        )
        camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2,
                center: LensPoint(x: 0.25, y: 0.75),
                easing: "linear",
                reason: .clickFocus
            )
        ]

        let transform = VideoEditorCanvasPreviewLayout.cameraTransform(
            in: CGSize(width: 1_000, height: 500),
            camera: camera,
            sourceTimeSeconds: 1
        )

        XCTAssertEqual(transform.scale, 2, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.width, 500, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.height, -250, accuracy: 0.000_001)
    }

    func testLivePreviewCameraTransformBypassesDisabledMotion() {
        var camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true
        )
        camera.mode = "off"
        camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2.4,
                center: LensPoint(x: 0.25, y: 0.75),
                easing: "linear",
                reason: .clickFocus
            )
        ]

        let transform = VideoEditorCanvasPreviewLayout.cameraTransform(
            in: CGSize(width: 1_000, height: 500),
            camera: camera,
            sourceTimeSeconds: 1
        )

        XCTAssertEqual(transform.scale, 1)
        XCTAssertEqual(transform.offset, CGSize.zero)
    }

    func testLivePreviewCameraTransformClampsViewportToSourceEdgesLikeRenderer() {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            keyframes: [
                AutoEditPlan.CameraKeyframe(
                    time: 0,
                    scale: 2,
                    center: LensPoint(x: 0.05, y: 0.95),
                    easing: "linear",
                    reason: .clickFocus
                )
            ]
        )

        let transform = VideoEditorCanvasPreviewLayout.cameraTransform(
            in: CGSize(width: 1_000, height: 500),
            camera: camera,
            sourceTimeSeconds: 0
        )

        XCTAssertEqual(transform.scale, 2, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.width, 500, accuracy: 0.000_001)
        XCTAssertEqual(transform.offset.height, -250, accuracy: 0.000_001)
    }

    func testRealtimeCameraPlayerFrameMatchesSwiftUIViewportTransform() {
        let transform = VideoEditorCanvasPreviewLayout.CameraTransform(
            scale: 2,
            offset: CGSize(width: 500, height: -250)
        )

        let frame = VideoEditorCanvasPreviewLayout.playerFrame(
            in: CGSize(width: 1_000, height: 500),
            transform: transform
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
    }

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
            onExport: {},
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
                    bounds: LensRect(x: 0.18, y: 0.22, width: 0.48, height: 0.34),
                    start: LensPoint(x: 0.18, y: 0.56),
                    end: LensPoint(x: 0.66, y: 0.22),
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
                center: LensPoint(x: 0.78, y: 0.76),
                size: 0.19
            ),
            AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: 10,
                center: LensPoint(x: 0.22, y: 0.24),
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
            "LENS_VIDEO_EDITOR_INSPECTOR_SNAPSHOT"
        ]
        let root = VideoEditorView(
            model: model,
            playback: playback,
            title: "Safari 产品演示",
            initialInspectorSection: inspectorSnapshotPath == nil ? nil : .captions,
            onSave: {},
            onExport: {},
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
            "LENS_VIDEO_EDITOR_SNAPSHOT"
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

    func testUnifiedEditorRendersDarkHighContrastAppearanceVariant() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 18,
            hasCameraTrack: true,
            hasMicrophoneTrack: true,
            transcript: nil
        )
        let playback = VideoEditorPlaybackController()
        defer { playback.stop() }
        let root = VideoEditorView(
            model: model,
            playback: playback,
            title: "深色高对比度回归",
            onSave: {},
            onExport: {},
            onClose: {}
        )
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_260, height: 780)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_260)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 780)
        XCTAssertGreaterThan(png.count, 35_000)
    }

    func testUnifiedEditorRendersWithReducedTransparencyAndMotion() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 18,
            hasCameraTrack: true,
            hasMicrophoneTrack: true,
            transcript: nil
        )
        let playback = VideoEditorPlaybackController()
        defer { playback.stop() }
        let root = VideoEditorView(
            model: model,
            playback: playback,
            title: "降低透明度与动态效果回归",
            onSave: {},
            onExport: {},
            onClose: {}
        )
        .lensAccessibilityOverrides(reduceTransparency: true, reduceMotion: true)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_260, height: 780)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_260)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 780)
        XCTAssertGreaterThan(png.count, 35_000)
    }

    func testRealtimeRawOverlayRendersCursorClickAndDragState() throws {
        func visiblePixelCount(
            kind: PointerEventKind,
            interaction: AutoEditPlan.Interaction? = nil
        ) throws -> Int {
            let view = VideoEditorCursorOverlayNSView(
                frame: CGRect(x: 0, y: 0, width: 640, height: 360)
            )
            view.configure(
                cursor: AutoEditPlan.Cursor(
                    appearance: .highContrast,
                    motionEffect: .none,
                    smoothing: 0,
                    scale: 1.6,
                    hidesWhenIdle: false,
                    keyframes: [
                        AutoEditPlan.CursorKeyframe(
                            time: 0,
                            position: LensPoint(x: 0.5, y: 0.5),
                            kind: kind
                        )
                    ]
                ),
                interaction: interaction
            )
            view.update(
                sourceTime: 0.2,
                cameraState: CameraFrameState(
                    scale: 1,
                    center: LensPoint(x: 0.5, y: 0.5)
                )
            )
            view.layoutSubtreeIfNeeded()
            let representation = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: view.bounds)
            )
            view.cacheDisplay(in: view.bounds, to: representation)
            var count = 0
            for y in stride(from: 0, to: representation.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: representation.pixelsWide, by: 2) {
                    if (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                        count += 1
                    }
                }
            }
            return count
        }

        let pointerOnly = try visiblePixelCount(kind: .moved)
        let dragging = try visiblePixelCount(kind: .dragged)
        let clicking = try visiblePixelCount(
            kind: .moved,
            interaction: AutoEditPlan.Interaction(
                clickPulses: [
                    AutoEditPlan.ClickPulse(
                        time: 0,
                        position: LensPoint(x: 0.5, y: 0.5),
                        button: .left
                    )
                ]
            )
        )

        XCTAssertGreaterThan(pointerOnly, 20)
        XCTAssertGreaterThan(dragging, pointerOnly)
        XCTAssertGreaterThan(clicking, pointerOnly)
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

private func videoEditorUISource() throws -> String {
    let files = [
        "Sources/LensMac/UI/VideoEditorView.swift",
        "Sources/LensMac/UI/VideoEditorInspectorView.swift",
        "Sources/LensMac/UI/VideoEditorTimelineView.swift",
        "Sources/LensMac/UI/VideoEditorCursorOverlayView.swift"
    ]
    return try files.map { path in
        try String(contentsOf: videoEditorSourceURL(path), encoding: .utf8)
    }.joined(separator: "\n")
}

private func videoEditorSourceURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
}
