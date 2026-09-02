import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import LensCore
import UniformTypeIdentifiers

private final class UncheckedSendableMediaReference<Value: AnyObject>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class RecoveryMovieSegmentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var storedFailure: Error?

    init(outputURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ScreenVideoTrackWriterError.unableToStartWriting(
                "output already exists"
            )
        }
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ) else {
            throw ScreenVideoTrackWriterError.unableToStartWriting(
                "unable to create fragmented output"
            )
        }
        fileHandle = try FileHandle(forWritingTo: outputURL)
    }

    func append(_ data: Data) {
        lock.withLock {
            guard storedFailure == nil, let fileHandle else { return }
            var fragmentStartOffset: UInt64?
            do {
                fragmentStartOffset = try fileHandle.offset()
                try fileHandle.write(contentsOf: data)
                // A delivered segment is recovery evidence only after it has
                // crossed the process boundary into the filesystem.
                try fileHandle.synchronize()
            } catch {
                // FileHandle may have persisted only a prefix before ENOSPC.
                // A partial moof/mdat tail makes every earlier durable HLS
                // fragment unreadable to AVFoundation, so roll the file back
                // to the last complete fragment boundary before surfacing the
                // original failure.
                if let fragmentStartOffset {
                    try? fileHandle.truncate(atOffset: fragmentStartOffset)
                    try? fileHandle.seek(toOffset: fragmentStartOffset)
                    try? fileHandle.synchronize()
                }
                storedFailure = error
            }
        }
    }

    func finish() throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            guard let fileHandle else { return }
            try fileHandle.synchronize()
            try fileHandle.close()
            self.fileHandle = nil
        }
    }

    func cancel() {
        lock.withLock {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}

enum ScreenVideoTrackWriterError: LocalizedError {
    case unableToCreateWriterInput
    case unableToStartWriting(String)
    case noVideoFrames
    case appendFailed(String)
    case finishFailed(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreateWriterInput:
            "无法创建屏幕录制编码轨。"
        case let .unableToStartWriting(detail):
            "无法启动屏幕录制编码：\(detail)"
        case .noVideoFrames:
            "录制期间没有收到完整的屏幕帧。"
        case let .appendFailed(detail):
            "写入屏幕帧失败：\(detail)"
        case let .finishFailed(detail):
            "无法完成屏幕录制文件：\(detail)"
        }
    }
}

struct CapturePerformanceSnapshot: Equatable, Sendable {
    let requestedFramesPerSecond: Int
    let receivedCompleteFrameCount: Int
    let writtenFrameCount: Int
    let droppedFrameCount: Int
    let measuredReceivedFramesPerSecond: Double?
    let measuredWrittenFramesPerSecond: Double?
    let p95FrameIntervalMilliseconds: Double?

    var isMeetingRequestedFrameRate: Bool? {
        guard let measured = measuredWrittenFramesPerSecond
            ?? measuredReceivedFramesPerSecond else { return nil }
        let threshold = requestedFramesPerSecond >= 60
            ? 58.0
            : Double(requestedFramesPerSecond) * 0.95
        return measured >= threshold
    }
}

private final class CapturePerformanceAccumulator: @unchecked Sendable {
    /// Roughly the most recent minute at 60 FPS. Keeping this window bounded
    /// prevents the floating HUD's health readout from sorting an ever-growing
    /// recording history while the encoder is trying to append a frame.
    private static let maximumRecentIntervals = 4_096

    private let lock = NSLock()
    private let requestedFramesPerSecond: Int
    private var receivedFrameCount = 0
    private var writtenFrameCount = 0
    private var firstReceivedTime: Double?
    private var lastReceivedTime: Double?
    private var firstWrittenTime: Double?
    private var lastWrittenTime: Double?
    private var recentReceivedIntervals: [Double] = []
    private var nextIntervalReplacementIndex = 0
    private var droppedFrameCount = 0

    init(requestedFramesPerSecond: Int) {
        self.requestedFramesPerSecond = max(requestedFramesPerSecond, 1)
    }

    func recordReceived(at time: CMTime) {
        guard time.isNumeric, time.seconds.isFinite else { return }
        lock.withLock {
            let seconds = time.seconds
            if firstReceivedTime == nil { firstReceivedTime = seconds }
            if let lastReceivedTime {
                let interval = seconds - lastReceivedTime
                if interval.isFinite, interval >= 0 {
                    appendRecentInterval(interval)
                }
            }
            lastReceivedTime = seconds
            receivedFrameCount += 1
        }
    }

