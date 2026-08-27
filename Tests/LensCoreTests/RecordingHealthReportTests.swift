import Foundation
import XCTest
@testable import LensCore

final class RecordingHealthReportTests: XCTestCase {
    func testRenderedEvidenceReplacesPlanCountsAndRaisesTruthfulWarnings() {
        let report = RecordingHealthReport(
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 59.9,
            p95FrameIntervalMilliseconds: 17,
            droppedFrameCount: 0,
            videoStatus: .healthy,
            eventStatus: .healthy,
            pointerEventCount: 20,
            clickEventCount: 2,
            keyboardEventCount: 0,
            windowEventCount: 0,
            effectiveCameraKeyframeCount: 4,
            cursorKeyframeCount: 20,
            clickPulseCount: 2,
            warnings: []
        )
        XCTAssertEqual(report.completedSmartEffects, ["自动运镜", "平滑光标", "点击反馈"])

        let verification = RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 2,
            rawMeasuredFramesPerSecond: 59.9,
            previewMeasuredFramesPerSecond: 30,
            minimumExpectedFramesPerSecond: 58,
            effects: [
                RenderedEffectVerification(effect: .automaticCamera, state: .verified),
                RenderedEffectVerification(effect: .cursor, state: .failed),
                RenderedEffectVerification(effect: .clickFeedback, state: .inconclusive),
                RenderedEffectVerification(effect: .canvas, state: .notRequested)
            ]
        )
        let updated = report.addingRenderedEffectVerification(
            verification,
            renderedPlanDigest: "sha256:current-plan"
        )

        XCTAssertEqual(updated.schemaVersion, "0.4")
        XCTAssertEqual(updated.renderedPlanDigest, "sha256:current-plan")
        XCTAssertEqual(updated.completedSmartEffects, ["自动运镜"])
        XCTAssertTrue(updated.warnings.contains(.renderedFrameRateBelowExpectation))
        XCTAssertTrue(updated.warnings.contains(.renderedEffectNotVerified))
        XCTAssertFalse(updated.warnings.contains(.renderedPreviewUnavailable))
    }

    func testLegacyHealthReportWithoutPlanDigestStillDecodes() throws {
        let legacy = RecordingHealthReport(
            schemaVersion: "0.3",
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 60,
            p95FrameIntervalMilliseconds: 16.7,
            droppedFrameCount: 0,
            videoStatus: .healthy,
            eventStatus: .healthy,
            pointerEventCount: 1,
            clickEventCount: 1,
            keyboardEventCount: 0,
            windowEventCount: 0,
            effectiveCameraKeyframeCount: 1,
            cursorKeyframeCount: 1,
            clickPulseCount: 1,
            warnings: []
        )

        let decoded = try JSONDecoder().decode(
            RecordingHealthReport.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decoded.schemaVersion, "0.3")
        XCTAssertNil(decoded.renderedPlanDigest)
    }

    func testRawTrackIntegrityDetectsMissingAndDriftedRequestedTracks() {
        let integrity = RecordingTrackIntegrityReport(
            screenVideoDurationSeconds: 3_600,
            systemAudioDurationSeconds: 3_599.96,
            microphoneDurationSeconds: 3_598.8,
            cameraDurationSeconds: nil,
            requestedSystemAudio: true,
            requestedMicrophone: true,
            requestedCamera: true
        )

        XCTAssertEqual(integrity.missingRequestedTracks, [.camera])
        XCTAssertEqual(integrity.outOfSyncTracks, [.microphone])
        XCTAssertEqual(integrity.maximumDurationDriftSeconds ?? 0, 1.2, accuracy: 0.001)
        XCTAssertFalse(integrity.isVerified)

        let aligned = RecordingTrackIntegrityReport(
            screenVideoDurationSeconds: 3_600,
            systemAudioDurationSeconds: 3_599.96,
            microphoneDurationSeconds: 3_600.04,
            cameraDurationSeconds: 3_599.9,
            requestedSystemAudio: true,
            requestedMicrophone: true,
            requestedCamera: true
        )
        XCTAssertTrue(aligned.isVerified)
    }

    func testLegacyFrameRateRemainsAvailableAsEffectiveRequest() throws {
        let metadata = try JSONDecoder().decode(
            LensCaptureMetadata.self,
            from: Data(#"""
            {
                "mode":"display",
                "globalBounds":{"x":0,"y":0,"width":1280,"height":720},
                "framesPerSecond":60
            }
            """#.utf8)
        )

        XCTAssertEqual(metadata.framesPerSecond, 60)
        XCTAssertNil(metadata.requestedFramesPerSecond)
        XCTAssertEqual(metadata.effectiveRequestedFramesPerSecond, 60)
        XCTAssertNil(metadata.measuredFramesPerSecond)
    }

    func testHealthReportPersistsMetricsWithoutOverwritingRequestedFrameRate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingHealthReport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let source = RecordingCaptureSource(
            mode: .display,
            displayID: 1,
            captureBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        let session = try store.beginRecording(
            width: 1280,
            height: 720,
            captureSource: LensCaptureMetadata(
                recordingSource: source,
                framesPerSecond: 60
            )
        )
        try Data([0, 1, 2, 3]).write(to: session.videoURL)
        _ = try store.finalizeRecording(session, durationSeconds: 1)
        let report = RecordingHealthReport(
            generatedAt: Date(timeIntervalSince1970: 10),
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 59.94,
            p95FrameIntervalMilliseconds: 17.1,
            droppedFrameCount: 2,
            videoStatus: .healthy,
            eventStatus: .healthy,
            pointerEventCount: 80,
            clickEventCount: 4,
            keyboardEventCount: 1,
            windowEventCount: 2,
            effectiveCameraKeyframeCount: 8,
            cursorKeyframeCount: 70,
            clickPulseCount: 2,
            cameraMotionComfort: CameraMotionComfortReport(
                maximumPanVelocity: 0.62,
                maximumZoomVelocity: 1.08,
                maximumCombinedMotionRatio: 1.12,
                rapidDirectionReversalCount: 1,
                compressedReturnCount: 0,
                analyzedTransitionCount: 4,
                issues: []
            ),
            warnings: [.droppedVideoFrames]
        )

        let updated = try store.writeRecordingHealthReport(report, to: session.packageURL)
        let reloaded = try store.loadRecordingHealthReport(from: session.packageURL)

        XCTAssertEqual(reloaded, report)
        XCTAssertEqual(updated.manifest.schemaVersion, LensManifest.currentSchemaVersion)
        XCTAssertEqual(updated.manifest.captureSource?.effectiveRequestedFramesPerSecond, 60)
        XCTAssertEqual(updated.manifest.captureSource?.measuredFramesPerSecond, 59.94)
        XCTAssertEqual(updated.manifest.captureSource?.droppedFrameCount, 2)
        XCTAssertTrue(updated.manifest.assets.contains { $0.role == .recordingHealth })
        XCTAssertTrue(reloaded.cameraMotionComfort?.isComfortable == true)
        XCTAssertEqual(report.completedSmartEffects, ["自动运镜", "平滑光标", "点击反馈"])
    }
}
