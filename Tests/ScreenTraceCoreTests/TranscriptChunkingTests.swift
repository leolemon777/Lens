import Foundation
import XCTest
@testable import ScreenTraceCore

final class TranscriptChunkingTests: XCTestCase {
    func testPlannerBuildsOverlappedChunksWithSingleOwnershipBoundaries() {
        let chunks = TranscriptChunkPlanner.plan(
            durationSeconds: 125,
            maximumChunkDurationSeconds: 50,
            overlapSeconds: 1
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].sourceStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chunks[0].sourceEndSeconds, 50, accuracy: 0.001)
        XCTAssertEqual(chunks[0].acceptedEndSeconds, 49.5, accuracy: 0.001)
        XCTAssertEqual(chunks[1].sourceStartSeconds, 49, accuracy: 0.001)
        XCTAssertEqual(chunks[1].acceptedStartSeconds, 49.5, accuracy: 0.001)
        XCTAssertEqual(chunks[1].acceptedEndSeconds, 98.5, accuracy: 0.001)
        XCTAssertEqual(chunks[2].sourceStartSeconds, 98, accuracy: 0.001)
        XCTAssertEqual(chunks[2].sourceEndSeconds, 125, accuracy: 0.001)
        XCTAssertEqual(chunks[2].acceptedStartSeconds, 98.5, accuracy: 0.001)
    }

    func testMergerOffsetsTimesAndRemovesWordsDuplicatedInsideOverlap() {
        let chunks = TranscriptChunkPlanner.plan(
            durationSeconds: 80,
            maximumChunkDurationSeconds: 50,
            overlapSeconds: 1
        )
        let first = document(segments: [
            TranscriptSegment(startSeconds: 48.8, endSeconds: 49.2, text: "keep", confidence: 0.9),
            TranscriptSegment(startSeconds: 49.6, endSeconds: 49.9, text: "duplicate", confidence: 0.8)
        ])
        let second = document(segments: [
            TranscriptSegment(startSeconds: 0.1, endSeconds: 0.4, text: "duplicate", confidence: 0.8),
            TranscriptSegment(startSeconds: 0.7, endSeconds: 1.0, text: "next", confidence: 0.95)
        ])

        let merged = TranscriptChunkMerger.merge(
            [
                TranscriptChunkDocument(chunk: chunks[0], document: first),
                TranscriptChunkDocument(chunk: chunks[1], document: second)
            ],
            engine: "test-local",
            generatedAt: Date(timeIntervalSince1970: 10),
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .microphone
        )

        XCTAssertEqual(merged.segments.map(\.text), ["keep", "next"])
        XCTAssertEqual(merged.segments[0].startSeconds, 48.8, accuracy: 0.001)
        XCTAssertEqual(merged.segments[1].startSeconds, 49.7, accuracy: 0.001)
        XCTAssertEqual(merged.fullText, "keep next")
    }

    /// A one-second overlap left only half a second of margin on each side of an
    /// ownership boundary, so an ordinary two-second utterance straddling a cut
    /// was awarded to the chunk that had only heard its tail. The default must
    /// give both neighbours enough context to hear such an utterance in full.
    func testDefaultOverlapCoversAnOrdinaryUtteranceStraddlingABoundary() {
        let chunks = TranscriptChunkPlanner.plan(durationSeconds: 200)

        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        let first = chunks[0]
        let second = chunks[1]
        let overlap = first.sourceEndSeconds - second.sourceStartSeconds
        XCTAssertGreaterThanOrEqual(
            overlap, 4,
            "默认重叠不足以覆盖常见的 2–4 秒中文语音片段"
        )

        // Ownership must stay contiguous: no gap and no double counting.
        XCTAssertEqual(
            first.acceptedEndSeconds,
            second.acceptedStartSeconds,
            accuracy: 0.001
        )

        // An utterance centred just past the boundary must sit entirely inside
        // the chunk that owns it, not start before that chunk's audio begins.
        let boundary = first.acceptedEndSeconds
        let utteranceStart = boundary - 1.0
        XCTAssertGreaterThanOrEqual(utteranceStart, second.sourceStartSeconds)
    }

    /// An utterance longer than the overlap can still straddle a boundary. When
    /// the midpoint awards it to a chunk that only caught its tail, the merger
    /// must fall back to the neighbour that heard the whole thing.
    func testTruncatedWinnerIsReplacedByTheChunkThatHeardTheWholeUtterance() {
        let chunks = TranscriptChunkPlanner.plan(
            durationSeconds: 100,
            maximumChunkDurationSeconds: 50,
            overlapSeconds: 4
        )
        XCTAssertGreaterThanOrEqual(chunks.count, 2)

        // Chunk 0 covers [0, 50]. These times put the midpoint just past the
        // ownership cut so the full hearing is a neighbour, not the winner.
        let firstDocument = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            fullText: "完整的一句话",
            segments: [TranscriptSegment(
                startSeconds: 46.2,
                endSeconds: 49.9,
                text: "完整的一句话",
                confidence: 0.9
            )]
        )
        // Chunk 1 starts at 46 and only catches the tail from t=0, so the
        // midpoint lands in its accepted range and the slice looks truncated.
        let secondDocument = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            fullText: "句话",
            segments: [TranscriptSegment(
                startSeconds: 0,
                endSeconds: 4.2,
                text: "句话",
                confidence: 0.4
            )]
        )

        let merged = TranscriptChunkMerger.merge(
            [
                TranscriptChunkDocument(chunk: chunks[0], document: firstDocument),
                TranscriptChunkDocument(chunk: chunks[1], document: secondDocument)
            ],
            engine: "test",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone
        )

        XCTAssertTrue(
            merged.segments.contains { $0.text == "完整的一句话" },
            "被截断的版本胜出了，应该采用完整听到的那一份"
        )
        XCTAssertFalse(merged.segments.contains { $0.text == "句话" })
    }

    private func document(segments: [TranscriptSegment]) -> TranscriptDocument {
        TranscriptDocument(
            engine: "test-local",
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: segments
        )
    }
}