    func recordWritten(at time: CMTime) {
        guard time.isNumeric, time.seconds.isFinite else { return }
        lock.withLock {
            let seconds = time.seconds
            if firstWrittenTime == nil { firstWrittenTime = seconds }
            lastWrittenTime = seconds
            writtenFrameCount += 1
        }
    }

    func recordDroppedFrame() {
        lock.withLock { droppedFrameCount += 1 }
    }

    func snapshot() -> CapturePerformanceSnapshot {
        let state = lock.withLock {
            (
                receivedFrameCount,
                writtenFrameCount,
                droppedFrameCount,
                firstReceivedTime,
                lastReceivedTime,
                firstWrittenTime,
                lastWrittenTime,
                recentReceivedIntervals
            )
        }
        return CapturePerformanceSnapshot(
            requestedFramesPerSecond: requestedFramesPerSecond,
            receivedCompleteFrameCount: state.0,
            writtenFrameCount: state.1,
            droppedFrameCount: state.2,
            measuredReceivedFramesPerSecond: Self.measuredFPS(
                count: state.0,
                first: state.3,
                last: state.4
            ),
            measuredWrittenFramesPerSecond: Self.measuredFPS(
                count: state.1,
                first: state.5,
                last: state.6
            ),
            p95FrameIntervalMilliseconds: Self.percentile(state.7, fraction: 0.95)
                .map { $0 * 1_000 }
        )
    }

    private func appendRecentInterval(_ interval: Double) {
        if recentReceivedIntervals.count < Self.maximumRecentIntervals {
            recentReceivedIntervals.append(interval)
            return
        }
        recentReceivedIntervals[nextIntervalReplacementIndex] = interval
        nextIntervalReplacementIndex = (
            nextIntervalReplacementIndex + 1
        ) % Self.maximumRecentIntervals
    }

