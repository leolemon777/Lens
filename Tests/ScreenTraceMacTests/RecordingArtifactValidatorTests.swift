import AVFoundation
import CoreMedia
import CoreVideo
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

final class RecordingArtifactValidatorTests: XCTestCase {
    func testOptionalTrackInterruptionsBecomeExplicitHealthWarnings() {
        XCTAssertEqual(
            RecordingArtifactValidator.optionalTrackInterruptionWarnings(
                for: [.microphone, .camera]
            ),
            [.microphoneInterrupted, .cameraInterrupted]
        )
        XCTAssertEqual(
            RecordingArtifactValidator.optionalTrackInterruptionWarnings(
                for: [.systemAudio]
            ),
            []
        )
    }

    @MainActor
    func testSyntheticHourTimelineUsesBoundedPhysicalFrameWindows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTrace-HourTimeline-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticVideoFactory.makeVideo(
            at: url,
            frameCount: 3_601,
            framesPerSecond: 1,
            width: 16,
            height: 16
        )
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 3_600)

        let loadedMetrics = await RecordingArtifactValidator.inspectVideo(at: url)
        let metrics = try XCTUnwrap(loadedMetrics)

        // This fixture intentionally uses an extreme 1 FPS H.264 timeline;
        // encoder GOP boundary samples can vary, but the bounded verifier must
        // still produce a finite pacing result without scanning 3,601 frames.
        XCTAssertGreaterThan(metrics.measuredFramesPerSecond ?? 0, 0.8)
        XCTAssertLessThan(metrics.measuredFramesPerSecond ?? 0, 1.5)
        XCTAssertGreaterThanOrEqual(metrics.sampleCount, 10)
        XCTAssertLessThanOrEqual(metrics.sampleCount, 20)
    }

    @MainActor
    func testTrackIntegrityReadsPhysicalMediaAndDetectsCameraDrift() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTrackIntegrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(
            width: 320,
            height: 180,
            includesSystemAudio: true,
            includesMicrophone: true,
            includesCamera: true
        )
        let silentVideoURL = session.packageURL.appendingPathComponent("raw/video-only.mp4")
        let systemAudioURL = session.packageURL.appendingPathComponent("raw/system.caf")
        try await SyntheticVideoFactory.makeVideo(
            at: silentVideoURL,
            frameCount: 60,
            framesPerSecond: 30
        )
        try makeAudio(at: systemAudioURL, frameCount: 96_000)
        try await mux(
            videoURL: silentVideoURL,
            audioURL: systemAudioURL,
            outputURL: session.videoURL
        )
        try makeAudio(at: try XCTUnwrap(session.microphoneURL), frameCount: 96_000)
        try await SyntheticVideoFactory.makeVideo(
            at: try XCTUnwrap(session.cameraURL),
            frameCount: 45,
            framesPerSecond: 30
        )

        let integrity = await RecordingArtifactValidator.inspectTrackIntegrity(
            session: session
        )

        XCTAssertTrue(integrity.missingRequestedTracks.isEmpty)
        XCTAssertEqual(integrity.outOfSyncTracks, [.camera])
        XCTAssertEqual(integrity.screenVideoDurationSeconds ?? 0, 2, accuracy: 0.06)
        XCTAssertEqual(integrity.systemAudioDurationSeconds ?? 0, 2, accuracy: 0.06)
        XCTAssertEqual(integrity.microphoneDurationSeconds ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(integrity.cameraDurationSeconds ?? 0, 1.5, accuracy: 0.06)
        XCTAssertFalse(integrity.isVerified)

        try FileManager.default.removeItem(at: try XCTUnwrap(session.microphoneURL))
        let missing = await RecordingArtifactValidator.inspectTrackIntegrity(
            session: session
        )
        XCTAssertEqual(missing.missingRequestedTracks, [.microphone])
    }

    func testValidatorReportsActualFrameRateAndOnlyCompletedSmartEffects() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingArtifactValidator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let source = RecordingCaptureSource(
            mode: .display,
            displayID: 1,
            captureBounds: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        let session = try store.beginRecording(
            width: 320,
            height: 180,
            captureSource: TraceCaptureMetadata(
                recordingSource: source,
                framesPerSecond: 60
            )
        )
        let writer = try ScreenVideoTrackWriter(
            outputURL: session.videoURL,
            dimensions: TraceDimensions(width: 320, height: 180),
            framesPerSecond: 60,
            capturesSystemAudio: false
        )
        for index in 0..<60 {
            writer.appendVideoPixelBuffer(
                try makePixelBuffer(value: UInt8(index)),
                sourceTime: CMTime(value: CMTimeValue(index), timescale: 30)
            )
            try await Task.sleep(for: .milliseconds(1))
        }
        try await writer.finish()

        let pointerWriter = try JSONLinesWriter<PointerEvent>(url: session.pointerEventsURL)
        try await pointerWriter.append(PointerEvent(
            time: 0.1,
            kind: .moved,
            location: TracePoint(x: 80, y: 90),
            normalizedLocation: TracePoint(x: 0.25, y: 0.5),
            displayID: nil
        ))
        try await pointerWriter.append(PointerEvent(
            time: 0.2,
            kind: .moved,
            location: TracePoint(x: 160, y: 90),
            normalizedLocation: TracePoint(x: 0.5, y: 0.5),
            displayID: nil
        ))
        try await pointerWriter.close()
        let clickWriter = try JSONLinesWriter<ClickEvent>(url: session.clickEventsURL)
        try await clickWriter.append(ClickEvent(
            time: 0.25,
            button: .left,
            phase: .down,
            location: TracePoint(x: 160, y: 90),
            normalizedLocation: TracePoint(x: 0.5, y: 0.5),
            clickCount: 1
        ))
        try await clickWriter.close()
        _ = try store.writeAutoEditPlan(for: session, durationSeconds: 2)
        _ = try store.finalizeRecording(session, durationSeconds: 2)

        let report = await RecordingArtifactValidator(store: store).validate(
            session: session,
            requestedFramesPerSecond: 60,
            eventSnapshot: EventCaptureSnapshot(
                health: .healthy(pointerCount: 2, clickCount: 1),
                pointerCount: 2,
                clickCount: 1,
                keyboardCount: 0,
                windowCount: 0,
                lastEventUptime: 1
            ),
            capturePerformance: writer.performanceSnapshot
        )

        XCTAssertEqual(report.videoStatus, .degraded)
        XCTAssertGreaterThan(report.measuredFramesPerSecond ?? 0, 10)
        XCTAssertLessThan(report.measuredFramesPerSecond ?? 0, 40)
        XCTAssertTrue(report.warnings.contains(.measuredFrameRateBelowRequest))
        XCTAssertEqual(report.eventStatus, .healthy)
        XCTAssertEqual(report.pointerEventCount, 2)
        XCTAssertEqual(report.clickEventCount, 1)
        XCTAssertGreaterThan(report.effectiveCameraKeyframeCount, 0)
        XCTAssertGreaterThan(report.cursorKeyframeCount, 0)
        XCTAssertEqual(report.clickPulseCount, 1)
        XCTAssertNotNil(report.cameraMotionComfort)
        XCTAssertTrue(report.cameraMotionComfort?.isComfortable == true)
        XCTAssertEqual(report.completedSmartEffects, ["自动运镜", "平滑光标", "点击反馈"])
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

    private func makeAudio(at url: URL, frameCount: AVAudioFrameCount) throws {
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
