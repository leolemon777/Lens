import AVFoundation
import XCTest
@testable import LensCore
@testable import LensMac

final class TranscriptionAudioChunkExporterTests: XCTestCase {
    func testExporterCutsRequestedAudioRangeIntoSpeechCompatibleM4A() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensTranscriptionChunkTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("narration.caf")
        let outputURL = directory.appendingPathComponent("chunk.m4a")
        try makeTone(at: inputURL, frameCount: 144_000)
        let chunk = TranscriptChunk(
            index: 0,
            sourceStartSeconds: 0.5,
            sourceEndSeconds: 1.75,
            acceptedStartSeconds: 0.5,
            acceptedEndSeconds: 1.75
        )

        _ = try await TranscriptionAudioChunkExporter().export(
            inputURL: inputURL,
            chunk: chunk,
            outputURL: outputURL
        )

        let output = AVURLAsset(url: outputURL)
        let tracks = try await output.loadTracks(withMediaType: .audio)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(duration, 1.25, accuracy: 0.04)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber)?.int64Value ?? 0,
            2_000
        )
    }

    private func makeTone(at url: URL, frameCount: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = sin(Float(index) * 0.035) * 0.12
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }
}
