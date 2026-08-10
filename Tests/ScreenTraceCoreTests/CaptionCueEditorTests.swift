import XCTest
@testable import ScreenTraceCore

final class CaptionCueEditorTests: XCTestCase {
    func testNormalizationClampsRangesAndKeepsHiddenCue() throws {
        let normalized = CaptionCueEditor.normalized([
            CaptionSourceCue(sourceStartSeconds: -2, sourceEndSeconds: 0.01, text: ""),
            CaptionSourceCue(sourceStartSeconds: 4.9, sourceEndSeconds: 8, text: "End")
        ], sourceDurationSeconds: 5)

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].sourceStartSeconds, 0)
        XCTAssertEqual(
            normalized[0].sourceEndSeconds,
            CaptionCueEditor.minimumDurationSeconds
        )
        XCTAssertEqual(normalized[0].text, "")
        XCTAssertEqual(normalized[1].sourceStartSeconds, 4.9)
        XCTAssertEqual(normalized[1].sourceEndSeconds, 5)
    }

    func testRetimeClampsAgainstNeighborsWithoutMovingOppositeEdge() throws {
        let cues = [
            CaptionSourceCue(sourceStartSeconds: 0, sourceEndSeconds: 1, text: "A"),
            CaptionSourceCue(sourceStartSeconds: 1.2, sourceEndSeconds: 2, text: "B"),
            CaptionSourceCue(sourceStartSeconds: 2.3, sourceEndSeconds: 3, text: "C")
        ]
        let movedStart = try XCTUnwrap(CaptionCueEditor.retimed(
            cues,
            at: 1,
            sourceStartSeconds: 0.5,
            sourceDurationSeconds: 4
        ))
        XCTAssertEqual(movedStart[1].sourceStartSeconds, 1)
        XCTAssertEqual(movedStart[1].sourceEndSeconds, 2)

        let movedEnd = try XCTUnwrap(CaptionCueEditor.retimed(
            movedStart,
            at: 1,
            sourceEndSeconds: 3.5,
            sourceDurationSeconds: 4
        ))
        XCTAssertEqual(movedEnd[1].sourceStartSeconds, 1)
        XCTAssertEqual(movedEnd[1].sourceEndSeconds, 2.3)
    }

    func testSplitPrefersNaturalPunctuationNearPlayhead() throws {
        let cues = [CaptionSourceCue(
            sourceStartSeconds: 0,
            sourceEndSeconds: 4,
            text: "先录制，然后自动整理"
        )]

        let split = try XCTUnwrap(CaptionCueEditor.split(
            cues,
            at: 0,
            sourceTimeSeconds: 1.7
        ))

        XCTAssertEqual(split.map(\.text), ["先录制，", "然后自动整理"])
        XCTAssertEqual(split[0].sourceEndSeconds, 1.7)
        XCTAssertEqual(split[1].sourceStartSeconds, 1.7)
    }

    func testMergeUsesLocaleAwareSpacing() throws {
        let cues = [
            CaptionSourceCue(sourceStartSeconds: 0, sourceEndSeconds: 1, text: "Hello"),
            CaptionSourceCue(sourceStartSeconds: 1, sourceEndSeconds: 2, text: "world.")
        ]
        XCTAssertEqual(
            CaptionCueEditor.mergedWithNext(cues, at: 0, localeIdentifier: "en-US")?.first?.text,
            "Hello world."
        )
        XCTAssertEqual(
            CaptionCueEditor.mergedWithNext(cues, at: 0, localeIdentifier: "zh-Hans")?.first?.text,
            "Helloworld."
        )
    }
}
