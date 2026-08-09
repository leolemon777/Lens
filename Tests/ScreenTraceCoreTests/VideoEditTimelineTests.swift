import Foundation
import XCTest
@testable import ScreenTraceCore

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
}