    private static func measuredFPS(
        count: Int,
        first: Double?,
        last: Double?
    ) -> Double? {
        guard count >= 2,
              let first,
              let last,
              last > first else { return nil }
        return Double(count - 1) / (last - first)
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(
            (Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded(.up)
        )
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

final class ScreenVideoTrackWriter: NSObject, SCStreamOutput, AVAssetWriterDelegate,
    @unchecked Sendable {
    /// ScreenCaptureKit itself is configured with queueDepth 8. Retaining more
    /// full-resolution pixel buffers here during an encoder stall only turns a
    /// recoverable dropped frame into unbounded memory growth on long sessions.
    static let maximumPendingVideoFrameCount = 8
    static let maximumPendingAudioSampleCount = 512
    static let recoverySegmentIntervalSeconds = 5.0

    static func recoverySystemAudioURL(for videoURL: URL) -> URL {
        videoURL.deletingLastPathComponent().appendingPathComponent(
            "\(videoURL.deletingPathExtension().lastPathComponent).system-audio.caf"
        )
    }

    let outputQueue: DispatchQueue

    private struct PendingVideoFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    private let writer: AVAssetWriter
    private let videoSegmentSink: RecoveryMovieSegmentSink
    private let audioSegmentSink: RecoveryMovieSegmentSink?
    private let videoInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let targetFramesPerSecond: Int
    private let audioLevelMeter: AudioLevelMeter?
    private let performance: CapturePerformanceAccumulator
    private let outputQueueKey = DispatchSpecificKey<Void>()
    private var hasStartedSession = false
    private var firstVideoTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastWrittenVideoTime: CMTime?
    private var nextIdleFillTime: CMTime?
    private var latestCompletePixelBuffer: CVPixelBuffer?
    private var isSourceIdle = false
    private var idleTickGeneration = 0
    private var completeFrameGeneration = 0
    private var isAcceptingVideoFrames = true
    private var pendingVideoFrames: [PendingVideoFrame] = []
    private var pendingVideoFrameIndex = 0
    private var pendingAudioSamples: [CMSampleBuffer] = []
    private var pendingAudioSampleIndex = 0
    private var lastScheduledVideoTime: CMTime?
    private var drainRetryScheduled = false
    private var audioDrainRetryScheduled = false
    private var storedFailure: Error?
    private var isFinishing = false

    init(
        outputURL: URL,
        dimensions: LensDimensions,
        framesPerSecond: Int,
        capturesSystemAudio: Bool,
        audioLevelMeter: AudioLevelMeter? = nil
    ) throws {
        let framesPerSecond = max(framesPerSecond, 1)
        targetFramesPerSecond = framesPerSecond
        self.audioLevelMeter = audioLevelMeter
        performance = CapturePerformanceAccumulator(
            requestedFramesPerSecond: framesPerSecond
        )
        outputQueue = DispatchQueue(
            label: "app.lens.screen-writer.\(UUID().uuidString)",
            qos: .userInteractive
        )
        outputQueue.setSpecific(key: outputQueueKey, value: ())
        videoSegmentSink = try RecoveryMovieSegmentSink(outputURL: outputURL)
        do {
            audioSegmentSink = capturesSystemAudio
                ? try RecoveryMovieSegmentSink(
                    outputURL: Self.recoverySystemAudioURL(for: outputURL)
                )
                : nil
        } catch {
            videoSegmentSink.cancel()
            throw error
        }
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: Self.recoverySegmentIntervalSeconds,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = .zero

        let pixelCount = max(dimensions.width * dimensions.height, 1)
        let averageBitRate = min(
            max(Int(Double(pixelCount * framesPerSecond) * 0.08), 4_000_000),
            30_000_000
        )
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: averageBitRate,
                    AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenVideoTrackWriterError.unableToCreateWriterInput
        }
        writer.add(videoInput)
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        if capturesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScreenVideoTrackWriterError.unableToCreateWriterInput
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        super.init()
        writer.delegate = self
        guard writer.startWriting() else {
            videoSegmentSink.cancel()
            audioSegmentSink?.cancel()
            let detail: String
            if let error = writer.error as NSError? {
                detail = "\(error.domain) \(error.code): \(error.userInfo)"
            } else {
                detail = "unknown"
            }
            throw ScreenVideoTrackWriterError.unableToStartWriting(
                detail
            )
        }
    }

    var performanceSnapshot: CapturePerformanceSnapshot {
        performance.snapshot()
    }

    var retainedVideoFrameReferenceCount: Int {
        if DispatchQueue.getSpecific(key: outputQueueKey) != nil {
            return pendingVideoFrames.count
        }
        return outputQueue.sync { pendingVideoFrames.count }
    }

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let mediaTypes = segmentReport?.trackReports.map(\.mediaType) ?? []
        let containsVideo = mediaTypes.contains(.video)
        let containsAudio = mediaTypes.contains(.audio)
        if containsAudio, !containsVideo, let audioSegmentSink {
            audioSegmentSink.append(segmentData)
        } else {
            // Apple HLS normally emits one initialization/media sequence per
            // track. A future muxed or report-less sequence remains a valid
            // primary video artifact instead of being silently discarded.
            videoSegmentSink.append(segmentData)
        }
    }

    /// Call immediately before stopping ScreenCaptureKit. This freezes the
    /// idle-frame clock at the user's stop instant instead of allowing writer
    /// finalization and encoder drain time to extend the visible recording.
    func prepareToFinish() {
        outputQueue.async { [self] in
            isAcceptingVideoFrames = false
            isSourceIdle = false
            idleTickGeneration &+= 1
            completeFrameGeneration &+= 1
        }
    }

    /// Safe to call from the shared SCK output queue or hop onto it.
    func synchronizedFirstVideoTime() -> CMTime? {
        if DispatchQueue.getSpecific(key: outputQueueKey) != nil {
            return firstVideoTime
        }
        return outputQueue.sync { firstVideoTime }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, !isFinishing else { return }
        switch type {
        case .screen:
            switch Self.screenFrameStatus(sampleBuffer) {
            case .idle:
                appendIdleFrame(at: sampleBuffer.presentationTimeStamp)
            case .complete, nil:
                guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
                appendVideoPixelBuffer(
                    pixelBuffer,
                    sourceTime: sampleBuffer.presentationTimeStamp
                )
            default:
                break
            }
        case .audio:
            appendAudioSampleBuffer(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, sourceTime: CMTime) {
        guard DispatchQueue.getSpecific(key: outputQueueKey) != nil else {
            let transferableBuffer = UncheckedSendableMediaReference(pixelBuffer)
            outputQueue.async { [self] in
                appendVideoPixelBuffer(
                    transferableBuffer.value,
                    sourceTime: sourceTime
                )
            }
            return
        }
        guard !isFinishing,
              isAcceptingVideoFrames,
              storedFailure == nil,
              sourceTime.isNumeric else { return }
        isSourceIdle = false
        idleTickGeneration &+= 1
        completeFrameGeneration &+= 1
        let generation = completeFrameGeneration
        performance.recordReceived(at: sourceTime)
        if let lastVideoTime, sourceTime <= lastVideoTime {
            performance.recordDroppedFrame()
            return
        }
        if !hasStartedSession {
            writer.startSession(atSourceTime: sourceTime)
            firstVideoTime = sourceTime
            hasStartedSession = true
        }
        lastVideoTime = sourceTime
        latestCompletePixelBuffer = pixelBuffer
        append(pixelBuffer, at: sourceTime)
        nextIdleFillTime = sourceTime + frameInterval
        scheduleInactivityWatchdog(generation: generation)
    }

    /// ScreenCaptureKit reports unchanged frames as `.idle` instead of sending
    /// another complete pixel buffer. Reusing the last known pixels for those
    /// explicit idle intervals keeps a genuinely constant media clock without
    /// disguising a dynamic 30 FPS source as 60 FPS.
    func appendIdleFrame(at sourceTime: CMTime) {
        guard DispatchQueue.getSpecific(key: outputQueueKey) != nil else {
            outputQueue.async { [self] in appendIdleFrame(at: sourceTime) }
            return
        }
        guard !isFinishing,
              isAcceptingVideoFrames,
              storedFailure == nil,
              sourceTime.isNumeric,
              hasStartedSession,
              let latestCompletePixelBuffer,
              var scheduledTime = nextIdleFillTime else { return }
        if let lastVideoTime, sourceTime <= lastVideoTime { return }
        lastVideoTime = sourceTime
        isSourceIdle = true
        completeFrameGeneration &+= 1
        idleTickGeneration &+= 1
        let generation = idleTickGeneration
        let tolerance = CMTimeMultiplyByRatio(
            frameInterval,
            multiplier: 1,
            divisor: 2
        )
        while scheduledTime <= sourceTime + tolerance {
            appendIdlePixelBuffer(latestCompletePixelBuffer, at: scheduledTime)
            scheduledTime = scheduledTime + frameInterval
        }
        nextIdleFillTime = scheduledTime
        scheduleIdleTick(generation: generation)
    }

    /// Some ScreenCaptureKit sources stop callbacks after their last complete
    /// frame without delivering a reusable `.idle` sample. A conservative
    /// watchdog distinguishes that case from ordinary 30/60 FPS delivery and
    /// advances the clock only after 250 ms of genuine inactivity.
    private func scheduleInactivityWatchdog(generation: Int) {
        let idleThresholdNanoseconds = 250_000_000
        outputQueue.asyncAfter(
            deadline: .now() + .nanoseconds(idleThresholdNanoseconds)
        ) { [self] in
            guard !isFinishing,
                  isAcceptingVideoFrames,
                  storedFailure == nil,
                  !isSourceIdle,
                  completeFrameGeneration == generation,
                  let latestCompletePixelBuffer,
                  var scheduledTime = nextIdleFillTime else { return }
            isSourceIdle = true
            idleTickGeneration &+= 1
            let idleGeneration = idleTickGeneration
            let backfillCount = max(
                1,
                (idleThresholdNanoseconds * targetFramesPerSecond) / 1_000_000_000
            )
            for _ in 0..<backfillCount {
                appendIdlePixelBuffer(latestCompletePixelBuffer, at: scheduledTime)
                scheduledTime = scheduledTime + frameInterval
            }
            nextIdleFillTime = scheduledTime
            scheduleIdleTick(generation: idleGeneration)
        }
    }

    /// ScreenCaptureKit can emit a single `.idle` notification and then stop
    /// producing callbacks until pixels change again. Keep the media clock
    /// advancing only while that explicit idle state remains active.
    private func scheduleIdleTick(
        generation: Int,
        deadline: DispatchTime? = nil
    ) {
        let nanoseconds = max(1, 1_000_000_000 / targetFramesPerSecond)
        let scheduledDeadline = deadline ?? (.now() + .nanoseconds(nanoseconds))
        outputQueue.asyncAfter(deadline: scheduledDeadline) { [self] in
            guard !isFinishing,
                  storedFailure == nil,
                  isSourceIdle,
                  idleTickGeneration == generation,
                  let latestCompletePixelBuffer,
                  let scheduledTime = nextIdleFillTime else { return }
            appendIdlePixelBuffer(latestCompletePixelBuffer, at: scheduledTime)
            nextIdleFillTime = scheduledTime + frameInterval
            scheduleIdleTick(
                generation: generation,
                deadline: scheduledDeadline + .nanoseconds(nanoseconds)
            )
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard DispatchQueue.getSpecific(key: outputQueueKey) != nil else {
            let transferableBuffer = UncheckedSendableMediaReference(sampleBuffer)
            outputQueue.async { [self] in
                appendAudioSampleBuffer(transferableBuffer.value)
            }
            return
        }
        guard !isFinishing,
              isAcceptingVideoFrames,
              storedFailure == nil,
              hasStartedSession,
              let firstVideoTime,
              sampleBuffer.presentationTimeStamp >= firstVideoTime,
              let audioInput else { return }
        audioLevelMeter?.update(sampleBuffer: sampleBuffer)
        compactPendingAudioSamplesIfNeeded()
        guard pendingAudioSamples.count - pendingAudioSampleIndex
                < Self.maximumPendingAudioSampleCount else {
            storedFailure = ScreenVideoTrackWriterError.appendFailed(
                "system audio encoder backpressure exceeded"
            )
            return
        }
        pendingAudioSamples.append(sampleBuffer)
        drainPendingAudioSamples(input: audioInput)
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            outputQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(
                        throwing: ScreenVideoTrackWriterError.finishFailed("already finishing")
                    )
                    return
                }
                isFinishing = true
                if let storedFailure {
                    writer.cancelWriting()
                    cancelSegmentSinks()
                    continuation.resume(throwing: storedFailure)
                    return
                }
                finishWhenVideoQueueDrains(continuation)
            }
        }
    }

    func cancel() {
        outputQueue.async { [self] in
            guard !isFinishing else { return }
            isFinishing = true
            isSourceIdle = false
            idleTickGeneration &+= 1
            pendingVideoFrames.removeAll()
            pendingVideoFrameIndex = 0
            pendingAudioSamples.removeAll()
            pendingAudioSampleIndex = 0
            writer.cancelWriting()
            cancelSegmentSinks()
        }
    }

    private var frameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(targetFramesPerSecond))
    }

    private func appendIdlePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        at presentationTime: CMTime
    ) {
        // Idle backfill references one shared pixel buffer, so a complete
        // second of a 60 FPS time grid is inexpensive. Still cap it to two
        // seconds so a stalled encoder cannot accumulate forever.
        append(
            pixelBuffer,
            at: presentationTime,
            maximumPendingFrameCount: max(targetFramesPerSecond * 2, 8)
        )
    }

    private func append(
        _ pixelBuffer: CVPixelBuffer,
        at presentationTime: CMTime,
        maximumPendingFrameCount: Int = maximumPendingVideoFrameCount
    ) {
        guard lastScheduledVideoTime.map({ presentationTime > $0 }) ?? true else { return }
        compactPendingVideoFramesIfNeeded()
        guard pendingVideoFrames.count - pendingVideoFrameIndex
                < maximumPendingFrameCount else {
            performance.recordDroppedFrame()
            return
        }
        lastScheduledVideoTime = presentationTime
        pendingVideoFrames.append(PendingVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime
        ))
        drainPendingVideoFrames()
    }

    private var hasPendingVideoFrames: Bool {
        pendingVideoFrameIndex < pendingVideoFrames.count
    }

    private func drainPendingVideoFrames() {
        guard storedFailure == nil else { return }
        while hasPendingVideoFrames, videoInput.isReadyForMoreMediaData {
            let frame = pendingVideoFrames[pendingVideoFrameIndex]
            guard pixelBufferAdaptor.append(
                frame.pixelBuffer,
                withPresentationTime: frame.presentationTime
            ) else {
                performance.recordDroppedFrame()
                storedFailure = ScreenVideoTrackWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "unknown"
                )
                return
            }
            pendingVideoFrameIndex += 1
            lastWrittenVideoTime = frame.presentationTime
            performance.recordWritten(at: frame.presentationTime)
        }
        compactPendingVideoFramesIfNeeded()
        if hasPendingVideoFrames, !isFinishing {
            scheduleDrainRetry()
        }
    }

    private var hasPendingAudioSamples: Bool {
        pendingAudioSampleIndex < pendingAudioSamples.count
    }

    private func drainPendingAudioSamples(input: AVAssetWriterInput? = nil) {
        guard storedFailure == nil,
              let audioInput = input ?? audioInput else { return }
        while hasPendingAudioSamples, audioInput.isReadyForMoreMediaData {
            let sample = pendingAudioSamples[pendingAudioSampleIndex]
            guard audioInput.append(sample) else {
                storedFailure = ScreenVideoTrackWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "system audio"
                )
                return
            }
            pendingAudioSampleIndex += 1
        }
        compactPendingAudioSamplesIfNeeded()
        if hasPendingAudioSamples, !isFinishing {
            scheduleAudioDrainRetry()
        }
    }

    private func compactPendingAudioSamplesIfNeeded() {
        guard pendingAudioSampleIndex > 256,
              pendingAudioSampleIndex * 2 >= pendingAudioSamples.count else { return }
        pendingAudioSamples.removeFirst(pendingAudioSampleIndex)
        pendingAudioSampleIndex = 0
    }

    private func scheduleAudioDrainRetry() {
        guard !audioDrainRetryScheduled else { return }
        audioDrainRetryScheduled = true
        outputQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
            audioDrainRetryScheduled = false
            drainPendingAudioSamples()
        }
    }

    private func compactPendingVideoFramesIfNeeded() {
        // Full-resolution callback buffers belong to ScreenCaptureKit's small
        // queueDepth-sized IOSurface pool. Release every consumed reference
        // immediately; retaining hundreds of already-written frames here
        // starves that pool and makes a dynamic recording update only when the
        // array is eventually compacted several seconds later.
        guard pendingVideoFrameIndex > 0 else { return }
        pendingVideoFrames.removeFirst(pendingVideoFrameIndex)
        pendingVideoFrameIndex = 0
    }

    private func scheduleDrainRetry() {
        guard !drainRetryScheduled else { return }
        drainRetryScheduled = true
        outputQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
            drainRetryScheduled = false
            drainPendingVideoFrames()
        }
    }

    private func finishWhenVideoQueueDrains(
        _ continuation: CheckedContinuation<Void, Error>
    ) {
        drainPendingVideoFrames()
        drainPendingAudioSamples()
        if let storedFailure {
            writer.cancelWriting()
            cancelSegmentSinks()
            continuation.resume(throwing: storedFailure)
            return
        }
        if hasPendingVideoFrames || hasPendingAudioSamples {
            outputQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in
                finishWhenVideoQueueDrains(continuation)
            }
            return
        }
        guard hasStartedSession, let lastWrittenVideoTime else {
            writer.cancelWriting()
            cancelSegmentSinks()
            continuation.resume(throwing: ScreenVideoTrackWriterError.noVideoFrames)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: lastWrittenVideoTime + frameInterval)
        writer.finishWriting { [self] in
            if writer.status == .completed {
                do {
                    try videoSegmentSink.finish()
                    try audioSegmentSink?.finish()
                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: ScreenVideoTrackWriterError.finishFailed(
                            error.localizedDescription
                        )
                    )
                }
            } else {
                cancelSegmentSinks()
                continuation.resume(
                    throwing: ScreenVideoTrackWriterError.finishFailed(
                        writer.error?.localizedDescription ?? "unknown"
                    )
                )
            }
        }
    }

    private func cancelSegmentSinks() {
        videoSegmentSink.cancel()
        audioSegmentSink?.cancel()
    }

    private static func screenFrameStatus(
        _ sampleBuffer: CMSampleBuffer
    ) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            // Synthetic test buffers and future ScreenCaptureKit versions may
            // omit the status; callers treat that case as a complete frame.
            return nil
        }
        return status
    }
}
