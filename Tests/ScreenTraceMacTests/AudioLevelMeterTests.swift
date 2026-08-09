import AVFoundation
import XCTest
@testable import ScreenTraceMac

final class AudioLevelMeterTests: XCTestCase {
    func testInterleavedPCMBufferProducesNormalizedVisualLevel() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
        )
        buffer.frameLength = 8
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let audioBuffer = try XCTUnwrap(buffers.first)
        let samples = try XCTUnwrap(audioBuffer.mData?.assumingMemoryBound(to: Float.self))
        for index in 0..<16 {
            samples[index] = index.isMultiple(of: 2) ? 0.1 : -0.1
        }
        let meter = AudioLevelMeter()

        meter.update(buffer: buffer)

        XCTAssertEqual(meter.level, 0.506, accuracy: 0.02)
        meter.reset()
        XCTAssertEqual(meter.level, 0, accuracy: 0.0001)
    }

    func testMeterUsesFastAttackAndSlowerRelease() {
        let meter = AudioLevelMeter()

        meter.update(rootMeanSquare: 1)
        let attacked = meter.level
        meter.update(rootMeanSquare: 1e-9)
        let released = meter.level

        XCTAssertEqual(attacked, 0.62, accuracy: 0.001)
        XCTAssertEqual(released, 0.5208, accuracy: 0.001)
        XCTAssertGreaterThan(released, 0)
    }

    func testMeterIgnoresSamplesBeyondLogicalFrameLength() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)
        )
        buffer.frameLength = 8
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4 { samples[index] = 0.01 }
        for index in 4..<8 { samples[index] = 1 }
        buffer.frameLength = 4
        let meter = AudioLevelMeter()

        meter.update(buffer: buffer)

        XCTAssertEqual(meter.level, 0.358, accuracy: 0.02)
    }
}
