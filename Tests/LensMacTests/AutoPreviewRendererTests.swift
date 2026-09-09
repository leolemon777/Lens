import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

/// Collects progress callbacks that may arrive off the calling task (the
/// export-progress poller runs in its own `Task`); a lock-guarded array is
/// simpler than an actor here since the callback itself is synchronous.
final class ProgressCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var recorded: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class AutoPreviewRendererTests: XCTestCase {
    @MainActor
    func testRenderProgressIsMonotonicStartsNearZeroAndEndsAtOne() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await SyntheticVideoFactory.makeVideo(at: inputURL, frameCount: 36, framesPerSecond: 24)
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = false

        let collector = ProgressCollectorBox()
        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan,
            progress: { collector.append($0) }
        )
        XCTAssertEqual(renderer.lastRenderMetrics.encodePassCount, 1)
        XCTAssertGreaterThan(renderer.lastRenderMetrics.elapsedMilliseconds, 0)
        XCTAssertGreaterThan(renderer.lastRenderMetrics.peakPhysicalFootprintBytes, 0)

        let values = collector.recorded
        XCTAssertFalse(values.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values.first), 0)
        XCTAssertEqual(try XCTUnwrap(values.last), 1)
        XCTAssertEqual(values, values.sorted(), "progress must never move backwards")
        // The exporter is polled at 10 Hz; a sub-second synthetic render
        // should never produce anywhere near a per-frame callback count.
        XCTAssertLessThan(values.count, 300)
    }

    @MainActor
    func testPresenterCameraRenderProgressSpansBothEncodePassesWithoutRestarting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensPresenterProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("presenter.mp4")
        try await SyntheticVideoFactory.makeVideo(at: screenURL, frameCount: 24, framesPerSecond: 24)
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 24,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true

        let collector = ProgressCollectorBox()
        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan,
            progress: { collector.append($0) }
        )
        XCTAssertEqual(renderer.lastRenderMetrics.encodePassCount, 2)
        XCTAssertGreaterThan(renderer.lastRenderMetrics.peakPhysicalFootprintBytes, 0)

        let values = collector.recorded
        XCTAssertFalse(values.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values.first), 0)
        XCTAssertEqual(try XCTUnwrap(values.last), 1)
        XCTAssertEqual(values, values.sorted(), "progress must never move backwards")
    }

    func testCameraMotionBlurIsVelocityDrivenAndZeroIsExactBypass() throws {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 180)
        let checker = try XCTUnwrap(CIFilter(
            name: "CICheckerboardGenerator",
            parameters: [
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
                "inputWidth": 3.0,
                "inputSharpness": 1.0
            ]
        )?.outputImage).cropped(to: extent)
        let keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: LensPoint(x: 0.3, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 1.5,
                center: LensPoint(x: 0.7, y: 0.5),
                easing: "linear",
                reason: .clickFocus
            )
        ]
        var moving = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            zoomScale: 1.5,
            motionBlurStrength: 1,
            keyframes: keyframes
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        let base = try XCTUnwrap(context.createCGImage(checker, from: extent))
        let blurred = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0.5,
                camera: moving,
                extent: extent
            ),
            from: extent
        ))

        let movingPixelCount = changedPixelCount(between: base, and: blurred)
        XCTAssertGreaterThan(movingPixelCount, 5_000)
        XCTAssertLessThan(movingPixelCount, 12_000)

        let endpoint = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0,
                camera: moving,
                extent: extent
            ),
            from: extent
        ))
        XCTAssertEqual(changedPixelCount(between: base, and: endpoint), 0)

        let outsideTemporalBudget = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0.15,
                camera: moving,
                extent: extent
            ),
            from: extent
        ))
        XCTAssertEqual(
            changedPixelCount(between: base, and: outsideTemporalBudget),
            0,
            "Long transitions should stay sharp outside the short center blur window"
        )

        var pointerCorrection = moving
        pointerCorrection.keyframes = keyframes.map { keyframe in
            AutoEditPlan.CameraKeyframe(
                time: keyframe.time,
                scale: keyframe.scale,
                center: keyframe.center,
                easing: keyframe.easing,
                reason: keyframe.time == 0 ? .baseline : .pointerFollow
            )
        }
        let pointerBlur = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0.5,
                camera: pointerCorrection,
                extent: extent
            ),
            from: extent
        ))
        let pointerChangedPixelCount = changedPixelCount(between: base, and: pointerBlur)
        XCTAssertLessThan(pointerChangedPixelCount, movingPixelCount)

        moving.motionBlurStrength = 0
        let disabled = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0.5,
                camera: moving,
                extent: extent
            ),
            from: extent
        ))
        XCTAssertEqual(changedPixelCount(between: base, and: disabled), 0)

        moving.motionBlurStrength = 1
        moving.keyframes = keyframes.map {
            AutoEditPlan.CameraKeyframe(
                time: $0.time,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: $0.reason
            )
        }
        let staticFrame = try XCTUnwrap(context.createCGImage(
            AutoPreviewRenderer.applyCameraMotionBlur(
                to: checker,
                at: 0.5,
                camera: moving,
                extent: extent
            ),
            from: extent
        ))
        XCTAssertEqual(changedPixelCount(between: base, and: staticFrame), 0)
    }

    func testClickFeedbackIsVisibleDuringPulseAndStrictlyBypassesWhenDisabled() throws {
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let background = CIImage(color: CIColor(red: 0.08, green: 0.09, blue: 0.10))
            .cropped(to: extent)
        let ring = CIImage(color: CIColor.white).cropped(to: CGRect(
            x: 0,
            y: 0,
            width: 72,
            height: 72
        ))
        let pulse = AutoEditPlan.ClickPulse(
            time: 0,
            position: LensPoint(x: 0.5, y: 0.5),
            button: .left,
            duration: 0.64
        )
        let enabled = AutoEditPlan.Interaction(
            showsClickPulse: true,
            clickPulseScale: 1.25,
            clickPulseColorHex: "#FF684D",
            clickPulseDuration: 0.64,
            clickPulses: [pulse]
        )
        let disabled = AutoEditPlan.Interaction(
            showsClickPulse: false,
            clickPulses: [pulse]
        )
        let active = AutoPreviewRenderer.applyClickFeedback(
            to: background,
            at: 0.24,
            interaction: enabled,
            viewport: extent,
            cameraScale: 1,
            extent: extent,
            clickRingImage: ring
        )
        let ended = AutoPreviewRenderer.applyClickFeedback(
            to: background,
            at: 1,
            interaction: enabled,
            viewport: extent,
            cameraScale: 1,
            extent: extent,
            clickRingImage: ring
        )
        let bypassed = AutoPreviewRenderer.applyClickFeedback(
            to: background,
            at: 0.24,
            interaction: disabled,
            viewport: extent,
            cameraScale: 1,
            extent: extent,
            clickRingImage: ring
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        let base = try XCTUnwrap(context.createCGImage(background, from: extent))
        let activeFrame = try XCTUnwrap(context.createCGImage(active, from: extent))
        let endedFrame = try XCTUnwrap(context.createCGImage(ended, from: extent))
        let bypassedFrame = try XCTUnwrap(context.createCGImage(bypassed, from: extent))

        XCTAssertGreaterThan(changedPixelCount(between: base, and: activeFrame), 120)
        XCTAssertEqual(changedPixelCount(between: base, and: endedFrame), 0)
        XCTAssertEqual(changedPixelCount(between: base, and: bypassedFrame), 0)

        var styledFrames: [AutoEditPlan.Interaction.ClickEffect: CGImage] = [:]
        for effect in AutoEditPlan.Interaction.ClickEffect.allCases {
            let styled = AutoEditPlan.Interaction(
                showsClickPulse: true,
                clickEffect: effect,
                clickEffectStrength: 0.9,
                clickPulseScale: 1.25,
                clickPulseColorHex: "#FF684D",
                clickPulseDuration: 0.64,
                clickPulses: [pulse]
            )
            let image = try XCTUnwrap(context.createCGImage(
                AutoPreviewRenderer.applyClickFeedback(
                    to: background,
                    at: 0.24,
                    interaction: styled,
                    viewport: extent,
                    cameraScale: 1,
                    extent: extent,
                    clickRingImage: ring
                ),
                from: extent
            ))
            XCTAssertGreaterThan(changedPixelCount(between: base, and: image), 80)
            styledFrames[effect] = image
        }
        XCTAssertGreaterThan(changedPixelCount(
            between: try XCTUnwrap(styledFrames[.ripple]),
            and: try XCTUnwrap(styledFrames[.pulse])
        ), 20)
        XCTAssertGreaterThan(changedPixelCount(
            between: try XCTUnwrap(styledFrames[.pulse]),
            and: try XCTUnwrap(styledFrames[.spotlight])
        ), 20)
    }

    func testVideoAnnotationRendererScopesBlurAndPixelateToActiveRegions() throws {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 180)
        let checker = try XCTUnwrap(CIFilter(
            name: "CICheckerboardGenerator",
            parameters: [
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
                "inputWidth": 3.0,
                "inputSharpness": 1.0
            ]
        )?.outputImage).cropped(to: extent)
        let renderer = VideoAnnotationRenderer(annotations: [
            VideoAnnotation(
                annotation: ScreenshotAnnotation(
                    kind: .blur,
                    bounds: LensRect(x: 0.08, y: 0.2, width: 0.34, height: 0.6),
                    style: ScreenshotAnnotationStyle(intensity: 0.07)
                ),
                sourceStartSeconds: 0.5,
                sourceEndSeconds: 1.5,
                fadeDurationSeconds: 0
            ),
            VideoAnnotation(
                annotation: ScreenshotAnnotation(
                    kind: .pixelate,
                    bounds: LensRect(x: 0.58, y: 0.2, width: 0.34, height: 0.6),
                    style: ScreenshotAnnotationStyle(intensity: 0.09)
                ),
                sourceStartSeconds: 0.5,
                sourceEndSeconds: 1.5,
                fadeDurationSeconds: 0
            )
        ])
        let context = CIContext(options: [.cacheIntermediates: false])
        let base = try XCTUnwrap(context.createCGImage(checker, from: extent))
        let inactive = try XCTUnwrap(context.createCGImage(
            renderer.apply(to: checker, atSourceTime: 0.2),
            from: extent
        ))
        let active = try XCTUnwrap(context.createCGImage(
            renderer.apply(to: checker, atSourceTime: 1),
            from: extent
        ))

        XCTAssertEqual(changedPixelCount(between: base, and: inactive), 0)
        XCTAssertGreaterThan(changedPixelCount(
            between: base,
            and: active,
            normalizedRect: LensRect(x: 0.1, y: 0.25, width: 0.3, height: 0.5)
        ), 1_000)
        XCTAssertGreaterThan(changedPixelCount(
            between: base,
            and: active,
            normalizedRect: LensRect(x: 0.6, y: 0.25, width: 0.3, height: 0.5)
        ), 1_000)
        XCTAssertLessThan(changedPixelCount(
            between: base,
            and: active,
            normalizedRect: LensRect(x: 0.45, y: 0.02, width: 0.1, height: 0.12)
        ), 5)
    }

    func testCaptionOverlayRendererChangesOnlyActiveFrame() throws {
        let configuration = AutoEditPlan.Captions(
            isEnabled: true,
            style: .highContrast,
            position: .bottom
        )
        let renderer = CaptionOverlayRenderer(
            cues: [CaptionCue(
                startSeconds: 0.5,
                endSeconds: 1.2,
                text: "Caption overlay"
            )],
            configuration: configuration,
            presenter: nil
        )
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let base = CIImage(color: CIColor(red: 0.1, green: 0.55, blue: 0.2))
            .cropped(to: extent)
        let inactive = renderer.apply(to: base, at: 0.2)
        let active = renderer.apply(to: base, at: 0.8)
        let context = CIContext(options: [.cacheIntermediates: false])
        let inactiveImage = try XCTUnwrap(context.createCGImage(inactive, from: extent))
        let activeImage = try XCTUnwrap(context.createCGImage(active, from: extent))

        XCTAssertGreaterThan(changedPixelCount(between: inactiveImage, and: activeImage), 250)
    }

    @MainActor
    func testSyntheticVideoRendersNaturalCameraAndCursorPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await SyntheticVideoFactory.makeVideo(at: inputURL, frameCount: 36, framesPerSecond: 24)

        var plan = AutoEditPlan()
        plan.camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 0.6,
                scale: 1.5,
                center: LensPoint(x: 0.72, y: 0.35),
                easing: "spring-smooth",
                reason: .clickFocus
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1.3,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "spring-gentle",
                reason: .returnToOverview
            )
        ]
        plan.cursor.keyframes = [
            AutoEditPlan.CursorKeyframe(time: 0, position: LensPoint(x: 0.2, y: 0.7)),
            AutoEditPlan.CursorKeyframe(time: 0.8, position: LensPoint(x: 0.72, y: 0.35))
        ]
        plan.interaction?.clickPulses = [
            AutoEditPlan.ClickPulse(
                time: 0.55,
                position: LensPoint(x: 0.72, y: 0.35),
                button: .left
            )
        ]

        let renderedURL = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertEqual(renderedURL, outputURL)
        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        XCTAssertGreaterThan(fileSize?.int64Value ?? 0, 1_000)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.3)
        XCTAssertLessThan(duration, 1.7)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        let renderedFrame = try await imageGenerator.image(at: CMTime(seconds: 0.7, preferredTimescale: 600)).image
        XCTAssertEqual(renderedFrame.width, 640)
        XCTAssertEqual(renderedFrame.height, 360)
        let bitmap = NSBitmapImageRep(cgImage: renderedFrame)
        let cornerColor = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        XCTAssertTrue((0.72...0.92).contains(cornerColor.redComponent), "\(cornerColor)")
        XCTAssertTrue((0.72...0.91).contains(cornerColor.greenComponent), "\(cornerColor)")
        XCTAssertTrue((0.68...0.90).contains(cornerColor.blueComponent), "\(cornerColor)")
    }

    @MainActor
    func testRecordedCursorShapeAndMotionEffectChangeRenderedMedia() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensCursorStyleTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 20,
            framesPerSecond: 24
        )

        var arrowPlan = AutoEditPlan()
        arrowPlan.camera.mode = "off"
        arrowPlan.canvas?.isEnabled = false
        arrowPlan.presenterCamera?.isEnabled = false
        arrowPlan.interaction?.showsClickPulse = false
        arrowPlan.cursor.appearance = .macOS
        arrowPlan.cursor.motionEffect = .none
        arrowPlan.cursor.hidesWhenIdle = false
        arrowPlan.cursor.smoothingWindowMilliseconds = 0
        arrowPlan.cursor.keyframes = [
            AutoEditPlan.CursorKeyframe(
                time: 0,
                position: LensPoint(x: 0.5, y: 0.5)
            )
        ]

        var recordedPlan = arrowPlan
        recordedPlan.cursor.appearance = .recorded
        recordedPlan.cursor.shapeKeyframes = [
            AutoEditPlan.CursorShapeKeyframe(time: 0, shape: .pointingHand)
        ]

        var spotlightPlan = recordedPlan
        spotlightPlan.cursor.motionEffect = .spotlight
        spotlightPlan.cursor.motionEffectStrength = 1
        spotlightPlan.cursor.accentColorHex = "#A3E635"

        let arrowURL = directory.appendingPathComponent("arrow.mp4")
        let recordedURL = directory.appendingPathComponent("recorded.mp4")
        let spotlightURL = directory.appendingPathComponent("spotlight.mp4")
        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: arrowURL,
            plan: arrowPlan
        )
        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: recordedURL,
            plan: recordedPlan
        )
        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: spotlightURL,
            plan: spotlightPlan
        )

        let time = CMTime(seconds: 0.3, preferredTimescale: 600)
        let arrow = try await AVAssetImageGenerator(
            asset: AVURLAsset(url: arrowURL)
        ).image(at: time).image
        let recorded = try await AVAssetImageGenerator(
            asset: AVURLAsset(url: recordedURL)
        ).image(at: time).image
        let spotlight = try await AVAssetImageGenerator(
            asset: AVURLAsset(url: spotlightURL)
        ).image(at: time).image

        XCTAssertGreaterThan(changedPixelCount(between: arrow, and: recorded), 20)
        XCTAssertGreaterThan(changedPixelCount(between: recorded, and: spotlight), 100)
    }

    @MainActor
    func testTimeAwareVectorAnnotationIsBurnedOnlyInsideItsSourceRange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensVideoAnnotationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("annotated.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 42,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false
        plan.videoAnnotations = [
            VideoAnnotation(
                annotation: ScreenshotAnnotation(
                    kind: .rectangle,
                    bounds: LensRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.024, color: .red)
                ),
                sourceStartSeconds: 0.5,
                sourceEndSeconds: 1.2,
                fadeDurationSeconds: 0.08
            )
        ]

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = try await generator.image(
            at: CMTime(seconds: 0.25, preferredTimescale: 600)
        ).image
        let during = try await generator.image(
            at: CMTime(seconds: 0.8, preferredTimescale: 600)
        ).image
        let after = try await generator.image(
            at: CMTime(seconds: 1.45, preferredTimescale: 600)
        ).image

        XCTAssertGreaterThan(redAnnotationPixelCount(in: during), 1_000)
        XCTAssertLessThan(redAnnotationPixelCount(in: before), 25)
        XCTAssertLessThan(redAnnotationPixelCount(in: after), 25)
    }

    @MainActor
    func testNonDestructiveTimelineCutsAndSpeedsRenderedPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensTimelineRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("timeline.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 48,
            framesPerSecond: 24
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = false
        plan.timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0.25,
                    sourceEndSeconds: 0.75
                ),
                VideoEditSegment(
                    sourceStartSeconds: 1,
                    sourceEndSeconds: 1.75,
                    playbackRate: 2
                )
            ]
        )

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let output = AVURLAsset(url: outputURL)
        let duration = try await output.load(.duration).seconds
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(duration, 0.875, accuracy: 0.09)
    }

    @MainActor
    func testOverlappingTimelineTransitionSurvivesScreenEffectsPipeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensTransitionPipelineTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("transitioned.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 48,
            framesPerSecond: 24,
            style: .temporalSplit(splitFrame: 24)
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = false
        plan.canvas?.isEnabled = false
        plan.timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 1,
                    transitionToNext: VideoEditTransition(
                        kind: .crossDissolve,
                        durationSeconds: 0.5
                    )
                ),
                VideoEditSegment(sourceStartSeconds: 1, sourceEndSeconds: 2)
            ]
        )

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(
            at: CMTime(seconds: 0.75, preferredTimescale: 600)
        ).image
        let bitmap = NSBitmapImageRep(cgImage: frame)
        let color = try XCTUnwrap(
            bitmap.colorAt(x: frame.width / 2, y: frame.height / 2)?
                .usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(color.redComponent, 0.24, "\(color)")
        XCTAssertGreaterThan(color.blueComponent, 0.24, "\(color)")
    }

    @MainActor
    func testTranscriptIsBurnedIntoPreviewOnlyDuringCaptionCue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensCaptionRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("captioned.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 42,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = false
        plan.captions = AutoEditPlan.Captions(
            isEnabled: true,
            style: .glass,
            position: .bottom,
            fontScale: 1.1
        )
        let transcript = TranscriptDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: [
                TranscriptSegment(
                    startSeconds: 0.5,
                    endSeconds: 1.2,
                    text: "Glass captions stay synchronized.",
                    confidence: 1
                )
            ]
        )

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan,
            transcript: transcript
        )

        let output = AVURLAsset(url: outputURL)
        let generator = AVAssetImageGenerator(asset: output)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = try await generator.image(
            at: CMTime(seconds: 0.25, preferredTimescale: 600)
        ).image
        let during = try await generator.image(
            at: CMTime(seconds: 0.75, preferredTimescale: 600)
        ).image
        let after = try await generator.image(
            at: CMTime(seconds: 1.45, preferredTimescale: 600)
        ).image
        let captionDifference = changedPixelCount(between: before, and: during)
        let outsideCueDifference = changedPixelCount(between: before, and: after)
        XCTAssertGreaterThan(
            captionDifference,
            outsideCueDifference + 250,
            "caption=\(captionDifference), outside=\(outsideCueDifference)"
        )
    }

    @MainActor
    func testSyntheticPresenterCameraTrackIsCompositedIntoAutomaticPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("presenter.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: screenURL,
            frameCount: 48,
            framesPerSecond: 24
        )
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 48,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.export = .init(preset: .compact)
        plan.presenterCamera = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .circle,
            anchor: .bottomTrailing,
            size: 0.26,
            margin: 0.04,
            isMirrored: true,
            shadowOpacity: 0.35
        )
        plan.timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 1,
                    transitionToNext: VideoEditTransition(
                        kind: .crossDissolve,
                        durationSeconds: 0.5
                    )
                ),
                VideoEditSegment(sourceStartSeconds: 1, sourceEndSeconds: 2)
            ]
        )
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNil(renderer.lastPresenterCameraError)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(
            at: CMTime(seconds: 0.75, preferredTimescale: 600)
        ).image
        let bitmap = NSBitmapImageRep(cgImage: frame)
        var greenPixels = 0
        var strongestGreen: (score: CGFloat, color: NSColor) = (-1, .black)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let score = color.greenComponent - max(color.redComponent, color.blueComponent)
                if color.greenComponent > 0.85, score > 0.55 {
                    greenPixels += 1
                }
                if score > strongestGreen.score {
                    strongestGreen = (score, color)
                }
            }
        }
        XCTAssertGreaterThan(
            greenPixels,
            250,
            "strongest=\(strongestGreen.color), score=\(strongestGreen.score)"
        )
    }

    @MainActor
    func testPresenterSourceTimeKeyframesMoveInExportedVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensPresenterMotionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("moving-presenter.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: screenURL,
            frameCount: 36,
            framesPerSecond: 24
        )
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 36,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .roundedRectangle,
            size: 0.18,
            shadowOpacity: 0,
            automaticallyAvoidsContent: false,
            keyframes: [
                AutoEditPlan.PresenterCameraKeyframe(
                    sourceTimeSeconds: 0,
                    center: LensPoint(x: 0.2, y: 0.2),
                    size: 0.18,
                    easing: "linear"
                ),
                AutoEditPlan.PresenterCameraKeyframe(
                    sourceTimeSeconds: 0.8,
                    center: LensPoint(x: 0.8, y: 0.8),
                    size: 0.18,
                    easing: "linear"
                )
            ]
        )

        _ = try await AutoPreviewRenderer().render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        let asset = AVURLAsset(url: outputURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(
            at: CMTime(seconds: 0.04, preferredTimescale: 600)
        ).image
        let late = try await generator.image(
            at: CMTime(seconds: 1.05, preferredTimescale: 600)
        ).image
        let earlyCenter = try greenCentroid(in: early)
        let lateCenter = try greenCentroid(in: late)

        XCTAssertLessThan(earlyCenter.x, CGFloat(early.width) * 0.4)
        XCTAssertLessThan(earlyCenter.y, CGFloat(early.height) * 0.4)
        XCTAssertGreaterThan(lateCenter.x, CGFloat(late.width) * 0.6)
        XCTAssertGreaterThan(lateCenter.y, CGFloat(late.height) * 0.6)
    }

    @MainActor
    func testPresenterCameraPreviewPreservesScreenAudioTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensPresenterAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoOnlyURL = directory.appendingPathComponent("video-only.mp4")
        let narrationURL = directory.appendingPathComponent("tone.caf")
        let screenURL = directory.appendingPathComponent("screen-with-audio.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("presenter-with-audio.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoOnlyURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try makeTone(at: narrationURL, frameCount: 60_000)
        try await mux(videoURL: videoOnlyURL, audioURL: narrationURL, outputURL: screenURL)
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 30,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNil(renderer.lastPresenterCameraError)
        let output = AVURLAsset(url: outputURL)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.1)
    }

    @MainActor
    func testBrokenCameraTrackFallsBackToScreenPreviewWithoutLosingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensPresenterFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("broken-camera.mov")
        let outputURL = directory.appendingPathComponent("fallback.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: screenURL,
            frameCount: 12,
            framesPerSecond: 24
        )
        try Data([1, 2, 3, 4]).write(to: cameraURL)
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNotNil(renderer.lastPresenterCameraError)
        let output = AVURLAsset(url: outputURL)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber)?.int64Value ?? 0,
            1_000
        )
    }

    @MainActor
    func testSourceExportPreservesSixtyFPSInputThroughSmartEffects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensSourceFrameRateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input-60fps.mp4")
        let outputURL = directory.appendingPathComponent("source-effects.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 60,
            framesPerSecond: 60
        )
        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        XCTAssertGreaterThanOrEqual(nominalFrameRate, 58)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            timestamps.append(sample.presentationTimeStamp.seconds)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(timestamps.count, 58)
        let first = try XCTUnwrap(timestamps.first)
        let last = try XCTUnwrap(timestamps.last)
        XCTAssertGreaterThanOrEqual(
            Double(timestamps.count - 1) / max(last - first, 0.000_001),
            58
        )
    }

    @MainActor
    func testCompactExportCreatesPlayableHEVCAndCapsSixtyFPSInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensCompactExportTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input-60fps.mp4")
        let outputURL = directory.appendingPathComponent("compact.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 120,
            framesPerSecond: 60
        )
        var plan = AutoEditPlan(export: .init(preset: .compact))
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false

        _ = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formatDescriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        XCTAssertLessThanOrEqual(nominalFrameRate, 24.5)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frameCount = 0
        while output.copyNextSampleBuffer() != nil { frameCount += 1 }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(frameCount, 35)
        XCTAssertLessThanOrEqual(frameCount, 55)
    }

    @MainActor
    private func mux(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        let outputVideo = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let outputAudio = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try outputVideo.insertTimeRange(
            CMTimeRange(start: videoRange.start, duration: duration),
            of: videoTrack,
            at: .zero
        )
        outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        try outputAudio.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ))
        try await exporter.export(to: outputURL, as: .mp4)
    }

    private func makeTone(at url: URL, frameCount: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = sin(Float(index) * 0.035) * 0.15
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func changedPixelCount(between first: CGImage, and second: CGImage) -> Int {
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        let secondBitmap = NSBitmapImageRep(cgImage: second)
        var count = 0
        for y in stride(from: 0, to: min(firstBitmap.pixelsHigh, secondBitmap.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: min(firstBitmap.pixelsWide, secondBitmap.pixelsWide), by: 2) {
                guard let firstColor = firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let secondColor = secondBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let difference = abs(firstColor.redComponent - secondColor.redComponent)
                    + abs(firstColor.greenComponent - secondColor.greenComponent)
                    + abs(firstColor.blueComponent - secondColor.blueComponent)
                if difference > 0.18 {
                    count += 1
                }
            }
        }
        return count
    }

    private func changedPixelCount(
        between first: CGImage,
        and second: CGImage,
        normalizedRect: LensRect
    ) -> Int {
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        let secondBitmap = NSBitmapImageRep(cgImage: second)
        let width = min(firstBitmap.pixelsWide, secondBitmap.pixelsWide)
        let height = min(firstBitmap.pixelsHigh, secondBitmap.pixelsHigh)
        let minX = max(Int(normalizedRect.x * Double(width)), 0)
        let maxX = min(Int((normalizedRect.x + normalizedRect.width) * Double(width)), width)
        let minY = max(Int(normalizedRect.y * Double(height)), 0)
        let maxY = min(Int((normalizedRect.y + normalizedRect.height) * Double(height)), height)
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let firstColor = firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let secondColor = secondBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let difference = abs(firstColor.redComponent - secondColor.redComponent)
                    + abs(firstColor.greenComponent - secondColor.greenComponent)
                    + abs(firstColor.blueComponent - secondColor.blueComponent)
                if difference > 0.18 { count += 1 }
            }
        }
        return count
    }

    private func redAnnotationPixelCount(in image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent > 0.72,
                   color.greenComponent < 0.42,
                   color.blueComponent < 0.42 {
                    count += 1
                }
            }
        }
        return count
    }

    private func greenCentroid(in image: CGImage) throws -> CGPoint {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var totalX = 0.0
        var totalY = 0.0
        var count = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.greenComponent > 0.82,
                      color.greenComponent - max(
                          color.redComponent,
                          color.blueComponent
                      ) > 0.48 else { continue }
                totalX += Double(x)
                totalY += Double(y)
                count += 1
            }
        }
        guard count > 40 else {
            throw NSError(
                domain: "LensTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Presenter pixels were not found"]
            )
        }
        return CGPoint(x: totalX / count, y: totalY / count)
    }
}

