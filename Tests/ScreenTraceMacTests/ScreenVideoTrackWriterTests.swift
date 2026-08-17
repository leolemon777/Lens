import AVFoundation
import CoreVideo
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

final class ScreenVideoTrackWriterTests: XCTestCase {
    func testPlanarStereoSampleBufferConversionPreservesFramesAndSamples() throws {
        let frameCount: AVAudioFrameCount = 960
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        source.frameLength = frameCount
        for channel in 0..<2 {
            let samples = try XCTUnwrap(source.floatChannelData?[channel])
            for frame in 0..<Int(frameCount) {
                samples[frame] = Float(channel + 1) * 0.125 + Float(frame) / 100_000
            }
        }

        let sampleBuffer = try makeAudioSampleBuffer(from: source)
        let converted = try AudioSampleBufferPCMConverter.convert(sampleBuffer)

        XCTAssertEqual(converted.frameLength, frameCount)
        XCTAssertEqual(converted.format.channelCount, 2)
        XCTAssertFalse(converted.format.isInterleaved)
        for channel in 0..<2 {
            let expected = try XCTUnwrap(source.floatChannelData?[channel])
            let actual = try XCTUnwrap(converted.floatChannelData?[channel])
            for frame in [0, 1, 479, 959] {
                XCTAssertEqual(actual[frame], expected[frame], accuracy: 0.000_001)
            }
        }
        let meter = AudioLevelMeter()
        meter.update(sampleBuffer: sampleBuffer)
        XCTAssertGreaterThan(meter.level, 0)
    }

    func testIndependentSystemAudioWriterCanBePrepared() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("system-audio.mp4")

        let writer = try SystemAudioTrackWriter(outputURL: outputURL)

