import Foundation
import XCTest
@testable import ScreenTraceCore

final class VideoAnnotationTests: XCTestCase {
    func testOpacityIsSeekSafeAndUsesSmoothFades() {
        let item = VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: 2,
            sourceEndSeconds: 4,
            fadeDurationSeconds: 0.5
        )

        XCTAssertEqual(item.opacity(atSourceTime: 1.99), 0)
        XCTAssertEqual(item.opacity(atSourceTime: 2), 0)
        XCTAssertEqual(item.opacity(atSourceTime: 2.25), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(item.opacity(atSourceTime: 2.5), 1)
        XCTAssertEqual(item.opacity(atSourceTime: 3.75), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(item.opacity(atSourceTime: 4), 0)
    }

    func testNormalizationClampsToSourceAndDropsEmptyRanges() throws {
        let item = VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: -4,
            sourceEndSeconds: 14,
            fadeDurationSeconds: 8
        )
        let normalized = try XCTUnwrap(item.normalized(sourceDurationSeconds: 10))

        XCTAssertEqual(normalized.sourceStartSeconds, 0)
        XCTAssertEqual(normalized.sourceEndSeconds, 10)
        XCTAssertEqual(normalized.fadeDurationSeconds, 1)
        XCTAssertNil(VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: 12,
            sourceEndSeconds: 14
        ).normalized(sourceDurationSeconds: 10))
    }

    func testOutputRangesFollowCutsReorderingAndPlaybackRate() {
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 12,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 6,
                    sourceEndSeconds: 10,
                    playbackRate: 2
                ),
                VideoEditSegment(
                    sourceStartSeconds: 1,
                    sourceEndSeconds: 4
                ),
                VideoEditSegment(
                    sourceStartSeconds: 6,
                    sourceEndSeconds: 8
                )
            ]
        )
        let item = VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: 2,
            sourceEndSeconds: 8
        )

        XCTAssertEqual(VideoAnnotationPlanner.outputRanges(
            for: item,
            timeline: timeline
        ), [
            VideoEditTimeRange(startSeconds: 0, endSeconds: 1),
            VideoEditTimeRange(startSeconds: 3, endSeconds: 5),
            VideoEditTimeRange(startSeconds: 5, endSeconds: 7)
        ])
    }

    func testAnnotationsFollowCrossDissolveAndDipToBlackWeights() {
        let outgoing = VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: 0,
            sourceEndSeconds: 1,
            fadeDurationSeconds: 0
        )
        let incoming = VideoAnnotation(
            annotation: ScreenshotAnnotation(
                kind: .ellipse,
                bounds: TraceRect(x: 0.5, y: 0.2, width: 0.2, height: 0.3)
            ),
            sourceStartSeconds: 2,
            sourceEndSeconds: 3,
            fadeDurationSeconds: 0
        )
        let crossDissolve = VideoEditTimeline(
            sourceDurationSeconds: 3,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 1,
                    transitionToNext: VideoEditTransition(
                        kind: .crossDissolve,
                        durationSeconds: 0.5
                    )
                ),
                VideoEditSegment(sourceStartSeconds: 2, sourceEndSeconds: 3)
            ]
        )

        let mixed = VideoAnnotationPlanner.activeAnnotations(
            atOutputTime: 0.75,
            annotations: [outgoing, incoming],
            timeline: crossDissolve
        )
        XCTAssertEqual(mixed.map(\.annotation.id), [outgoing.id, incoming.id])
        XCTAssertEqual(mixed.map(\.opacity), [0.5, 0.5])

        var dipToBlack = crossDissolve
        dipToBlack.segments[0].transitionToNext = VideoEditTransition(
            kind: .dipToBlack,
            durationSeconds: 0.5
        )
        XCTAssertTrue(VideoAnnotationPlanner.activeAnnotations(
            atOutputTime: 0.75,
            annotations: [outgoing, incoming],
            timeline: dipToBlack
        ).isEmpty)
    }

    func testLegacyAutoEditPlanDecodesWithoutVideoAnnotations() throws {
        let encoded = try JSONEncoder().encode(AutoEditPlan())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "videoAnnotations")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: legacyData)

        XCTAssertNil(decoded.videoAnnotations)
    }

    func testAnnotationWithoutFadeUsesPortableDefault() throws {
        let encoded = try JSONEncoder().encode(VideoAnnotation(
            annotation: annotation(),
            sourceStartSeconds: 1,
            sourceEndSeconds: 2
        ))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "fadeDurationSeconds")

        let decoded = try JSONDecoder().decode(
            VideoAnnotation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.fadeDurationSeconds, 0.16)
    }

    private func annotation() -> ScreenshotAnnotation {
        ScreenshotAnnotation(
            kind: .rectangle,
            bounds: TraceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
    }
}
