import Foundation
import XCTest
@testable import LensCore

final class VideoEditTimelineTests: XCTestCase {
    func testSplitTrimRateAndDisableRemainNonDestructiveAndMapOutputTime() throws {
        var timeline = VideoEditTimeline(sourceDurationSeconds: 12)
        let firstID = try XCTUnwrap(timeline.segments.first?.id)
        let secondID = try XCTUnwrap(timeline.split(segmentID: firstID, atSourceTime: 5))
        timeline.trimStart(of: firstID, to: 1)
        timeline.trimEnd(of: secondID, to: 11)
        timeline.setPlaybackRate(2, for: secondID)

        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.segments[0].sourceStartSeconds, 1)
        XCTAssertEqual(timeline.segments[0].sourceEndSeconds, 5)
        XCTAssertEqual(timeline.segments[1].sourceStartSeconds, 5)
        XCTAssertEqual(timeline.segments[1].sourceEndSeconds, 11)
        XCTAssertEqual(timeline.outputDurationSeconds, 7)
        let position = try XCTUnwrap(timeline.position(atOutputTime: 5))
        XCTAssertEqual(position.segmentID, secondID)
        XCTAssertEqual(
            position.sourceTimeSeconds,
            7,
            accuracy: 0.000_001
        )

        timeline.setEnabled(false, for: firstID)
        XCTAssertEqual(timeline.outputDurationSeconds, 3)
        timeline.setEnabled(false, for: secondID)
        XCTAssertTrue(timeline.segments[1].isEnabled, "At least one source segment must remain")
    }

    func testSourceActivityMapsAcrossReorderedAndSpedUpSegments() throws {
        let first = VideoEditSegment(
            sourceStartSeconds: 6,
            sourceEndSeconds: 10,
            playbackRate: 2
        )
        let second = VideoEditSegment(
            sourceStartSeconds: 1,
            sourceEndSeconds: 4
        )
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 12,
            segments: [first, second]
        )

        XCTAssertEqual(timeline.outputDurationSeconds, 5)
        XCTAssertEqual(
            timeline.outputRanges(forSourceRange: VideoEditTimeRange(
                startSeconds: 2,
                endSeconds: 8
            )),
            [
                VideoEditTimeRange(startSeconds: 0, endSeconds: 1),
                VideoEditTimeRange(startSeconds: 3, endSeconds: 5)
            ]
        )

        let decoded = try JSONDecoder().decode(
            VideoEditTimeline.self,
            from: JSONEncoder().encode(timeline)
        )
        XCTAssertEqual(decoded, timeline)
    }

    func testSourceKeyframeMapsToEveryRepeatedOutputOccurrence() {
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 8,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 2,
                    sourceEndSeconds: 4,
                    playbackRate: 2
                ),
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 1
                ),
                VideoEditSegment(
                    sourceStartSeconds: 2,
                    sourceEndSeconds: 4
                )
            ]
        )

        XCTAssertEqual(timeline.outputTimes(forSourceTime: 3), [0.5, 3])
        XCTAssertTrue(timeline.outputTimes(forSourceTime: 6).isEmpty)
        XCTAssertTrue(timeline.outputTimes(forSourceTime: .infinity).isEmpty)
    }

    func testSourceKeyframeAtCutBoundaryDoesNotCreateDuplicateMarker() {
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 6,
            segments: [
                VideoEditSegment(sourceStartSeconds: 0, sourceEndSeconds: 3),
                VideoEditSegment(sourceStartSeconds: 3, sourceEndSeconds: 6)
            ]
        )

        XCTAssertEqual(timeline.outputTimes(forSourceTime: 3), [3])
        XCTAssertEqual(timeline.outputTimes(forSourceTime: 6), [6])
    }

    func testOverlappingTransitionsResolveLayoutDurationAndDominantSourceTime() throws {
        let first = VideoEditSegment(
            sourceStartSeconds: 0,
            sourceEndSeconds: 4,
            transitionToNext: VideoEditTransition(
                kind: .crossDissolve,
                durationSeconds: 0.8
            )
        )
        let second = VideoEditSegment(
            sourceStartSeconds: 4,
            sourceEndSeconds: 8,
            transitionToNext: VideoEditTransition(
                kind: .dipToBlack,
                durationSeconds: 0.6
            )
        )
        let third = VideoEditSegment(sourceStartSeconds: 8, sourceEndSeconds: 10)
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 10,
            segments: [first, second, third]
        )

        XCTAssertEqual(timeline.outputDurationSeconds, 8.6, accuracy: 0.000_001)
        for (actual, expected) in zip(
            timeline.segmentLayouts.map(\.outputStartSeconds),
            [0, 3.2, 6.6]
        ) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(timeline.resolvedTransitions.map(\.kind), [.crossDissolve, .dipToBlack])
        XCTAssertEqual(timeline.resolvedTransitions.map(\.durationSeconds), [0.8, 0.6])

        let outgoing = try XCTUnwrap(timeline.position(atOutputTime: 3.35))
        XCTAssertEqual(outgoing.segmentID, first.id)
        XCTAssertEqual(outgoing.sourceTimeSeconds, 3.35, accuracy: 0.000_001)
        let incoming = try XCTUnwrap(timeline.position(atOutputTime: 3.65))
        XCTAssertEqual(incoming.segmentID, second.id)
        XCTAssertEqual(incoming.sourceTimeSeconds, 4.45, accuracy: 0.000_001)
        XCTAssertEqual(timeline.outputTimes(forSourceTime: 5), [4.2])
    }

    func testTransitionDurationIsClampedByBothNeighboringSegments() throws {
        let first = VideoEditSegment(
            sourceStartSeconds: 0,
            sourceEndSeconds: 1,
            transitionToNext: VideoEditTransition(
                kind: .crossDissolve,
                durationSeconds: 1.5
            )
        )
        let second = VideoEditSegment(sourceStartSeconds: 1, sourceEndSeconds: 1.4)
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [first, second]
        )

        let transition = try XCTUnwrap(timeline.resolvedTransitions.first)
        XCTAssertEqual(transition.durationSeconds, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(timeline.outputDurationSeconds, 1.2, accuracy: 0.000_001)
    }

    func testSplitKeepsExistingOutgoingTransitionOnTrailingSegment() throws {
        let original = VideoEditSegment(
            sourceStartSeconds: 0,
            sourceEndSeconds: 6,
            transitionToNext: VideoEditTransition(
                kind: .dipToBlack,
                durationSeconds: 0.45
            )
        )
        let next = VideoEditSegment(sourceStartSeconds: 6, sourceEndSeconds: 8)
        var timeline = VideoEditTimeline(
            sourceDurationSeconds: 8,
            segments: [original, next]
        )

        let trailingID = try XCTUnwrap(timeline.split(
            segmentID: original.id,
            atSourceTime: 3
        ))

        XCTAssertNil(timeline.segments[0].transitionToNext)
        XCTAssertEqual(
            timeline.segments.first(where: { $0.id == trailingID })?.transitionToNext,
            VideoEditTransition(kind: .dipToBlack, durationSeconds: 0.45)
        )
        XCTAssertEqual(timeline.resolvedTransitions.count, 1)
        XCTAssertEqual(timeline.resolvedTransitions.first?.fromSegmentID, trailingID)
    }

    func testLegacySegmentWithoutTransitionDecodesAsCut() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceDurationSeconds": 3,
            "segments": [[
                "id": id.uuidString,
                "sourceStartSeconds": 0,
                "sourceEndSeconds": 3,
                "playbackRate": 1,
                "isEnabled": true
            ]]
        ])

        let timeline = try JSONDecoder().decode(VideoEditTimeline.self, from: data)

        XCTAssertNil(timeline.segments.first?.transitionToNext)
        XCTAssertFalse(timeline.hasActiveTransitions)
        XCTAssertEqual(timeline.outputDurationSeconds, 3)
    }

    func testDecodedTransitionDurationIsSanitized() throws {
        let oversized = Data(#"{"kind":"crossDissolve","durationSeconds":99}"#.utf8)
        let cut = Data(#"{"kind":"cut","durationSeconds":1}"#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(VideoEditTransition.self, from: oversized),
            VideoEditTransition(kind: .crossDissolve, durationSeconds: 2)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(VideoEditTransition.self, from: cut),
            VideoEditTransition(kind: .cut, durationSeconds: 0)
        )
    }

    func testRemoveSourceRangeSplitsAndDisablesCoveredSlice() {
        var timeline = VideoEditTimeline(sourceDurationSeconds: 10)
        XCTAssertTrue(timeline.removeSourceRange(startSeconds: 4, endSeconds: 6))

        XCTAssertEqual(timeline.segments.count, 3)
        XCTAssertEqual(timeline.activeSegments.count, 2)
        XCTAssertEqual(timeline.activeSegments[0].sourceEndSeconds, 4)
        XCTAssertEqual(timeline.activeSegments[1].sourceStartSeconds, 6)
        XCTAssertEqual(timeline.outputDurationSeconds, 8)

        // The disabled slice stays addressable, so the removal is undoable.
        let disabled = timeline.segments.first { $0.isEnabled == false }
        XCTAssertEqual(disabled?.sourceStartSeconds, 4)
        XCTAssertEqual(disabled?.sourceEndSeconds, 6)
    }

    func testRemoveSourceRangePreservesOutgoingTransitionOnKeptPiece() {
        let original = VideoEditSegment(
            sourceStartSeconds: 0,
            sourceEndSeconds: 6,
            transitionToNext: VideoEditTransition(
                kind: .crossDissolve,
                durationSeconds: 0.4
            )
        )
        let next = VideoEditSegment(sourceStartSeconds: 6, sourceEndSeconds: 8)
        var timeline = VideoEditTimeline(
            sourceDurationSeconds: 8,
            segments: [original, next]
        )

        XCTAssertTrue(timeline.removeSourceRange(startSeconds: 2, endSeconds: 4))

        XCTAssertEqual(timeline.resolvedTransitions.count, 1)
        XCTAssertEqual(
            timeline.resolvedTransitions.first?.fromSegmentID,
            timeline.segments.first { $0.sourceStartSeconds == 4 }?.id
        )
    }

    func testRemoveSourceRangeRefusesToWipeOutEveryEnabledSegment() {
        var timeline = VideoEditTimeline(sourceDurationSeconds: 4)
        XCTAssertFalse(timeline.removeSourceRange(startSeconds: 0, endSeconds: 4))
        XCTAssertEqual(timeline.segments.count, 1)
        XCTAssertEqual(timeline.outputDurationSeconds, 4)
    }

    func testRemoveSourceRangeDropsSubMinimumRemaindersLikeNormalization() {
        var timeline = VideoEditTimeline(sourceDurationSeconds: 1)
        XCTAssertTrue(timeline.removeSourceRange(startSeconds: 0.9, endSeconds: 1))

        // The covered slice survives as a disabled segment; the sub-minimum
        // trailing remainder (0.1s < minimum) is dropped entirely.
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertTrue(timeline.segments[0].isEnabled)
        XCTAssertEqual(timeline.segments[0].sourceEndSeconds, 0.9)
        XCTAssertEqual(timeline.outputDurationSeconds, 0.9, accuracy: 0.000_001)
    }

    func testRemoveSourceRangeIgnoresRangesBelowMinimumSegmentDuration() {
        var timeline = VideoEditTimeline(sourceDurationSeconds: 5)
        XCTAssertFalse(timeline.removeSourceRange(startSeconds: 2, endSeconds: 2.03))
        XCTAssertEqual(timeline.segments.count, 1)
    }
}