        XCTAssertEqual(SystemAudioTrackWriter.maximumPendingSampleCount, 512)
        writer.cancel()
    }

    func testSegmentedWriterAcceptsSystemAudioTrack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("system-audio.mp4")

        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: true
        )

        writer.cancel()
    }

    func testFragmentCadenceBoundsUnexpectedTerminationLoss() {
        XCTAssertEqual(ScreenVideoTrackWriter.recoverySegmentIntervalSeconds, 5)
        XCTAssertGreaterThanOrEqual(
            ScreenVideoTrackWriter.maximumPendingVideoFrameCount,
            8
        )
    }

    func testWriterPreservesRealSixtyFrameInputWithoutInventingFrames() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("sixty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        for index in 0..<120 {
            writer.appendVideoPixelBuffer(
                try makePixelBuffer(value: UInt8(index % 255)),
                sourceTime: CMTime(value: CMTimeValue(index), timescale: 60)
            )
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.finish()

        let snapshot = writer.performanceSnapshot
        XCTAssertEqual(snapshot.receivedCompleteFrameCount, 120)
        XCTAssertGreaterThanOrEqual(snapshot.writtenFrameCount, 110)
        XCTAssertEqual(snapshot.measuredReceivedFramesPerSecond ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(snapshot.isMeetingRequestedFrameRate, true)
        XCTAssertLessThanOrEqual(snapshot.p95FrameIntervalMilliseconds ?? 100, 17)

        let media = try await inspectVideo(at: outputURL)
        XCTAssertGreaterThanOrEqual(media.sampleCount, 110)
        XCTAssertEqual(media.duration, 2, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(media.measuredFramesPerSecond, 55)
    }

    func testWriterReportsThirtyFrameInputAsBelowRequestedSixty() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("thirty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        for index in 0..<30 {
            writer.appendVideoPixelBuffer(
                try makePixelBuffer(value: UInt8(index)),
                sourceTime: CMTime(value: CMTimeValue(index), timescale: 30)
            )
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.finish()

        let snapshot = writer.performanceSnapshot
        XCTAssertEqual(snapshot.receivedCompleteFrameCount, 30)
        XCTAssertEqual(snapshot.measuredReceivedFramesPerSecond ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(snapshot.isMeetingRequestedFrameRate, false)

        let media = try await inspectVideo(at: outputURL)
        XCTAssertLessThan(media.measuredFramesPerSecond, 40)
    }

    func testExplicitIdleFramesReusePixelsOnTheRequestedTimeGrid() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("idle-sixty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        writer.appendVideoPixelBuffer(
            try makePixelBuffer(value: 128),
            sourceTime: .zero
        )
        for index in 1...12 {
            writer.appendIdleFrame(at: CMTime(value: CMTimeValue(index), timescale: 12))
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.finish()

        let snapshot = writer.performanceSnapshot
        XCTAssertEqual(snapshot.receivedCompleteFrameCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.writtenFrameCount, 58)

        let media = try await inspectVideo(at: outputURL)
        XCTAssertGreaterThanOrEqual(media.sampleCount, 58)
        XCTAssertEqual(media.duration, 1, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(media.measuredFramesPerSecond, 58)
    }

    func testSingleIdleNotificationKeepsTheMediaClockAdvancing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("continuous-idle-sixty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        writer.appendVideoPixelBuffer(
            try makePixelBuffer(value: 128),
            sourceTime: .zero
        )
        writer.appendIdleFrame(at: CMTime(value: 1, timescale: 60))
        try await Task.sleep(for: .milliseconds(250))
        try await writer.finish()

        let snapshot = writer.performanceSnapshot
        XCTAssertGreaterThanOrEqual(snapshot.writtenFrameCount, 10)

        let media = try await inspectVideo(at: outputURL)
        XCTAssertGreaterThanOrEqual(media.sampleCount, 10)
        XCTAssertGreaterThanOrEqual(media.duration, 0.18)
        XCTAssertGreaterThanOrEqual(media.measuredFramesPerSecond, 58)
    }

    func testInactivityWatchdogKeepsAStaticSourceAdvancingWithoutIdleCallbacks() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("static-source-sixty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        writer.appendVideoPixelBuffer(
            try makePixelBuffer(value: 96),
            sourceTime: .zero
        )
        try await Task.sleep(for: .milliseconds(400))
        try await writer.finish()

        let media = try await inspectVideo(at: outputURL)
        XCTAssertGreaterThanOrEqual(media.sampleCount, 20)
        XCTAssertGreaterThanOrEqual(media.duration, 0.35)
        XCTAssertGreaterThanOrEqual(media.measuredFramesPerSecond, 58)
    }

    func testInactivityWatchdogDoesNotDoubleARealTimeThirtyFrameSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("realtime-thirty.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        for index in 0..<12 {
            writer.appendVideoPixelBuffer(
                try makePixelBuffer(value: UInt8(index)),
                sourceTime: CMTime(value: CMTimeValue(index), timescale: 30)
            )
            try await Task.sleep(for: .milliseconds(33))
        }
        try await writer.finish()

        let snapshot = writer.performanceSnapshot
        XCTAssertEqual(snapshot.receivedCompleteFrameCount, 12)
        XCTAssertLessThanOrEqual(snapshot.writtenFrameCount, 12)

        let media = try await inspectVideo(at: outputURL)
        XCTAssertLessThan(media.measuredFramesPerSecond, 55)
    }

    func testPreparingToFinishFreezesTheIdleClockAtTheStopRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("frozen-stop.mp4")
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )

        writer.appendVideoPixelBuffer(
            try makePixelBuffer(value: 64),
            sourceTime: .zero
        )
        try await Task.sleep(for: .milliseconds(350))
        writer.prepareToFinish()
        try await Task.sleep(for: .milliseconds(150))
        try await writer.finish()

        let media = try await inspectVideo(at: outputURL)
        XCTAssertGreaterThanOrEqual(media.duration, 0.30)
        XCTAssertLessThan(media.duration, 0.45)
        XCTAssertGreaterThanOrEqual(media.measuredFramesPerSecond, 58)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenVideoTrackWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeAudioSampleBuffer(
        from buffer: AVAudioPCMBuffer
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var optionalSampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &optionalSampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer = optionalSampleBuffer else {
            throw NSError(domain: "ScreenTraceTests", code: Int(createStatus))
        }
        let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: buffer.audioBufferList
        )
        guard copyStatus == noErr else {
            throw NSError(domain: "ScreenTraceTests", code: Int(copyStatus))
        }
        let readyStatus = CMSampleBufferSetDataReady(sampleBuffer)
        guard readyStatus == noErr else {
            throw NSError(domain: "ScreenTraceTests", code: Int(readyStatus))
        }
        return sampleBuffer
    }

    private func makePixelBuffer(value: UInt8) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            180,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw NSError(domain: "ScreenTraceTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            memset(baseAddress, Int32(value), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func inspectVideo(at url: URL) async throws -> (
        sampleCount: Int,
        duration: Double,
        measuredFramesPerSecond: Double
    ) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(sample.presentationTimeStamp.seconds)
        }
        let measured: Double
        if let first = times.first, let last = times.last, last > first {
            measured = Double(times.count - 1) / (last - first)
        } else {
            measured = 0
        }
        return (times.count, duration, measured)
    }
}
