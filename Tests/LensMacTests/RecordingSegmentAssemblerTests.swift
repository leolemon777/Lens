import AVFoundation
import XCTest
@testable import LensCore
@testable import LensMac

final class RecordingSegmentAssemblerTests: XCTestCase {
    @MainActor
    func testVideoAndIndependentSystemAudioRemuxIntoOnePhysicalMP4() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("screen.mp4")
        let audioURL = directory.appendingPathComponent("system-audio.caf")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 24,
            framesPerSecond: 24
        )
        try makeAudio(
            at: audioURL,
            frameCount: 48_000,
            phaseOffset: 0
        )

        let output = try await RecordingSegmentAssembler().muxSystemAudio(
            videoURL: videoURL,
            audioURL: audioURL
        )

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let outputDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(outputDuration, 1, accuracy: 0.05)
        XCTAssertGreaterThan(fileSize(at: output), 1_000)
    }

    @MainActor
    func testRecoveryMuxTrimsVideoToDurableSystemAudioPrefix() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("screen.mp4")
        let audioURL = directory.appendingPathComponent("system-audio.caf")
        try await SyntheticVideoFactory.makeVideo(
            at: videoURL,
            frameCount: 48,
            framesPerSecond: 24
        )
        try makeAudio(
            at: audioURL,
            frameCount: 48_000,
            phaseOffset: 0
        )

        let output = try await RecordingSegmentAssembler().muxSystemAudio(
            videoURL: videoURL,
            audioURL: audioURL,
            trimVideoToAudio: true
        )

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let videoDuration = videoRange.duration.seconds
        let audioDuration = audioRange.duration.seconds
        XCTAssertEqual(videoDuration, 1, accuracy: 0.05)
        XCTAssertEqual(audioDuration, 1, accuracy: 0.05)
        XCTAssertEqual(videoDuration, audioDuration, accuracy: 0.01)
    }

    @MainActor
    func testVideoSegmentsJoinInOrderWithoutReencodingContractBreakage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("screen.mp4")
        let second = directory.appendingPathComponent("screen-001.mp4")
        try await SyntheticVideoFactory.makeVideo(at: first, frameCount: 12, framesPerSecond: 24)
        try await SyntheticVideoFactory.makeVideo(at: second, frameCount: 18, framesPerSecond: 24)
        let firstDuration = try await duration(of: first)
        let secondDuration = try await duration(of: second)
        let expectedDuration = firstDuration + secondDuration

        let output = try await RecordingSegmentAssembler().assembleVideoSegments(
            [first, second],
            outputURL: first,
            fileType: .mp4
        )

        XCTAssertEqual(output, first)
        let outputTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let outputDuration = try await duration(of: output)
        XCTAssertEqual(outputTracks.count, 1)
        XCTAssertEqual(outputDuration, expectedDuration, accuracy: 0.05)
        XCTAssertGreaterThan(fileSize(at: output), 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testMicrophoneSegmentsJoinIntoOnePhysicalCAFTrack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("microphone.caf")
        let second = directory.appendingPathComponent("microphone-001.caf")
        try makeAudio(at: first, frameCount: 2_400, phaseOffset: 0)
        try makeAudio(at: second, frameCount: 3_600, phaseOffset: 2_400)

        let output = try RecordingSegmentAssembler().assembleAudioSegments(
            [first, second],
            outputURL: first
        )

        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, 6_000)
        XCTAssertEqual(audio.processingFormat.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(fileSize(at: output), 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testRecoveryAudioKeepsValidPrefixWhenFinalCAFIsCorrupt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("system-audio-00000.caf")
        let second = directory.appendingPathComponent("system-audio-00001.caf")
        let corrupt = directory.appendingPathComponent("system-audio-00002.caf")
        try makeAudio(at: first, frameCount: 2_400, phaseOffset: 0)
        try makeAudio(at: second, frameCount: 3_600, phaseOffset: 2_400)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: corrupt.path,
            contents: Data(repeating: 0xA5, count: 16_384)
        ))

        let output = try RecordingSegmentAssembler().assembleAudioSegments(
            [first, second, corrupt],
            outputURL: first,
            allowsTrailingCorruption: true
        )

        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, 6_000)
        XCTAssertGreaterThan(fileSize(at: output), 1_000)
    }

    @MainActor
    func testMicrophoneSegmentsAreTrimmedToMatchingScreenDurations() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("microphone.caf")
        let second = directory.appendingPathComponent("microphone-001.caf")
        try makeAudio(at: first, frameCount: 4_800, phaseOffset: 0)
        try makeAudio(at: second, frameCount: 4_800, phaseOffset: 4_800)

        let output = try RecordingSegmentAssembler().assembleAudioSegments(
            [first, second],
            outputURL: first,
            maximumDurations: [0.025, 0.05]
        )

        let audio = try AVAudioFile(forReading: output)
        XCTAssertEqual(audio.length, 3_600)
    }

    @MainActor
    func testVideoSegmentsAreTrimmedToMatchingScreenDurations() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("camera.mov")
        let second = directory.appendingPathComponent("camera-001.mov")
        try await SyntheticVideoFactory.makeVideo(at: first, frameCount: 24, framesPerSecond: 24)
        try await SyntheticVideoFactory.makeVideo(at: second, frameCount: 24, framesPerSecond: 24)

        let output = try await RecordingSegmentAssembler().assembleVideoSegments(
            [first, second],
            outputURL: first,
            fileType: .mov,
            maximumDurations: [0.25, 0.5]
        )

        let outputDuration = try await duration(of: output)
        XCTAssertEqual(outputDuration, 0.75, accuracy: 0.06)
    }

    @MainActor
    func testSingleResumedVideoCanRestoreMissingPrimaryOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resumed = directory.appendingPathComponent("screen-001.mp4")
        let primary = directory.appendingPathComponent("screen.mp4")
        try await SyntheticVideoFactory.makeVideo(at: resumed, frameCount: 12, framesPerSecond: 24)

        let output = try await RecordingSegmentAssembler().assembleVideoSegments(
            [resumed],
            outputURL: primary,
            fileType: .mp4
        )

        XCTAssertEqual(output, primary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumed.path))
        let primaryDuration = try await duration(of: primary)
        let resumedDuration = try await duration(of: resumed)
        XCTAssertEqual(primaryDuration, resumedDuration, accuracy: 0.01)
    }

    @MainActor
    func testFirstSegmentIsArchivedBeforePrimaryBecomesJoinedOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensArchiveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 640, height: 360)
        try await SyntheticVideoFactory.makeVideo(
            at: session.videoURL,
            frameCount: 12,
            framesPerSecond: 24
        )
        let segmentsDirectory = session.packageURL
            .appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        let secondURL = segmentsDirectory.appendingPathComponent("screen-001.mp4")
        try await SyntheticVideoFactory.makeVideo(at: secondURL, frameCount: 18, framesPerSecond: 24)
        let firstDuration = try await duration(of: session.videoURL)
        let secondDuration = try await duration(of: secondURL)
        _ = try store.completeRecordingSegment(index: 0, durationSeconds: firstDuration, in: session)
        try store.appendRecordingSegment(
            RecordingSegment(
                index: 1,
                timelineStartSeconds: firstDuration,
                durationSeconds: secondDuration,
                screenRelativePath: "raw/segments/screen-001.mp4"
            ),
            to: session
        )

        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )
        let originalSegments = try store.loadRecordingSegmentIndex(
            from: session.packageURL
        ).segments
        let archivedSegments = try service.archiveFirstSegmentsIfNeeded(
            originalSegments,
            session: session
        )
        let archivedFirst = try XCTUnwrap(archivedSegments.first { $0.index == 0 })
        let archivedFirstURL = session.packageURL
            .appendingPathComponent(archivedFirst.screenRelativePath)
        let archivedDurationBeforeJoin = try await duration(of: archivedFirstURL)
        let primaryDurationBeforeJoin = try await duration(of: session.videoURL)

        XCTAssertEqual(archivedFirst.screenRelativePath, "raw/segments/screen-000.mp4")
        XCTAssertEqual(archivedDurationBeforeJoin, firstDuration, accuracy: 0.01)
        XCTAssertEqual(primaryDurationBeforeJoin, firstDuration, accuracy: 0.01)

        _ = try await RecordingSegmentAssembler().assembleVideoSegments(
            archivedSegments.map {
                session.packageURL.appendingPathComponent($0.screenRelativePath)
            },
            outputURL: session.videoURL,
            fileType: .mp4
        )
        let joinedDuration = try await duration(of: session.videoURL)
        let archivedDurationAfterJoin = try await duration(of: archivedFirstURL)
        XCTAssertEqual(joinedDuration, firstDuration + secondDuration, accuracy: 0.05)
        XCTAssertEqual(archivedDurationAfterJoin, firstDuration, accuracy: 0.01)
        XCTAssertEqual(
            try store.loadRecordingSegmentIndex(from: session.packageURL)
                .segments.first(where: { $0.index == 0 })?.screenRelativePath,
            "raw/segments/screen-000.mp4"
        )
    }

    @MainActor
    func testPlayableInterruptedSegmentIsRecoveredBeforeFinalization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensFinalizationRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 640, height: 360)
        try await SyntheticVideoFactory.makeVideo(
            at: session.videoURL,
            frameCount: 12,
            framesPerSecond: 24
        )
        let firstDuration = try await duration(of: session.videoURL)
        _ = try store.completeRecordingSegment(
            index: 0,
            durationSeconds: firstDuration,
            in: session
        )
        let resumedURL = session.packageURL
            .appendingPathComponent("raw/segments/screen-001.mp4")
        try FileManager.default.createDirectory(
            at: resumedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await SyntheticVideoFactory.makeVideo(
            at: resumedURL,
            frameCount: 18,
            framesPerSecond: 24
        )
        try store.appendRecordingSegment(
            RecordingSegment(
                index: 1,
                timelineStartSeconds: firstDuration,
                screenRelativePath: "raw/segments/screen-001.mp4"
            ),
            to: session
        )
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )
        let index = try store.loadRecordingSegmentIndex(from: session.packageURL)

        let recovered = try await service.finalizableSegments(
            from: index,
            session: session
        )
        let resumedDuration = try await duration(of: resumedURL)

        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(recovered[0].durationSeconds),
            firstDuration,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(recovered[1].durationSeconds),
            resumedDuration,
            accuracy: 0.01
        )
        XCTAssertNotNil(
            try store.loadRecordingSegmentIndex(from: session.packageURL)
                .segments.first(where: { $0.index == 1 })?.durationSeconds
        )
    }

    @MainActor
    func testInterruptedSegmentsRecoverIntoProcessableJoinedRecording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 640, height: 360)
        try await SyntheticVideoFactory.makeVideo(
            at: session.videoURL,
            frameCount: 12,
            framesPerSecond: 24
        )
        let segmentsDirectory = session.packageURL
            .appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: segmentsDirectory,
            withIntermediateDirectories: true
        )
        let resumedURL = segmentsDirectory.appendingPathComponent("screen-001.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: resumedURL,
            frameCount: 18,
            framesPerSecond: 24
        )
        try store.appendRecordingSegment(
            RecordingSegment(
                index: 1,
                timelineStartSeconds: 0.5,
                screenRelativePath: "raw/segments/screen-001.mp4"
            ),
            to: session
        )
        try store.markRecordingInterrupted(session)
        let interruptedManifest = try store.loadManifest(from: session.packageURL)
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )

        let saved = try await service.recoverInterruptedRecording(
            RecordingRecoveryCandidate(
                packageURL: session.packageURL,
                videoURL: session.videoURL,
                manifest: interruptedManifest
            )
        )

        let recoveredManifest = try store.loadManifest(from: session.packageURL)
        let recoveredIndex = try store.loadRecordingSegmentIndex(from: session.packageURL)
        let joinedDuration = try await duration(of: session.videoURL)
        XCTAssertEqual(saved.manifest.state, .processing)
        XCTAssertEqual(recoveredManifest.state, .processing)
        XCTAssertEqual(recoveredIndex.segments.count, 2)
        XCTAssertTrue(recoveredIndex.segments.allSatisfy { ($0.durationSeconds ?? 0) > 0 })
        XCTAssertEqual(
            recoveredIndex.segments.first?.screenRelativePath,
            "raw/segments/screen-000.mp4"
        )
        XCTAssertEqual(joinedDuration, recoveredManifest.durationSeconds ?? 0, accuracy: 0.05)
        XCTAssertGreaterThan(joinedDuration, 1.1)
        XCTAssertNotNil(try store.loadAutoEditPlan(from: session.packageURL).timeline)
    }

    @MainActor
    func testMissingScreenMediaIsQuarantinedAfterOneRecoveryAttempt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensMissingRecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 640, height: 360)
        try store.markRecordingInterrupted(session)
        let candidate = try XCTUnwrap(
            store.interruptedRecordingCandidates().first
        )
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )

        do {
            _ = try await service.recoverInterruptedRecording(candidate)
            XCTFail("Missing screen media must not report a successful recovery")
        } catch {
            guard case ScreenRecordingError.recordingDidNotFinalize = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }

        XCTAssertEqual(
            try store.loadManifest(from: session.packageURL).state,
            .failed
        )
        XCTAssertTrue(store.interruptedRecordingCandidates().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.packageURL.path))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensSegmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
    }

    private func makeAudio(at url: URL, frameCount: AVAudioFrameCount, phaseOffset: Int) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            channel[index] = sin(Float(index + phaseOffset) * 0.04) * 0.18
        }
        var writer: MicrophoneFileWriter? = try MicrophoneFileWriter(
            file: AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        )
        writer?.write(buffer)
        XCTAssertNil(writer?.failure)
        writer = nil
    }
}
