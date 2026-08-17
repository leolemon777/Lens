import AVFoundation
import XCTest
@testable import ScreenTraceMac

final class AudioMediaEvidenceAnalyzerTests: XCTestCase {
    func testDistributedWindowsDetectLateRecordingSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenTraceAudioContinuity-\(UUID().uuidString).caf"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url, silentAfterSeconds: 5)

        let analyzed = await AudioMediaEvidenceAnalyzer.analyze(url: url)
        let evidence = try XCTUnwrap(analyzed)

        XCTAssertEqual(evidence.windowRootMeanSquares.count, 5)
        XCTAssertGreaterThan(evidence.rootMeanSquare, 0.01)
        XCTAssertLessThan(evidence.minimumWindowRootMeanSquare, 0.000_001)
    }

    func testDistributedWindowsAcceptContinuousTone() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenTraceAudioContinuous-\(UUID().uuidString).caf"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url, silentAfterSeconds: nil)

        let analyzed = await AudioMediaEvidenceAnalyzer.analyze(url: url)
        let evidence = try XCTUnwrap(analyzed)

        XCTAssertEqual(evidence.windowRootMeanSquares.count, 5)
        XCTAssertGreaterThan(evidence.minimumWindowRootMeanSquare, 0.01)
    }

    private func writeFixture(to url: URL, silentAfterSeconds: Int?) throws {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let framesPerBuffer = AVAudioFrameCount(sampleRate)
        for second in 0..<10 {
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: framesPerBuffer
                )
            )
            buffer.frameLength = framesPerBuffer
            let isSilent = silentAfterSeconds.map { second >= $0 } ?? false
            for channelIndex in 0..<Int(format.channelCount) {
                let channel = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
                for frame in 0..<Int(framesPerBuffer) {
                    channel[frame] = isSilent
                        ? 0
                        : sin(Float(frame) * 0.036 + Float(channelIndex) * 0.3) * 0.18
                }
            }
            try file.write(from: buffer)
        }
    }
}
