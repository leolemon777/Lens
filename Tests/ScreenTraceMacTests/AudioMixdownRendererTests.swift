import AVFoundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class AudioMixdownRendererTests: XCTestCase {
    func testNarrationAnalyzerFindsSeparatedSpeechRegions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceNarration-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeTone(
            at: url,
            frameCount: 48_000,
            amplitudeAtFrame: { frame in
                ((9_600..<24_000).contains(frame) || (36_000..<43_200).contains(frame))
                    ? 0.22
                    : 0
            }
        )

        let ranges = try NarrationActivityAnalyzer().analyze(
            url: url,
            thresholdDecibels: -32,
            windowSeconds: 0.05
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].startSeconds, 0.2, accuracy: 0.06)
        XCTAssertEqual(ranges[0].endSeconds, 0.5, accuracy: 0.06)
        XCTAssertEqual(ranges[1].startSeconds, 0.75, accuracy: 0.06)
        XCTAssertEqual(ranges[1].endSeconds, 0.9, accuracy: 0.06)
    }

    func testDuckingEnvelopeMergesCloseNarrationAndClampsToTimeline() {
        let envelopes = AudioMixdownRenderer.duckingEnvelopes(
            activity: [
                NarrationActivityRange(startSeconds: 1, endSeconds: 2),
                NarrationActivityRange(startSeconds: 2.2, endSeconds: 2.5),
                NarrationActivityRange(startSeconds: 4.8, endSeconds: 5.2)
            ],
            attackSeconds: 0.2,
            releaseSeconds: 0.4,
            durationSeconds: 5
        )

        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes[0], DuckingEnvelope(
            attackStartSeconds: 0.8,
            fullDuckStartSeconds: 1,
            fullDuckEndSeconds: 2.5,
            releaseEndSeconds: 2.9
        ))
        XCTAssertEqual(envelopes[1], DuckingEnvelope(
            attackStartSeconds: 4.6,
            fullDuckStartSeconds: 4.8,
            fullDuckEndSeconds: 5,
            releaseEndSeconds: 5
        ))
    }

    @MainActor
    func testSystemAndMicrophoneTracksExportAsPlayableMixedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceMixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mp4")
        let systemURL = directory.appendingPathComponent("system.caf")
        let inputURL = directory.appendingPathComponent("input.mp4")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let outputURL = directory.appendingPathComponent("mixed.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try makeTone(at: systemURL, frameCount: 60_000) { _ in 0.04 }
        try makeTone(at: microphoneURL, frameCount: 60_000) { frame in
            (12_000..<48_000).contains(frame) ? 0.18 : 0
        }
        try await mux(videoURL: videoURL, audioURL: systemURL, outputURL: inputURL)
        let plan = AutoEditPlan.Audio(
            systemVolume: 0.9,
            microphoneVolume: 1,
            ducksSystemUnderNarration: true,
            duckedSystemVolume: 0.25,
            narrationThresholdDecibels: -36
        )

        _ = try await AudioMixdownRenderer().render(
            inputURL: inputURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            plan: plan
        )

        let output = AVURLAsset(url: outputURL)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.1)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber)?.int64Value ?? 0,
            2_000
        )
    }

    @MainActor
    func testTimelineCutsRemainAlignedAcrossVideoSystemAndMicrophoneAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTimelineMixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mp4")
        let systemURL = directory.appendingPathComponent("system.caf")
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let editedURL = directory.appendingPathComponent("edited.mp4")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let outputURL = directory.appendingPathComponent("mixed.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 48,
            framesPerSecond: 24
        )
        try makeTone(at: systemURL, frameCount: 96_000) { _ in 0.04 }
        try makeTone(at: microphoneURL, frameCount: 96_000) { frame in
            (9_600..<86_400).contains(frame) ? 0.16 : 0
        }
        try await mux(videoURL: videoURL, audioURL: systemURL, outputURL: rawURL)
        var editPlan = AutoEditPlan()
        editPlan.canvas?.isEnabled = false
        editPlan.presenterCamera?.isEnabled = false
        editPlan.timeline = VideoEditTimeline(
            sourceDurationSeconds: 2,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0.2,
                    sourceEndSeconds: 0.7,
                    transitionToNext: VideoEditTransition(
                        kind: .crossDissolve,
                        durationSeconds: 0.2
                    )
                ),
                VideoEditSegment(
                    sourceStartSeconds: 1,
                    sourceEndSeconds: 1.8,
                    playbackRate: 2
                )
            ]
        )
        _ = try await AutoPreviewRenderer().render(
            inputURL: rawURL,
            outputURL: editedURL,
            plan: editPlan
        )

        _ = try await AudioMixdownRenderer().render(
            inputURL: editedURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            plan: try XCTUnwrap(editPlan.audio),
            timeline: editPlan.timeline
        )

        let output = AVURLAsset(url: outputURL)
        let duration = try await output.load(.duration).seconds
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(duration, 0.7, accuracy: 0.10)
    }

    private func makeTone(
        at url: URL,
        frameCount: AVAudioFrameCount,
        amplitudeAtFrame: (Int) -> Float
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = sin(Float(index) * 0.035) * amplitudeAtFrame(index)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    @MainActor
    private func mux(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        let composition = AVMutableComposition()
        let outputVideo = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let outputAudio = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try outputVideo.insertTimeRange(
            CMTimeRange(start: videoRange.start, duration: duration),
            of: videoTrack,
            at: .zero
        )
        try outputAudio.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ))
        try await exporter.export(to: outputURL, as: .mp4)
    }
}
