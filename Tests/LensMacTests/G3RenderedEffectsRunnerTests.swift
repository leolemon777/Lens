import Foundation
import LensCore
import XCTest
@testable import LensMac

final class G3RenderedEffectsRunnerTests: XCTestCase {
    func testConfigurationResolvesProjectReportOutputAndPreset() throws {
        let root = URL(fileURLWithPath: "/tmp/Lens G3", isDirectory: true)
        let configuration = try XCTUnwrap(G3RenderedEffectsConfiguration(
            arguments: [
                "Lens",
                "--g3-rendered-effects",
                "--project", "Input.lens",
                "--report", "Reports/source.json",
                "--output", "Outputs/source.mp4",
                "--preset", "source",
                "--enable-captions",
                "--caption-text", "字幕必须进入最终成片",
                "--add-video-annotation",
                "--persist-derived-copy",
                "--require-effects", "captions,cursor,captions,videoAnnotation"
            ],
            workingDirectory: root
        ))

        XCTAssertEqual(
            configuration.projectURL.path,
            "/tmp/Lens G3/Input.lens"
        )
        XCTAssertEqual(
            configuration.reportURL.path,
            "/tmp/Lens G3/Reports/source.json"
        )
        XCTAssertEqual(
            configuration.outputURL?.path,
            "/tmp/Lens G3/Outputs/source.mp4"
        )
        XCTAssertEqual(configuration.preset, .source)
        XCTAssertTrue(configuration.enablesCaptions)
        XCTAssertEqual(configuration.diagnosticCaptionText, "字幕必须进入最终成片")
        XCTAssertTrue(configuration.addsVideoAnnotation)
        XCTAssertTrue(configuration.persistsDerivedCopy)
        XCTAssertEqual(
            configuration.requiredEffects.map(\.rawValue),
            ["captions", "cursor", "videoAnnotation"]
        )
    }

    func testTranscriptionConfigurationResolvesControlledEvidenceInputs() throws {
        let root = URL(fileURLWithPath: "/tmp/Lens Speech", isDirectory: true)
        let configuration = try XCTUnwrap(G3TranscriptionConfiguration(
            arguments: [
                "Lens", "--g3-transcription",
                "--audio", "speech.aiff",
                "--report", "report.json",
                "--locale", "zh-CN",
                "--expected-terms", "屏幕,录制,字幕",
                "--verify-organization"
            ],
            workingDirectory: root
        ))

        XCTAssertEqual(configuration.audioURL.path, "/tmp/Lens Speech/speech.aiff")
        XCTAssertEqual(configuration.reportURL.path, "/tmp/Lens Speech/report.json")
        XCTAssertEqual(configuration.localeIdentifier, "zh-CN")
        XCTAssertEqual(configuration.expectedTerms, ["屏幕", "录制", "字幕"])
        XCTAssertTrue(configuration.verifiesOrganization)
    }

    func testTranscriptionAcceptanceRequiresOnDeviceTextTimingAndTerms() {
        let document = TranscriptDocument(
            engine: "apple-speech",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [TranscriptSegment(
                startSeconds: 0.2,
                endSeconds: 1.4,
                text: "屏幕录制字幕",
                confidence: 0.9
            )]
        )
        XCTAssertTrue(G3TranscriptionAcceptance(
            audioDurationSeconds: 2,
            audioRootMeanSquare: 0.1,
            document: document,
            matchedExpectedTermCount: 3,
            expectedTermCount: 3,
            organizationRequired: true,
            organizationVerified: true
        ).passed)
        XCTAssertFalse(G3TranscriptionAcceptance(
            audioDurationSeconds: 2,
            audioRootMeanSquare: 0.1,
            document: document,
            matchedExpectedTermCount: 2,
            expectedTermCount: 3,
            organizationRequired: true,
            organizationVerified: true
        ).passed)
        XCTAssertFalse(G3TranscriptionAcceptance(
            audioDurationSeconds: 2,
            audioRootMeanSquare: 0.1,
            document: document,
            matchedExpectedTermCount: 3,
            expectedTermCount: 3,
            organizationRequired: true,
            organizationVerified: false
        ).passed)
    }

    func testConfigurationRejectsUnknownPreset() {
        XCTAssertNil(G3RenderedEffectsConfiguration(arguments: [
            "Lens",
            "--g3-rendered-effects",
            "--project", "/tmp/Input.lens",
            "--report", "/tmp/report.json",
            "--preset", "marketing"
        ]))
    }

    func testAcceptanceRequiresRealRequestedEffectAndComfortableMotion() {
        let verified = RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 3,
            rawMeasuredFramesPerSecond: 60,
            previewMeasuredFramesPerSecond: 60,
            minimumExpectedFramesPerSecond: 58,
            effects: [
                RenderedEffectVerification(
                    effect: .cursor,
                    state: .verified,
                    changedPixelCount: 120,
                    expectedDifference: 0.2,
                    similarityGain: 0.8
                )
            ]
        )
        let comfortable = CameraMotionComfortReport(
            maximumPanVelocity: 0.5,
            maximumZoomVelocity: 1,
            maximumCombinedMotionRatio: 1,
            rapidDirectionReversalCount: 0,
            compressedReturnCount: 0,
            analyzedTransitionCount: 1,
            issues: []
        )

        XCTAssertTrue(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 1,
            requiredEffects: [.cursor],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: false,
            persistenceVerified: true,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: true
        ).passed)
        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 0,
            requiredEffects: [],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: false,
            persistenceVerified: true,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: true
        ).passed)
        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: false,
            requestedEffectCount: 1,
            requiredEffects: [],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: false,
            persistenceVerified: true,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: true
        ).passed)
        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 1,
            requiredEffects: [.captions],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: false,
            persistenceVerified: true,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: true
        ).passed)

        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 1,
            requiredEffects: [.cursor],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: true,
            persistenceVerified: false,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: true
        ).passed)
        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 1,
            requiredEffects: [.cursor],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: true,
            persistenceVerified: true,
            sourceProjectUnchanged: false,
            exportFreshnessVerified: true
        ).passed)
        XCTAssertFalse(G3RenderedEffectsAcceptance(
            outputExists: true,
            requestedEffectCount: 1,
            requiredEffects: [.cursor],
            verification: verified,
            motionComfort: comfortable,
            persistenceRequested: false,
            persistenceVerified: true,
            sourceProjectUnchanged: true,
            exportFreshnessVerified: false
        ).passed)
    }
}
