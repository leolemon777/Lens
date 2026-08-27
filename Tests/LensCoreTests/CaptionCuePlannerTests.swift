import Foundation
import XCTest
@testable import LensCore

final class CaptionCuePlannerTests: XCTestCase {
    func testChineseTranscriptGroupsWithoutArtificialSpaces() throws {
        let transcript = document(
            locale: "zh-Hans",
            segments: [
                segment(0, 0.35, "你好"),
                segment(0.35, 0.45, "，"),
                segment(0.45, 0.85, "世界"),
                segment(0.85, 1.0, "！")
            ]
        )
        let configuration = AutoEditPlan.Captions(isEnabled: true)

        let cues = CaptionCuePlanner.cues(
            transcript: transcript,
            configuration: configuration
        )

        XCTAssertEqual(cues, [CaptionCue(
            startSeconds: 0,
            endSeconds: 1,
            text: "你好，世界！"
        )])
        XCTAssertEqual(
            CaptionCuePlanner.activeCue(at: 0.5, in: cues)?.text,
            "你好，世界！"
        )
        XCTAssertNil(CaptionCuePlanner.activeCue(at: 1, in: cues))
    }

    func testCuesFollowReorderedCutAndSpedUpTimeline() throws {
        let transcript = document(
            locale: "en-US",
            segments: [
                segment(1, 1.4, "alpha"),
                segment(2, 2.4, "beta."),
                segment(4, 4.4, "removed"),
                segment(6, 6.4, "gamma"),
                segment(7, 7.4, "delta.")
            ]
        )
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 8,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 6,
                    sourceEndSeconds: 8,
                    playbackRate: 2
                ),
                VideoEditSegment(
                    sourceStartSeconds: 1,
                    sourceEndSeconds: 3
                )
            ]
        )

        let cues = CaptionCuePlanner.cues(
            transcript: transcript,
            configuration: AutoEditPlan.Captions(isEnabled: true),
            timeline: timeline
        )

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "gamma delta.")
        XCTAssertEqual(cues[0].startSeconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(cues[0].endSeconds, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(cues[1].text, "alpha beta.")
        XCTAssertEqual(cues[1].startSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(cues[1].endSeconds, 2.4, accuracy: 0.000_001)
        XCTAssertFalse(cues.contains { $0.text.contains("removed") })
    }

    func testCustomSourceCuesAreNonDestructiveAndEmptyCueIsHidden() throws {
        let transcript = document(
            locale: "en-US",
            segments: [
                segment(0, 0.5, "automatic"),
                segment(0.5, 1, "words")
            ]
        )
        let custom = [
            CaptionSourceCue(sourceStartSeconds: 0, sourceEndSeconds: 0.5, text: "Edited"),
            CaptionSourceCue(sourceStartSeconds: 0.5, sourceEndSeconds: 1, text: "")
        ]
        let configuration = AutoEditPlan.Captions(
            isEnabled: true,
            customCues: custom
        )

        XCTAssertEqual(
            CaptionCuePlanner.sourceCues(
                transcript: transcript,
                configuration: configuration
            ),
            custom
        )
        XCTAssertEqual(
            CaptionCuePlanner.cues(
                transcript: transcript,
                configuration: configuration
            ),
            [CaptionCue(startSeconds: 0, endSeconds: 0.5, text: "Edited")]
        )
        XCTAssertEqual(transcript.fullText, "automatic words")
    }

    func testCaptionAvoidanceLeadsInAndReleasesSmoothly() {
        let cues = [CaptionCue(startSeconds: 1, endSeconds: 2, text: "Hello")]

        XCTAssertEqual(
            CaptionCuePlanner.avoidanceAmount(
                at: 0.7,
                in: cues,
                transitionDuration: 0.2
            ),
            0
        )
        XCTAssertEqual(
            CaptionCuePlanner.avoidanceAmount(
                at: 0.9,
                in: cues,
                transitionDuration: 0.2
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CaptionCuePlanner.avoidanceAmount(
                at: 1.4,
                in: cues,
                transitionDuration: 0.2
            ),
            1
        )
        XCTAssertEqual(
            CaptionCuePlanner.avoidanceAmount(
                at: 2.1,
                in: cues,
                transitionDuration: 0.2
            ),
            0.5,
            accuracy: 0.0001
        )
    }

    private func document(
        locale: String,
        segments: [TranscriptSegment]
    ) -> TranscriptDocument {
        TranscriptDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: locale,
            isOnDevice: true,
            sourceRole: .microphone,
            segments: segments
        )
    }

    private func segment(
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: 1
        )
    }
}
