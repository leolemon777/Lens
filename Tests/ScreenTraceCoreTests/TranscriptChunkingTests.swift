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