enum SyntheticVideoStyle {
    case quadrants
    case greenCamera
    case temporalSplit(splitFrame: Int)
}

enum SyntheticVideoFactory {
    static func makeVideo(
        at url: URL,
        frameCount: Int,
        framesPerSecond: Int,
        width: Int = 640,
        height: Int = 360,
        style: SyntheticVideoStyle = .quadrants,
        allowsFrameReordering: Bool? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if let allowsFrameReordering {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAllowFrameReorderingKey: allowsFrameReordering,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "LensTests", code: 1)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "LensTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let pixelBuffer = try makePixelBuffer(
                width: width,
                height: height,
                frame: index,
                style: style
            )
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? NSError(domain: "LensTests", code: 3)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "LensTests", code: 4)
        }
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frame: Int,
        style: SyntheticVideoStyle
    ) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw NSError(domain: "LensTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "LensTests", code: 5)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                switch style {
                case .quadrants:
                    let right = x >= width / 2
                    let bottom = y >= height / 2
                    row[offset] = UInt8(right ? 210 : 55)                       // B
                    row[offset + 1] = UInt8(bottom ? 190 : 70)                 // G
                    row[offset + 2] = UInt8((frame * 5 + (right ? 90 : 220)) % 255) // R
                case .greenCamera:
                    row[offset] = 25
                    row[offset + 1] = 235
                    row[offset + 2] = 20
                case let .temporalSplit(splitFrame):
                    let isFirstColor = frame < splitFrame
                    row[offset] = isFirstColor ? 20 : 235
                    row[offset + 1] = 20
                    row[offset + 2] = isFirstColor ? 235 : 20
                }
                row[offset + 3] = 255
            }
        }
        return buffer
    }

    @MainActor
    func testVerticalAspectRatioReframeRendersRecomposedCanvas() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensAspectReframeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: inputURL,
            frameCount: 30,
            framesPerSecond: 30
        )
        var plan = AutoEditPlan()
        plan.export?.aspectRatio = .vertical9x16

        let renderedURL = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let asset = AVURLAsset(url: renderedURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize.width, 202)
        XCTAssertEqual(naturalSize.height, 360)
    }

    func testDeliverySizeDerivesEvenCanvasPerAspect() {
        let source = CGSize(width: 640, height: 360)
        XCTAssertEqual(
            AutoPreviewRenderer.deliverySize(source: source, aspectRatio: nil),
            source
        )
        XCTAssertEqual(
            AutoPreviewRenderer.deliverySize(source: source, aspectRatio: .vertical9x16),
            CGSize(width: 202, height: 360)
        )
        XCTAssertEqual(
            AutoPreviewRenderer.deliverySize(source: source, aspectRatio: .square1x1),
            CGSize(width: 360, height: 360)
        )
        // A source already in the target aspect stays untouched.
        XCTAssertEqual(
            AutoPreviewRenderer.deliverySize(
                source: CGSize(width: 202, height: 360),
                aspectRatio: .vertical9x16
            ),
            CGSize(width: 202, height: 360)
        )
    }
}
