import AVFoundation
import AppKit
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

    @MainActor
    func testCrossDissolveExportsOverlappingTracksAndBlendedPixels() async throws {
        let directory = try makeTemporaryDirectory(named: "CrossDissolve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("dissolve.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: sourceURL,
            frameCount: 48,
            framesPerSecond: 24,
            style: .temporalSplit(splitFrame: 24)
        )
        let timeline = transitionTimeline(kind: .crossDissolve)
        let builder = VideoTimelineCompositionBuilder()

        let package = try await builder.buildPackage(
            inputURL: sourceURL,
            timeline: timeline,
            includesVideo: true,
            includesAudio: false,
            requiresVideo: true
        )

        let compositionVideoTrackCount = try await package.composition
            .loadTracks(withMediaType: .video).count
        let compositionDuration = try await package.composition.load(.duration).seconds
        XCTAssertEqual(compositionVideoTrackCount, 2)
        XCTAssertEqual(package.videoComposition?.instructions.count, 3)
        XCTAssertEqual(compositionDuration, 1.5, accuracy: 0.03)
        _ = try await builder.export(
            inputURL: sourceURL,
            timeline: timeline,
            outputURL: outputURL,
            includesVideo: true,
            includesAudio: false,
            requiresVideo: true
        )

        let asset = AVURLAsset(url: outputURL)
        let outputDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(outputDuration, 1.5, accuracy: 0.08)
        let before = try await Self.centerColor(in: outputURL, at: 0.1)
        let middle = try await Self.centerColor(in: outputURL, at: 0.75)
        let after = try await Self.centerColor(in: outputURL, at: 1.4)
        XCTAssertGreaterThan(before.red, before.blue * 3)
        XCTAssertGreaterThan(after.blue, after.red * 3)
        XCTAssertGreaterThan(middle.red, 0.24)
        XCTAssertGreaterThan(middle.blue, 0.24)
        XCTAssertLessThan(
            abs(middle.red - middle.blue),
            0.22,
            "The transition midpoint should contain both neighboring frames: \(middle)"
        )
    }

    @MainActor
    func testDipToBlackExportsARealBlackMidpoint() async throws {
        let directory = try makeTemporaryDirectory(named: "DipToBlack")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp4")
        let outputURL = directory.appendingPathComponent("dip.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: sourceURL,
            frameCount: 48,
            framesPerSecond: 24,
            style: .temporalSplit(splitFrame: 24)
        )

        _ = try await VideoTimelineCompositionBuilder().export(
            inputURL: sourceURL,
            timeline: transitionTimeline(kind: .dipToBlack),
            outputURL: outputURL,
            includesVideo: true,
            includesAudio: false,
            requiresVideo: true
        )

        let middle = try await Self.centerColor(in: outputURL, at: 0.75)
        XCTAssertLessThan(middle.red, 0.12, "\(middle)")
        XCTAssertLessThan(middle.green, 0.12, "\(middle)")
        XCTAssertLessThan(middle.blue, 0.12, "\(middle)")
    }

    private func transitionTimeline(
        kind: VideoEditTransition.Kind
    ) -> VideoEditTimeline {
        VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 1,
                    transitionToNext: VideoEditTransition(
                        kind: kind,
                        durationSeconds: 0.5
                    )
                ),
                VideoEditSegment(sourceStartSeconds: 1, sourceEndSeconds: 2)
            ]
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScreenTrace\(name)Tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private struct RGBComponents: Sendable, CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double

        var description: String {
            String(format: "rgb(%.3f, %.3f, %.3f)", red, green, blue)
        }
    }

    nonisolated private static func centerColor(
        in url: URL,
        at seconds: Double
    ) async throws -> RGBComponents {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        ).image
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(
            bitmap.colorAt(x: image.width / 2, y: image.height / 2)?
                .usingColorSpace(.deviceRGB)
        )
        return RGBComponents(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent
        )
    }
}
