import XCTest
@testable import LensCore
@testable import LensMac

final class RenderedPreviewExportGateTests: XCTestCase {
    func testExportGateRequiresPersistedMediaEvidence() {
        XCTAssertNotNil(RenderedPreviewExportGate.failureDescription(
            for: nil,
            expectedPlanDigest: "sha256:current"
        ))
        XCTAssertNotNil(RenderedPreviewExportGate.failureDescription(
            for: baseReport(),
            expectedPlanDigest: "sha256:current"
        ))
    }

    func testExportGateAcceptsOnlyPlayableFrameRateAndEffectChecks() {
        let report = baseReport().addingRenderedEffectVerification(
            RenderedEffectVerificationReport(
                previewPlayable: true,
                previewDurationSeconds: 2,
                rawMeasuredFramesPerSecond: 60,
                previewMeasuredFramesPerSecond: 60,
                minimumExpectedFramesPerSecond: 58,
                effects: RenderedEffectKind.allCases.map {
                    RenderedEffectVerification(effect: $0, state: .verified)
                }
            ),
            renderedPlanDigest: "sha256:current"
        )

        XCTAssertNil(RenderedPreviewExportGate.failureDescription(
            for: report,
            expectedPlanDigest: "sha256:current"
        ))
    }

    func testExportGateNamesFailedEffectAndFrameRate() {
        let report = baseReport().addingRenderedEffectVerification(
            RenderedEffectVerificationReport(
                previewPlayable: true,
                previewDurationSeconds: 2,
                rawMeasuredFramesPerSecond: 60,
                previewMeasuredFramesPerSecond: 24,
                minimumExpectedFramesPerSecond: 58,
                effects: [
                    RenderedEffectVerification(effect: .automaticCamera, state: .verified),
                    RenderedEffectVerification(effect: .cursor, state: .failed),
                    RenderedEffectVerification(effect: .clickFeedback, state: .notRequested),
                    RenderedEffectVerification(effect: .canvas, state: .verified)
                ]
            ),
            renderedPlanDigest: "sha256:current"
        )

        let failure = RenderedPreviewExportGate.failureDescription(
            for: report,
            expectedPlanDigest: "sha256:current"
        )
        XCTAssertTrue(failure?.contains("光标") == true)
        XCTAssertTrue(failure?.contains("帧率") == true)
    }

    func testExportGateRejectsVerifiedPreviewFromDifferentPlan() {
        let report = baseReport().addingRenderedEffectVerification(
            RenderedEffectVerificationReport(
                previewPlayable: true,
                previewDurationSeconds: 2,
                rawMeasuredFramesPerSecond: 60,
                previewMeasuredFramesPerSecond: 60,
                minimumExpectedFramesPerSecond: 58,
                effects: RenderedEffectKind.allCases.map {
                    RenderedEffectVerification(effect: $0, state: .verified)
                }
            ),
            renderedPlanDigest: "sha256:old"
        )

        let failure = RenderedPreviewExportGate.failureDescription(
            for: report,
            expectedPlanDigest: "sha256:current"
        )
        XCTAssertTrue(failure?.contains("旧编辑方案") == true)
    }

    func testRenderedPlanDigestIsDeterministicAndChangesWithUIParameters() throws {
        let plan = AutoEditPlan()
        let first = try RenderedPlanIdentity.digest(for: plan, transcript: nil)
        let second = try RenderedPlanIdentity.digest(for: plan, transcript: nil)
        XCTAssertEqual(first, second)

        var changed = plan
        changed.camera.zoomScale = 1.65
        XCTAssertNotEqual(
            first,
            try RenderedPlanIdentity.digest(for: changed, transcript: nil)
        )

        var captioned = plan
        captioned.captions = .init(isEnabled: true)
        let transcript = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [TranscriptSegment(
                startSeconds: 0,
                endSeconds: 1,
                text: "第一版字幕",
                confidence: 1
            )]
        )
        XCTAssertNotEqual(
            try RenderedPlanIdentity.digest(for: captioned, transcript: nil),
            try RenderedPlanIdentity.digest(for: captioned, transcript: transcript)
        )
    }

    func testRenderedPlanDigestChangesWhenSourceAssetChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendered-plan-source-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("screen.mp4")
        try Data("first-source".utf8).write(to: sourceURL)
        let first = try RenderedPlanIdentity.digest(
            for: AutoEditPlan(),
            transcript: nil,
            sourceURL: sourceURL
        )
        try Data("second-source".utf8).write(to: sourceURL, options: .atomic)
        let second = try RenderedPlanIdentity.digest(
            for: AutoEditPlan(),
            transcript: nil,
            sourceURL: sourceURL
        )
        XCTAssertNotEqual(first, second)
    }

    func testAsyncRenderedPlanDigestMatchesSynchronousIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendered-plan-async-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("screen.mp4")
        try Data(repeating: 7, count: 32_768).write(to: sourceURL)

        let synchronous = try RenderedPlanIdentity.digest(
            for: AutoEditPlan(),
            transcript: nil,
            sourceURL: sourceURL
        )
        let asynchronous = try await RenderedPlanIdentity.digestAsync(
            for: AutoEditPlan(),
            transcript: nil,
            sourceURL: sourceURL
        )
        XCTAssertEqual(asynchronous, synchronous)
    }

    private func baseReport() -> RecordingHealthReport {
        RecordingHealthReport(
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 60,
            p95FrameIntervalMilliseconds: 16.7,
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
    }
}
