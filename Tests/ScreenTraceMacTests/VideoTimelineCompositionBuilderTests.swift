import AVFoundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class VideoTimelineCompositionBuilderTests: XCTestCase {
    @MainActor
    func testShortSidecarKeepsMissingMediaAsSilenceInsteadOfShiftingLaterClips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScreenTraceShortSidecarTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("sidecar.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: sourceURL,
            frameCount: 24,
            framesPerSecond: 24
        )
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(sourceStartSeconds: 0.8, sourceEndSeconds: 1.2),
                VideoEditSegment(sourceStartSeconds: 0.1, sourceEndSeconds: 0.3)
            ]
        )

        let composition = try await VideoTimelineCompositionBuilder().build(
            inputURL: sourceURL,
            timeline: timeline,
            includesVideo: true,
            includesAudio: false,
            requiresVideo: true
        )

        let tracks = try await composition.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let mediaSegments = try await track.load(.segments).filter { !$0.isEmpty }
        let compositionDuration = try await composition.load(.duration).seconds
        XCTAssertEqual(mediaSegments.count, 2)
        XCTAssertEqual(
            mediaSegments[1].timeMapping.target.start.seconds,
            0.4,
            accuracy: 0.02
        )
        XCTAssertEqual(
            compositionDuration,
            0.6,
            accuracy: 0.02
        )
    }
}
