import AVFoundation
import XCTest
@testable import ScreenTraceMac

final class MicrophoneTrackRecorderTests: XCTestCase {
    func testWriterPersistsSyntheticNarrationAsIndependentCAFTrack() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceMicrophoneTests-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)
        )
        buffer.frameLength = 4_800
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = sin(Float(index) * 0.04) * 0.18
        }

        var writer: MicrophoneFileWriter? = try makeWriter(url: outputURL, format: format)
        writer?.write(buffer)
        XCTAssertNil(writer?.failure)
        writer = nil

        let track = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(track.processingFormat.channelCount, 1)
        XCTAssertEqual(track.processingFormat.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(track.length, 4_800)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0,
            1_000
        )
    }

    private func makeWriter(url: URL, format: AVAudioFormat) throws -> MicrophoneFileWriter {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        return MicrophoneFileWriter(file: file)
    }
}
