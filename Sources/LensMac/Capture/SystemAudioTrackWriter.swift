import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum SystemAudioTrackWriterError: LocalizedError {
    case noSamples
    case writeFailed(String)
    case alreadyFinishing

    var errorDescription: String? {
        switch self {
        case .noSamples: "录制期间没有收到系统音频样本。"
        case let .writeFailed(detail): "写入系统音频恢复轨失败：\(detail)"
        case .alreadyFinishing: "系统音频正在完成写入。"
        }
    }
}

struct SystemAudioCaptureSnapshot: Equatable, Sendable {
    let deliveredCallbackCount: Int
    let receivedSampleCount: Int
    let appendedSampleCount: Int
    let observedTimelineSeconds: Double
    let pendingSampleCount: Int
}

/// Writes ScreenCaptureKit's native PCM into five-second CAF segments. No
/// second AVAssetWriter/AAC session is created, because macOS can stop system
/// audio delivery when a fragmented video encoder and a second asset writer
/// run concurrently. Closed segments are atomically renamed; `.partial` files
/// are ignored after SIGKILL, bounding loss to the current five-second window.
final class SystemAudioTrackWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    static let maximumPendingSampleCount = 512
    static let segmentDurationSeconds = 5.0

    let outputQueue: DispatchQueue

    private let finalOutputURL: URL
    private let segmentDirectoryURL: URL
    private let levelMeter: AudioLevelMeter?
    private let outputQueueKey = DispatchSpecificKey<Void>()
    private let metricsLock = NSLock()
    private var activeFile: AVAudioFile?
    private var activePartialURL: URL?
    private var activeCompletedURL: URL?
    private var activeStartTime: CMTime?
    private var nextSegmentIndex = 0
    private var storedFailure: Error?
    private var isAcceptingSamples = true
    private var isFinishing = false
    private var deliveredCallbackCount = 0
    private var receivedSampleCount = 0
    private var appendedSampleCount = 0
    private var firstObservedTime: CMTime?
    private var lastObservedEndTime: CMTime?

    init(outputURL: URL, levelMeter: AudioLevelMeter? = nil) throws {
        finalOutputURL = outputURL
        segmentDirectoryURL = Self.segmentDirectoryURL(for: outputURL)
        self.levelMeter = levelMeter
        outputQueue = DispatchQueue(
            label: "app.lens.system-audio-pcm-writer.\(UUID().uuidString)",
            qos: .userInteractive
        )
        outputQueue.setSpecific(key: outputQueueKey, value: ())
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: segmentDirectoryURL)
        try FileManager.default.createDirectory(
            at: segmentDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    static func segmentDirectoryURL(for finalOutputURL: URL) -> URL {
        finalOutputURL.deletingLastPathComponent().appendingPathComponent(
            "\(finalOutputURL.deletingPathExtension().lastPathComponent)-segments",
            isDirectory: true
        )
    }

    static func completedSegmentURLs(for finalOutputURL: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: segmentDirectoryURL(for: finalOutputURL),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter {
                $0.pathExtension.lowercased() == "caf"
                    && !$0.lastPathComponent.contains(".partial.")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var captureSnapshot: SystemAudioCaptureSnapshot {
        let metrics = metricsLock.withLock {
            (
                deliveredCallbackCount,
                receivedSampleCount,
                appendedSampleCount,
                firstObservedTime,
                lastObservedEndTime
            )
        }
        let observed: Double
        if let first = metrics.3,
           let last = metrics.4,
           first.isNumeric,
           last.isNumeric,
           last >= first {
            observed = (last - first).seconds
        } else {
            observed = 0
        }
        return SystemAudioCaptureSnapshot(
            deliveredCallbackCount: metrics.0,
            receivedSampleCount: metrics.1,
            appendedSampleCount: metrics.2,
            observedTimelineSeconds: observed,
            pendingSampleCount: 0
        )
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        metricsLock.withLock { deliveredCallbackCount += 1 }
        let transferable = UncheckedSendableAudioSample(sampleBuffer)
        outputQueue.async { [self, transferable] in
            append(transferable.value)
        }
    }

    func prepareToFinish() {
        outputQueue.async { [self] in isAcceptingSamples = false }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            outputQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(
                        throwing: SystemAudioTrackWriterError.alreadyFinishing
                    )
                    return
                }
                isFinishing = true
                isAcceptingSamples = false
                do {
                    try finalizeActiveSegment()
                    if let storedFailure { throw storedFailure }
                    guard metricsLock.withLock({ appendedSampleCount }) > 0 else {
                        throw SystemAudioTrackWriterError.noSamples
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        outputQueue.async { [self] in
            guard !isFinishing else { return }
            isFinishing = true
            isAcceptingSamples = false
            activeFile = nil
            try? activePartialURL.map { try FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: finalOutputURL)
            try? FileManager.default.removeItem(at: segmentDirectoryURL)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard isAcceptingSamples,
              !isFinishing,
              storedFailure == nil,
              sampleBuffer.presentationTimeStamp.isNumeric else { return }
        let sampleDuration = sampleBuffer.duration.isNumeric
            ? sampleBuffer.duration
            : CMTime(value: 1_024, timescale: 48_000)
        let sampleEnd = sampleBuffer.presentationTimeStamp + sampleDuration
        metricsLock.withLock {
            receivedSampleCount += 1
            if firstObservedTime == nil {
                firstObservedTime = sampleBuffer.presentationTimeStamp
            }
            lastObservedEndTime = sampleEnd
        }
        levelMeter?.update(sampleBuffer: sampleBuffer)
        do {
            if let activeStartTime,
               (sampleBuffer.presentationTimeStamp - activeStartTime).seconds
                >= Self.segmentDurationSeconds {
                try finalizeActiveSegment()
            }
            let pcmBuffer = try AudioSampleBufferPCMConverter.convert(sampleBuffer)
            if activeFile == nil {
                try startSegment(
                    at: sampleBuffer.presentationTimeStamp,
                    format: pcmBuffer.format
                )
            }
            try activeFile?.write(from: pcmBuffer)
            metricsLock.withLock { appendedSampleCount += 1 }
        } catch {
            storedFailure = SystemAudioTrackWriterError.writeFailed(
                error.localizedDescription
            )
        }
    }

    private func startSegment(
        at startTime: CMTime,
        format: AVAudioFormat
    ) throws {
        let stem = String(format: "system-audio-%05d", nextSegmentIndex)
        nextSegmentIndex += 1
        let partialURL = segmentDirectoryURL.appendingPathComponent(
            "\(stem).partial.caf"
        )
        let completedURL = segmentDirectoryURL.appendingPathComponent(
            "\(stem).caf"
        )
        // The in-memory processing format is planar, while an audio file's
        // physical PCM representation must be interleaved. Keep the planar
        // client format below, but do not ask the CAF container to persist
        // non-interleaved samples (AVAudioFile otherwise logs and ignores it).
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        activeFile = try AVAudioFile(
            forWriting: partialURL,
            settings: fileSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        activePartialURL = partialURL
        activeCompletedURL = completedURL
        activeStartTime = startTime
    }

    private func finalizeActiveSegment() throws {
        guard let partialURL = activePartialURL,
              let completedURL = activeCompletedURL else { return }
        // Releasing AVAudioFile commits the CAF header before the atomic rename.
        activeFile = nil
        if FileManager.default.fileExists(atPath: completedURL.path) {
            try FileManager.default.removeItem(at: completedURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: completedURL)
        activePartialURL = nil
        activeCompletedURL = nil
        activeStartTime = nil
    }

}

private final class UncheckedSendableAudioSample: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}
