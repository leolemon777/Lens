import AVFoundation
import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

final class VoiceAudioProcessorTests: XCTestCase {
    func testKWeightedLoudnessMatchesReferenceOneKilohertzTone() async throws {
        let directory = try temporaryDirectory(named: "KWeighting")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.caf")
        try makeAudio(at: url, durationSeconds: 2) { frame, sampleRate in
            Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate) * 0.1)
        }

        let metrics = try await VoiceAudioProcessor().analyze(url: url)

        XCTAssertEqual(metrics.integratedLoudnessLUFS, -23.0, accuracy: 0.2)
    }

    func testQuietVoiceIsNormalizedToRequestedLoudnessWithoutChangingDuration() async throws {
        let directory = try temporaryDirectory(named: "Loudness")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("quiet.caf")
        let outputURL = directory.appendingPathComponent("normalized.caf")
        try makeAudio(at: inputURL, durationSeconds: 2) { frame, sampleRate in
            Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.08)
        }
        let processor = VoiceAudioProcessor()
        let plan = AutoEditPlan.Audio(
            reducesMicrophoneNoise: false,
            normalizesLoudness: true,
            targetLoudnessLUFS: -18,
            ducksSystemUnderNarration: false
        )

        let result = try await processor.process(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertGreaterThan(result.appliedGainDecibels, 5)
        XCTAssertEqual(result.after.integratedLoudnessLUFS, -18, accuracy: 0.35)
        XCTAssertEqual(result.after.durationSeconds, 2, accuracy: 1.0 / 48_000)
        XCTAssertLessThanOrEqual(result.after.peakAmplitude, 0.98)
    }

    func testNoiseReductionImprovesQuietRegionSignalToNoiseAndPreservesRawTrack() async throws {
        let directory = try temporaryDirectory(named: "NoiseReduction")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("noisy-voice.caf")
        let outputURL = directory.appendingPathComponent("conditioned.caf")
        var randomState: UInt64 = 0x5EED_F00D
        try makeAudio(at: inputURL, durationSeconds: 3) { frame, sampleRate in
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let random = Double(Int64(bitPattern: randomState) >> 40)
                / Double(1 << 23)
            let time = Double(frame) / sampleRate
            let hum = sin(2 * Double.pi * 50 * time) * 0.045
            let broadbandNoise = random * 0.009
            let voice = (1.0..<2.0).contains(time)
                ? sin(2 * Double.pi * 900 * time) * 0.22
                : 0
            return Float(hum + broadbandNoise + voice)
        }
        let originalBytes = try Data(contentsOf: inputURL)
        let plan = AutoEditPlan.Audio(
            reducesMicrophoneNoise: true,
            noiseReductionAmount: 0.85,
            normalizesLoudness: false,
            ducksSystemUnderNarration: false
        )

        let result = try await VoiceAudioProcessor().process(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        let quietBefore = try rms(url: inputURL, range: 0.4..<0.8)
        let voiceBefore = try rms(url: inputURL, range: 1.3..<1.7)
        let quietAfter = try rms(url: outputURL, range: 0.4..<0.8)
        let voiceAfter = try rms(url: outputURL, range: 1.3..<1.7)
        let snrBefore = 20 * log10(voiceBefore / quietBefore)
        let snrAfter = 20 * log10(voiceAfter / quietAfter)

        XCTAssertLessThan(quietAfter, quietBefore * 0.45)
        XCTAssertGreaterThan(voiceAfter, voiceBefore * 0.28)
        XCTAssertGreaterThan(snrAfter, snrBefore + 6)
        XCTAssertLessThan(
            result.after.noiseFloorDecibels,
            result.before.noiseFloorDecibels - 5
        )
        XCTAssertEqual(result.after.durationSeconds, 3, accuracy: 1.0 / 48_000)
        XCTAssertEqual(try Data(contentsOf: inputURL), originalBytes)
    }

    func testRecommendedGainRespectsPeakAndBoostLimits() {
        XCTAssertEqual(
            VoiceAudioProcessor.recommendedGainDecibels(
                measuredLoudnessLUFS: -40,
                targetLoudnessLUFS: -16,
                peakAmplitude: 0.1,
                maximumBoostDecibels: 8
            ),
            8,
            accuracy: 0.000_001
        )
        let peakLimited = VoiceAudioProcessor.recommendedGainDecibels(
            measuredLoudnessLUFS: -24,
            targetLoudnessLUFS: -16,
            peakAmplitude: 0.9
        )
        XCTAssertLessThan(peakLimited, 1)
        XCTAssertGreaterThan(peakLimited, 0)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LensVoice\(name)Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeAudio(
        at url: URL,
        durationSeconds: Double,
        sample: (Int, Double) -> Float
    ) throws {
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = sample(frame, sampleRate)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func rms(url: URL, range: Range<Double>) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(range.lowerBound * format.sampleRate)
        let frameCount = AVAudioFrameCount(
            (range.upperBound - range.lowerBound) * format.sampleRate
        )
        file.framePosition = startFrame
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        try file.read(into: buffer, frameCount: frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let count = Int(buffer.frameLength)
        let energy = (0..<count).reduce(0.0) {
            $0 + Double(samples[$1]) * Double(samples[$1])
        }
        return sqrt(energy / Double(max(count, 1)))
    }
}
