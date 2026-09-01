import AVFoundation
import XCTest
@testable import LensCore
@testable import LensMac

final class AudioMixdownRendererTests: XCTestCase {
    func testNarrationAnalyzerFindsSeparatedSpeechRegions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensNarration-\(UUID().uuidString).caf")
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
            .appendingPathComponent("LensMixTests-\(UUID().uuidString)", isDirectory: true)
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
        let originalMicrophoneBytes = try Data(contentsOf: microphoneURL)
        try await mux(videoURL: videoURL, audioURL: systemURL, outputURL: inputURL)
        let plan = AutoEditPlan.Audio(
            systemVolume: 0.9,
            microphoneVolume: 1,
            ducksSystemUnderNarration: true,
            duckedSystemVolume: 0.25,
            narrationThresholdDecibels: -36
        )

        let renderer = AudioMixdownRenderer()
        let report = try await renderer.renderWithReport(
            inputURL: inputURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            plan: plan,
            export: .init(preset: .compact)
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
        XCTAssertNil(report.voiceProcessingErrorDescription)
        let voiceResult = try XCTUnwrap(report.voiceProcessingResult)
        XCTAssertEqual(
            voiceResult.after.integratedLoudnessLUFS,
            plan.targetLoudnessLUFS,
            accuracy: 0.6
        )
        XCTAssertEqual(try Data(contentsOf: microphoneURL), originalMicrophoneBytes)

        var editPlan = AutoEditPlan()
        editPlan.camera.mode = "off"
        editPlan.cursor.isEnabled = false
        editPlan.canvas?.isEnabled = false
        editPlan.presenterCamera?.isEnabled = false
        editPlan.captions?.isEnabled = false
        editPlan.audio = plan
        let evidence = await RenderedEffectVerifier(
            renderer: AutoPreviewRenderer()
        ).validate(
            rawURL: inputURL,
            previewURL: outputURL,
            plan: editPlan,
            microphoneURL: microphoneURL
        )
        let audioEvidence = try XCTUnwrap(
            evidence.effects.first { $0.effect == .audioMix }
        )
        XCTAssertEqual(audioEvidence.state, .verified)
        XCTAssertGreaterThan(try XCTUnwrap(audioEvidence.audioDifference), 0.0015)
        XCTAssertTrue(evidence.isVerified)
    }

    @MainActor
    func testSourceQualityMixdownPreservesReorderedSixtyFPSVideoTiming() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensSourceTimingMixTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("reordered-60.mp4")
        let inputURL = directory.appendingPathComponent("effects-60.mp4")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let outputURL = directory.appendingPathComponent("mixed.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 120,
            framesPerSecond: 60,
            width: 2_560,
            height: 1_664,
            allowsFrameReordering: true
        )
        var editPlan = AutoEditPlan()
        editPlan.camera.mode = "off"
        editPlan.cursor.isEnabled = false
        editPlan.canvas?.isEnabled = false
        editPlan.presenterCamera?.isEnabled = false
        editPlan.captions?.isEnabled = false
        editPlan.export = .init(preset: .source)
        _ = try await AutoPreviewRenderer().render(
            inputURL: rawURL,
            outputURL: inputURL,
            plan: editPlan
        )
        try makeTone(at: microphoneURL, frameCount: 96_000) { frame in
            frame < 48_000 ? 0.16 : 0
        }
        let plan = AutoEditPlan.Audio(
            reducesMicrophoneNoise: false,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )

        _ = try await AudioMixdownRenderer().render(
            inputURL: inputURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            plan: plan,
            export: .init(preset: .source)
        )

