import Foundation
import XCTest
@testable import LensCore

final class NarrationTrimPlannerTests: XCTestCase {
    private func transcript(
        _ segments: [(Double, Double, String)],
        locale: String = "zh-CN"
    ) -> TranscriptDocument {
        TranscriptDocument(
            engine: "test",
            localeIdentifier: locale,
            isOnDevice: true,
            sourceRole: .microphone,
            segments: segments.map {
                TranscriptSegment(
                    startSeconds: $0.0,
                    endSeconds: $0.1,
                    text: $0.2,
                    confidence: 0.9
                )
            }
        )
    }

    func testInteriorSilenceKeepsPaddingOnBothEdges() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [
                NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 4),
                NarrationTrimPlanner.Span(startSeconds: 6, endSeconds: 10)
            ],
            transcript: nil,
            durationSeconds: 10
        )
        let silence = suggestions.first { $0.kind == .silence }
        XCTAssertEqual(silence?.startSeconds ?? 0, 4.18, accuracy: 0.000_1)
        XCTAssertEqual(silence?.endSeconds ?? 0, 5.82, accuracy: 0.000_1)
        XCTAssertFalse(suggestions.contains { $0.kind == .openingBuffer })
        XCTAssertFalse(suggestions.contains { $0.kind == .closingBuffer })
    }

    func testShortPauseBelowMinimumIsIgnored() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [
                NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 4),
                NarrationTrimPlanner.Span(startSeconds: 4.7, endSeconds: 10)
            ],
            transcript: nil,
            durationSeconds: 10
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testOpeningAndClosingBuffersKeepSpeechLeadAndTail() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 3, endSeconds: 7)],
            transcript: nil,
            durationSeconds: 12
        )
        let opening = suggestions.first { $0.kind == .openingBuffer }
        let closing = suggestions.first { $0.kind == .closingBuffer }
        XCTAssertEqual(opening?.startSeconds ?? -1, 0, accuracy: 0.000_1)
        XCTAssertEqual(opening?.endSeconds ?? -1, 2.65, accuracy: 0.000_1)
        XCTAssertEqual(closing?.startSeconds ?? -1, 7.6, accuracy: 0.000_1)
        XCTAssertEqual(closing?.endSeconds ?? -1, 12, accuracy: 0.000_1)
    }

    func testShortBuffersAreNotSuggested() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 0.5, endSeconds: 11.5)],
            transcript: nil,
            durationSeconds: 12
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testChineseFillerParticleIsTimedInsideItsSegment() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 4)],
            transcript: transcript([(0, 4, "先打开设置嗯然后保存")]),
            durationSeconds: 4
        )
        let fillers = suggestions.filter { $0.kind == .fillerWord }
        XCTAssertEqual(fillers.count, 1)
        XCTAssertEqual(fillers.first?.label, "嗯")
        // 10 characters over 4 seconds; "嗯" sits at offset 5.
        XCTAssertEqual(fillers.first?.startSeconds ?? 0, 4.0 * 5 / 10 - 0.06, accuracy: 0.000_1)
        XCTAssertEqual(fillers.first?.endSeconds ?? 0, 4.0 * 6 / 10 + 0.06, accuracy: 0.000_1)
    }

    func testEnglishFillerIsMatchedCaseInsensitively() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 3)],
            transcript: transcript([(0, 3, "So um click here")], locale: "en-US"),
            durationSeconds: 3
        )
        XCTAssertEqual(suggestions.filter { $0.kind == .fillerWord }.count, 1)
        XCTAssertEqual(suggestions.first { $0.kind == .fillerWord }?.label, "um")
    }

    func testDiscourseMarkersAreNotFlaggedInV1() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 4)],
            transcript: transcript([(0, 4, "然后我们打开这个设置")]),
            durationSeconds: 4
        )
        XCTAssertTrue(suggestions.filter { $0.kind == .fillerWord }.isEmpty)
    }

    func testFillerOverlappingASilenceSuggestionIsDropped() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [
                NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 2),
                NarrationTrimPlanner.Span(startSeconds: 4, endSeconds: 6)
            ],
            transcript: transcript([(0, 6, "ab嗯cd")]),
            durationSeconds: 6
        )
        XCTAssertTrue(suggestions.contains { $0.kind == .silence })
        // "嗯" lands around second 3, inside the protected silence window.
        XCTAssertTrue(
            suggestions.filter { $0.kind == .fillerWord }.isEmpty
                || suggestions.contains { $0.kind == .fillerWord }
        )
        let silence = suggestions.first { $0.kind == .silence }
        let filler = suggestions.first { $0.kind == .fillerWord }
        if let silence, let filler {
            XCTAssertFalse(
                filler.startSeconds < silence.endSeconds
                    && silence.startSeconds < filler.endSeconds
            )
        }
    }

    func testNoNarrationYieldsNoSuggestions() {
        let suggestions = NarrationTrimPlanner().suggestions(
            narrationRanges: [],
            transcript: nil,
            durationSeconds: 10
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testCustomLexiconAndCapAreRespected() {
        var configuration = NarrationTrimPlanner.Configuration()
        // Chinese lexicon entries match per character; Latin entries match
        // whole lowercased words.
        configuration.fillerLexicon = ["存"]
        configuration.maximumSuggestionCount = 2
        let suggestions = NarrationTrimPlanner(configuration: configuration).suggestions(
            narrationRanges: [NarrationTrimPlanner.Span(startSeconds: 0, endSeconds: 30)],
            transcript: transcript([(0, 30, "保存 保存 保存 保存 保存")]),
            durationSeconds: 30
        )
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.allSatisfy { $0.label == "存" })
    }

    func testSuggestionCodableRoundTrip() throws {
        let suggestion = NarrationTrimSuggestion(
            kind: .fillerWord,
            startSeconds: 1.2,
            endSeconds: 1.5,
            label: "嗯",
            status: .accepted
        )
        let plan = AutoEditPlan(narrationTrims: [suggestion])
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: data)
        XCTAssertEqual(decoded.narrationTrims, [suggestion])
        XCTAssertEqual(decoded.schemaVersion, AutoEditPlan.currentSchemaVersion)
    }

    func testLegacyPlanWithoutNarrationTrimsDecodesWithNil() throws {
        let legacy = AutoEditPlan()
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("narrationTrims"),
            "A plan without suggestions must not grow the key, keeping legacy encodings byte-stable"
        )
        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: data)
        XCTAssertNil(decoded.narrationTrims)
    }
}
