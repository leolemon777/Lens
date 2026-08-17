@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class RenderedEffectVerifierTests: XCTestCase {
    func testCursorBaselineRemainsReadableAcrossRetinaCaptureWidths() {
        XCTAssertEqual(
            AutoPreviewRenderer.baseCursorWidth(sourcePixelWidth: 640),
            36,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AutoPreviewRenderer.baseCursorWidth(sourcePixelWidth: 2_560),
            53.76,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AutoPreviewRenderer.baseCursorWidth(sourcePixelWidth: 3_840),
            80.64,
            accuracy: 0.001
        )
    }

    @MainActor
    func testRetinaCursorSurvivesFinalEncodingAndPlaybackDownscale() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedRetinaCursor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw-2560.mp4")
        let previewURL = directory.appendingPathComponent("preview-2560.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 9,
            framesPerSecond: 30,
            width: 2_560,
            height: 1_480
        )

        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.camera.mode = "off"
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.cursor.isEnabled = true
        plan.cursor.hidesWhenIdle = false
        plan.cursor.scale = 1.15
        plan.cursor.keyframes = [
            .init(time: 0.08, position: TracePoint(x: 0.46, y: 0.52))
        ]

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: plan
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: plan
        )
        let cursor = try XCTUnwrap(report.effects.first { $0.effect == .cursor })

        XCTAssertEqual(cursor.state, .verified, "\(cursor)")
        XCTAssertGreaterThanOrEqual(cursor.changedPixelCount, 72)
        XCTAssertGreaterThan(cursor.similarityGain ?? 0, 0.75)
    }

    @MainActor
    func testEncodedPreviewProvesPresenterAndCaptionsReachedFinalMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedPresenterCaptionEvidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let previewURL = directory.appendingPathComponent("preview.mp4")
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
        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.presenterCamera = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.24,
            margin: 0.04,
            isMirrored: true,
            shadowOpacity: 0.3
        )
        plan.captions = AutoEditPlan.Captions(
            isEnabled: true,
            style: .glass,
            position: .bottom,
            fontScale: 1.05
        )
        let transcript = TranscriptDocument(
            engine: "effect-verifier",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: [
                TranscriptSegment(
                    startSeconds: 0.45,
                    endSeconds: 1.45,
                    text: "字幕和摄像头都必须真正进入最终成片",
                    confidence: 1
                )
            ]
        )

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: previewURL,
            plan: plan,
            transcript: transcript
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: screenURL,
            previewURL: previewURL,
            plan: plan,
            cameraURL: cameraURL,
            transcript: transcript
        )

        for effect in [RenderedEffectKind.presenterCamera, .captions] {
            let check = try XCTUnwrap(report.effects.first { $0.effect == effect })
            XCTAssertEqual(check.state, .verified, "\(effect): \(check)")
            XCTAssertGreaterThan(check.changedPixelCount, 72)
            XCTAssertGreaterThan(check.similarityGain ?? 0, 0.12)
            if effect == .captions {
                XCTAssertGreaterThan(check.effectCorrelation ?? 0, 0.18)
                XCTAssertGreaterThan(check.effectProjectionStrength ?? 0, 0.12)
            }
        }
    }

    @MainActor
    func testCompressionRobustCaptionEvidenceRejectsEncodedVideoWithoutCaptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedMissingCaptionEvidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let previewURL = directory.appendingPathComponent("preview-without-captions.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 48,
            framesPerSecond: 24,
            width: 1_920,
            height: 1_080
        )

        var expectedPlan = AutoEditPlan(export: .init(preset: .source))
        expectedPlan.camera.mode = "off"
        expectedPlan.cursor.isEnabled = false
        expectedPlan.interaction?.showsClickPulse = false
        expectedPlan.canvas?.isEnabled = false
        expectedPlan.presenterCamera?.isEnabled = false
        expectedPlan.captions = .init(
            isEnabled: true,
            style: .glass,
            position: .bottom,
            fontScale: 1.12
        )
        let transcript = TranscriptDocument(
            engine: "missing-caption-counterfactual",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: [TranscriptSegment(
                startSeconds: 0.35,
                endSeconds: 1.55,
                text: "故意缺失的字幕绝不能被门禁误判为通过",
                confidence: 1
            )]
        )
        var incorrectlyRenderedPlan = expectedPlan
        incorrectlyRenderedPlan.captions?.isEnabled = false

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: incorrectlyRenderedPlan,
            transcript: transcript
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: expectedPlan,
            transcript: transcript
        )
        let caption = try XCTUnwrap(
            report.effects.first { $0.effect == .captions }
        )

        XCTAssertEqual(caption.state, .failed, "\(caption)")
        // Compression noise can share some direction with a large translucent
        // caption region, but an actually absent caption must retain too little
        // signed effect strength to satisfy the two-dimensional gate.
        XCTAssertLessThan(caption.effectProjectionStrength ?? 1, 0.12)
        XCTAssertFalse(
            (caption.effectCorrelation ?? 0) >= 0.18
                && (caption.effectProjectionStrength ?? 0) >= 0.12
        )
        XCTAssertFalse(report.allRequestedEffectsVerified)
        XCTAssertFalse(report.isVerified)
    }

    @MainActor
    func testEncodedPreviewProvesVideoAnnotationReachedFinalMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedVideoAnnotationEvidence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let previewURL = directory.appendingPathComponent("preview.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 48,
            framesPerSecond: 24
        )
        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false
        plan.videoAnnotations = [VideoAnnotation(
            annotation: ScreenshotAnnotation(
                kind: .rectangle,
                bounds: TraceRect(x: 0.16, y: 0.18, width: 0.68, height: 0.62),
                style: ScreenshotAnnotationStyle(lineWidth: 0.02, color: .orange)
            ),
            sourceStartSeconds: 0.4,
            sourceEndSeconds: 1.6,
            fadeDurationSeconds: 0.08
        )]

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: plan
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: plan
        )
        let annotation = try XCTUnwrap(
            report.effects.first { $0.effect == .videoAnnotation }
        )

        XCTAssertEqual(annotation.state, .verified, "\(annotation)")
        XCTAssertGreaterThan(annotation.changedPixelCount, 72)
        XCTAssertGreaterThan(annotation.similarityGain ?? 0, 0.12)
        XCTAssertTrue(report.isVerified)
    }

    @MainActor
    func testMediaGateDetectsSourcePresetSilentlyRenderedAtCompactFrameRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedEffectVerifierFrameRate-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw-60.mp4")
        let previewURL = directory.appendingPathComponent("preview-24.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 90,
            framesPerSecond: 60
        )

        var expectedPlan = AutoEditPlan(export: .init(preset: .source))
        expectedPlan.camera.mode = "off"
        expectedPlan.cursor.isEnabled = false
        expectedPlan.interaction?.showsClickPulse = false
        expectedPlan.canvas?.isEnabled = false
        expectedPlan.presenterCamera?.isEnabled = false
        var incorrectlyRenderedPlan = expectedPlan
        incorrectlyRenderedPlan.export?.preset = .compact

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: incorrectlyRenderedPlan
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: expectedPlan
        )

        XCTAssertTrue(report.previewPlayable)
        XCTAssertGreaterThan(report.rawMeasuredFramesPerSecond ?? 0, 58)
        XCTAssertLessThan(report.previewMeasuredFramesPerSecond ?? 60, 30)
        XCTAssertFalse(report.isFrameRateVerified)
        XCTAssertFalse(report.isVerified)
    }

    @MainActor
    func testSourcePresetPreservesReordered60FPSAfterEffectComposition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedEffectSource60FPS-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw-60.mp4")
        let previewURL = directory.appendingPathComponent("preview-source.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 120,
            framesPerSecond: 60,
            width: 1_280,
            height: 832,
            allowsFrameReordering: true
        )

        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.camera.mode = "off"
        plan.cursor.isEnabled = false
        plan.interaction?.showsClickPulse = false
        plan.canvas?.isEnabled = false
        plan.presenterCamera?.isEnabled = false
        plan.timeline = VideoEditTimeline(sourceDurationSeconds: 2)

        _ = try await AutoPreviewRenderer().render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: plan
        )
        let rawMetrics = await RecordingArtifactValidator.inspectVideo(at: rawURL)
        let previewMetrics = await RecordingArtifactValidator.inspectVideo(at: previewURL)

        XCTAssertGreaterThan(rawMetrics?.measuredFramesPerSecond ?? 0, 58)
        XCTAssertGreaterThan(
            previewMetrics?.measuredFramesPerSecond ?? 0,
            58,
            "源质量不能在特效合成阶段把 60 FPS 静默降为 30 FPS"
        )
    }

    @MainActor
    func testEncodedPreviewProvesCameraCursorClickAndCanvasIndependently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedEffectVerifier-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let previewURL = directory.appendingPathComponent("preview.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 72,
            framesPerSecond: 30
        )

        var plan = AutoEditPlan(export: .init(preset: .source))
        plan.presenterCamera?.isEnabled = false
        plan.camera.keyframes = [
            .init(
                time: 0,
                scale: 1,
                center: TracePoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            .init(
                time: 0.72,
                scale: 1.6,
                center: TracePoint(x: 0.72, y: 0.35),
                easing: "spring-smooth",
                reason: .clickFocus
            ),
            .init(
                time: 1.7,
                scale: 1.6,
                center: TracePoint(x: 0.72, y: 0.35),
                easing: "linear",
                reason: .clickHold
            )
        ]
        plan.cursor.isEnabled = true
        plan.cursor.hidesWhenIdle = false
        plan.cursor.keyframes = [
            .init(time: 0.2, position: TracePoint(x: 0.2, y: 0.72)),
            .init(time: 0.9, position: TracePoint(x: 0.72, y: 0.35))
        ]
        plan.interaction?.showsClickPulse = true
        plan.interaction?.clickPulses = [
            .init(
                time: 0.86,
                position: TracePoint(x: 0.72, y: 0.35),
                button: .left
            )
        ]
        plan.canvas?.isEnabled = true
        plan.canvas?.margin = 0.08

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: plan
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: plan
        )

        XCTAssertTrue(report.previewPlayable)
        XCTAssertTrue(report.isFrameRateVerified)
        XCTAssertTrue(report.isVerified, "\(report.effects)")
        for effect in [
            RenderedEffectKind.automaticCamera,
            .cursor,
            .clickFeedback,
            .canvas
        ] {
            let check = try XCTUnwrap(report.effects.first { $0.effect == effect })
            XCTAssertEqual(check.state, .verified, "\(effect): \(check)")
            XCTAssertGreaterThan(check.changedPixelCount, 0)
            XCTAssertGreaterThan(check.similarityGain ?? 0, 0.12)
        }
    }

    @MainActor
    func testCounterfactualDetectsCursorMissingFromEncodedMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RenderedEffectVerifierMissingCursor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let previewURL = directory.appendingPathComponent("preview.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 36,
            framesPerSecond: 30
        )

        var expectedPlan = AutoEditPlan(export: .init(preset: .source))
        expectedPlan.camera.mode = "off"
        expectedPlan.canvas?.isEnabled = false
        expectedPlan.presenterCamera?.isEnabled = false
        expectedPlan.interaction?.showsClickPulse = false
        expectedPlan.cursor.isEnabled = true
        expectedPlan.cursor.hidesWhenIdle = false
        expectedPlan.cursor.keyframes = [
            .init(time: 0.35, position: TracePoint(x: 0.44, y: 0.52))
        ]
        var incorrectlyRenderedPlan = expectedPlan
        incorrectlyRenderedPlan.cursor.isEnabled = false

        let renderer = AutoPreviewRenderer()
        _ = try await renderer.render(
            inputURL: rawURL,
            outputURL: previewURL,
            plan: incorrectlyRenderedPlan
        )
        let report = await RenderedEffectVerifier(renderer: renderer).validate(
            rawURL: rawURL,
            previewURL: previewURL,
            plan: expectedPlan
        )
        let cursor = try XCTUnwrap(report.effects.first { $0.effect == .cursor })

        XCTAssertEqual(cursor.state, .failed, "\(cursor)")
        XCTAssertLessThan(cursor.similarityGain ?? 1, 0.12)
        XCTAssertFalse(report.allRequestedEffectsVerified)
        XCTAssertFalse(report.isVerified)
    }
}