        let output = AVURLAsset(url: outputURL)
        let outputTracks = try await output.loadTracks(withMediaType: .video)
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let nominalFrameRate = try await outputTrack.load(.nominalFrameRate)
        XCTAssertGreaterThanOrEqual(nominalFrameRate, 58)
    }

    /// The single-pass path must not resurrect the 30 FPS trap the two-pass
    /// mix once had: the effects render embeds the prepared audio sidecar in
    /// its only video encode and keeps source-timing fidelity.
    func testSinglePassSidecarEmbedsMicrophoneMixDuringTheOnlyVideoEncode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensSinglePassMixTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw-60.mp4")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let sidecarURL = directory.appendingPathComponent("mix.caf")
        let outputURL = directory.appendingPathComponent("preview.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: rawURL,
            frameCount: 120,
            framesPerSecond: 60,
            allowsFrameReordering: true
        )
        try makeTone(at: microphoneURL, frameCount: 96_000) { frame in
            frame < 48_000 ? 0.16 : 0
        }
        let audioPlan = AutoEditPlan.Audio(
            reducesMicrophoneNoise: false,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )

        let report = try await AudioMixdownRenderer().prepareMixedAudioSidecar(
            sourceURL: rawURL,
            microphoneURL: microphoneURL,
            outputURL: sidecarURL,
            plan: audioPlan
        )
        let sidecar = AVURLAsset(url: sidecarURL)
        let sidecarAudioTracks = try await sidecar.loadTracks(withMediaType: .audio)
        let sidecarVideoTracks = try await sidecar.loadTracks(withMediaType: .video)
        XCTAssertFalse(sidecarAudioTracks.isEmpty)
        XCTAssertTrue(sidecarVideoTracks.isEmpty)
        XCTAssertNil(report.voiceProcessingResult)
        XCTAssertNil(report.voiceProcessingErrorDescription)

        var editPlan = AutoEditPlan()
        editPlan.camera.mode = "off"
        editPlan.cursor.isEnabled = false
        editPlan.canvas?.isEnabled = false
        editPlan.presenterCamera?.isEnabled = false
        editPlan.captions?.isEnabled = false
        editPlan.export = .init(preset: .source)
        _ = try await AutoPreviewRenderer().render(
            inputURL: rawURL,
            outputURL: outputURL,
            plan: editPlan,
            mixedAudioURL: sidecarURL
        )

        let output = AVURLAsset(url: outputURL)
        let outputVideoTracks = try await output.loadTracks(withMediaType: .video)
        let outputAudioTracks = try await output.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(outputVideoTracks.first)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        XCTAssertGreaterThanOrEqual(nominalFrameRate, 58)
        XCTAssertFalse(outputAudioTracks.isEmpty)
        let analyzer = VoiceAudioProcessor()
        let metrics = try await analyzer.analyze(url: outputURL)
        XCTAssertEqual(
            metrics.peakAmplitude,
            0.16,
            accuracy: 0.05,
            "成片音轨应携带麦克风混音电平。"
        )
    }

    func testSidecarProgressIsMonotonicAndEndsAtOne() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensSidecarProgressTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.mp4")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let sidecarURL = directory.appendingPathComponent("mix.caf")
        try await SyntheticVideoFactory.makeVideo(at: rawURL, frameCount: 96, framesPerSecond: 24)
        try makeTone(at: microphoneURL, frameCount: 96_000) { _ in 0.16 }
        let audioPlan = AutoEditPlan.Audio(
            reducesMicrophoneNoise: false,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )

        let collector = ProgressCollectorBox()
        _ = try await AudioMixdownRenderer().prepareMixedAudioSidecar(
            sourceURL: rawURL,
            microphoneURL: microphoneURL,
            outputURL: sidecarURL,
            plan: audioPlan,
            progress: { collector.append($0) }
        )

        let values = collector.recorded
        XCTAssertFalse(values.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values.first), 0)
        XCTAssertEqual(try XCTUnwrap(values.last), 1)
        XCTAssertEqual(values, values.sorted(), "progress must never move backwards")
    }

    @MainActor
    func testSystemVolumeAppliesWithoutMicrophoneTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensSystemOnlyMixTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mp4")
        let systemURL = directory.appendingPathComponent("system.caf")
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("adjusted.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try makeTone(at: systemURL, frameCount: 60_000) { _ in 0.20 }
        try await mux(videoURL: videoURL, audioURL: systemURL, outputURL: inputURL)
        let plan = AutoEditPlan.Audio(
            systemVolume: 0.25,
            reducesMicrophoneNoise: false,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )

        XCTAssertTrue(AudioMixdownRenderer.requiresMixdown(
            microphoneURL: nil,
            plan: plan
        ))
        let report = try await AudioMixdownRenderer().renderWithReport(
            inputURL: inputURL,
            microphoneURL: nil,
            outputURL: outputURL,
            plan: plan
        )

        let output = AVURLAsset(url: outputURL)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertNil(report.voiceProcessingResult)
        XCTAssertNil(report.voiceProcessingErrorDescription)
        let analyzer = VoiceAudioProcessor()
        let before = try await analyzer.analyze(url: inputURL)
        let after = try await analyzer.analyze(url: outputURL)
        XCTAssertEqual(
            after.peakAmplitude / before.peakAmplitude,
            0.25,
            accuracy: 0.04
        )

        var unity = plan
        unity.systemVolume = 1
        XCTAssertFalse(AudioMixdownRenderer.requiresMixdown(
            microphoneURL: nil,
            plan: unity
        ))
    }

    @MainActor
    func testFinalMediaEvidenceProvesSystemVolumeAndRejectsAnUnchangedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensAudioEvidenceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mp4")
        let systemURL = directory.appendingPathComponent("system.caf")
        let inputURL = directory.appendingPathComponent("input.mp4")
        let adjustedURL = directory.appendingPathComponent("adjusted.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try makeTone(at: systemURL, frameCount: 60_000) { frame in
            sin(Float(frame) * 0.007) * 0.18
        }
        try await mux(videoURL: videoURL, audioURL: systemURL, outputURL: inputURL)

        var editPlan = AutoEditPlan()
        editPlan.camera.mode = "off"
        editPlan.cursor.isEnabled = false
        editPlan.canvas?.isEnabled = false
        editPlan.presenterCamera?.isEnabled = false
        editPlan.captions?.isEnabled = false
        editPlan.audio = AutoEditPlan.Audio(
            systemVolume: 0.25,
            reducesMicrophoneNoise: false,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )
        _ = try await AudioMixdownRenderer().render(
            inputURL: inputURL,
            microphoneURL: nil,
            outputURL: adjustedURL,
            plan: try XCTUnwrap(editPlan.audio)
        )

        let verifier = RenderedEffectVerifier(renderer: AutoPreviewRenderer())
        let verifiedReport = await verifier.validate(
            rawURL: inputURL,
            previewURL: adjustedURL,
            plan: editPlan
        )
        let verifiedAudio = try XCTUnwrap(
            verifiedReport.effects.first { $0.effect == .audioMix }
        )
        XCTAssertEqual(verifiedAudio.state, .verified)
        let outputRMS = try XCTUnwrap(verifiedAudio.outputAudioRMS)
        let referenceRMS = try XCTUnwrap(verifiedAudio.referenceAudioRMS)
        XCTAssertEqual(outputRMS / referenceRMS, 0.25, accuracy: 0.05)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(verifiedAudio.audioDurationDriftSeconds),
            0.15
        )

        let unchangedReport = await verifier.validate(
            rawURL: inputURL,
            previewURL: inputURL,
            plan: editPlan
        )
        let unchangedAudio = try XCTUnwrap(
            unchangedReport.effects.first { $0.effect == .audioMix }
        )
        XCTAssertEqual(unchangedAudio.state, .failed)
        XCTAssertFalse(unchangedReport.isVerified)
    }

    @MainActor
    func testTimelineCutsRemainAlignedAcrossVideoSystemAndMicrophoneAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensTimelineMixTests-\(UUID().uuidString)", isDirectory: true)
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
