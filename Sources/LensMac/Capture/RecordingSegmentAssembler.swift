@preconcurrency import AVFoundation
import Foundation

enum RecordingSegmentAssemblerError: LocalizedError {
    case noSegments
    case missingVideoTrack(String)
    case missingAudioTrack(String)
    case incompatibleAudioFormat
    case durationCountMismatch
    case exportSessionUnavailable
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .noSegments: "没有可合并的录制分片。"
        case let .missingVideoTrack(filename): "录制分片 \(filename) 不包含视频轨道。"
        case let .missingAudioTrack(filename): "录制分片 \(filename) 不包含音频轨道。"
        case .incompatibleAudioFormat: "麦克风分片的音频格式不一致。"
        case .durationCountMismatch: "录制分片与屏幕时长记录不一致。"
        case .exportSessionUnavailable: "无法创建分片合并任务。"
        case .emptyOutput: "分片合并没有生成有效文件。"
        }
    }
}

/// Assembly is I/O heavy (whole-file copies, PCM concatenation, passthrough
/// exports) and sits directly on the recording stop path, so it runs on an
/// actor instead of the main actor. The static helpers execute within the
/// actor-isolated methods that call them, keeping the main thread free while
/// a long recording's segments are joined.
actor RecordingSegmentAssembler {
    func assembleVideoSegments(
        _ segmentURLs: [URL],
        outputURL: URL,
        fileType: AVFileType,
        maximumDurations: [Double]? = nil
    ) async throws -> URL {
        guard !segmentURLs.isEmpty else { throw RecordingSegmentAssemblerError.noSegments }
        if let maximumDurations, maximumDurations.count != segmentURLs.count {
            throw RecordingSegmentAssemblerError.durationCountMismatch
        }
        guard segmentURLs.count > 1 || maximumDurations != nil else {
            try Self.validateNonemptyFile(at: segmentURLs[0])
            if segmentURLs[0].standardizedFileURL != outputURL.standardizedFileURL {
                try Self.copy(segmentURLs[0], to: outputURL)
            }
            return outputURL
        }

        let composition = AVMutableComposition()
        guard let outputVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingSegmentAssemblerError.exportSessionUnavailable
        }
        var outputAudioTrack: AVMutableCompositionTrack?
        var insertionTime = CMTime.zero

        for (position, url) in segmentURLs.enumerated() {
            let asset = AVURLAsset(url: url)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingSegmentAssemblerError.missingVideoTrack(url.lastPathComponent)
            }
            let sourceVideoRange = try await videoTrack.load(.timeRange)
            guard sourceVideoRange.duration.isNumeric, sourceVideoRange.duration > .zero else {
                throw RecordingSegmentAssemblerError.missingVideoTrack(url.lastPathComponent)
            }
            let videoDuration = maximumDurations.map {
                CMTimeMinimum(
                    sourceVideoRange.duration,
                    CMTime(seconds: max(0, $0[position]), preferredTimescale: 600)
                )
            } ?? sourceVideoRange.duration
            guard videoDuration.isNumeric, videoDuration > .zero else { continue }
            let videoRange = CMTimeRange(start: sourceVideoRange.start, duration: videoDuration)
            try outputVideoTrack.insertTimeRange(videoRange, of: videoTrack, at: insertionTime)
            if position == 0 {
                outputVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
            }

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                if outputAudioTrack == nil {
                    outputAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                let audioRange = try await audioTrack.load(.timeRange)
                let usableDuration = CMTimeMinimum(audioRange.duration, videoRange.duration)
                if usableDuration.isNumeric, usableDuration > .zero {
                    let usableRange = CMTimeRange(start: audioRange.start, duration: usableDuration)
                    try outputAudioTrack?.insertTimeRange(
                        usableRange,
                        of: audioTrack,
                        at: insertionTime
                    )
                }
            }
            insertionTime = CMTimeAdd(insertionTime, videoDuration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecordingSegmentAssemblerError.exportSessionUnavailable
        }
        let temporaryURL = Self.temporaryOutputURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await exporter.export(to: temporaryURL, as: fileType)
        try Self.validateNonemptyFile(at: temporaryURL)
        try Self.replace(outputURL, with: temporaryURL)
        return outputURL
    }

    func assembleAudioSegments(
        _ segmentURLs: [URL],
        outputURL: URL,
        maximumDurations: [Double]? = nil,
        allowsTrailingCorruption: Bool = false
    ) throws -> URL {
        guard !segmentURLs.isEmpty else { throw RecordingSegmentAssemblerError.noSegments }
        if let maximumDurations, maximumDurations.count != segmentURLs.count {
            throw RecordingSegmentAssemblerError.durationCountMismatch
        }
        guard segmentURLs.count > 1 || maximumDurations != nil else {
            try Self.validateNonemptyFile(at: segmentURLs[0])
            if segmentURLs[0].standardizedFileURL != outputURL.standardizedFileURL {
                try Self.copy(segmentURLs[0], to: outputURL)
            }
            return outputURL
        }

        let temporaryURL = Self.temporaryOutputURL(for: outputURL, pathExtension: "caf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Self.concatenateAudio(
            segmentURLs,
            maximumDurations: maximumDurations,
            allowsTrailingCorruption: allowsTrailingCorruption,
            to: temporaryURL
        )
        try Self.validateNonemptyFile(at: temporaryURL)
        try Self.replace(outputURL, with: temporaryURL)
        return outputURL
    }

    /// Apple HLS segment output emits independent video and audio fragment
    /// sequences. Keep both durable during capture, then remux them without
    /// re-encoding so the public raw recording remains one ordinary MP4.
    func mergeRecoverySystemAudioIfPresent(
        videoURL: URL,
        trimVideoToRecoveredAudio: Bool = false
    ) async throws -> URL {
        let audioURL = ScreenVideoTrackWriter.recoverySystemAudioURL(for: videoURL)
        let segmentDirectory = SystemAudioTrackWriter.segmentDirectoryURL(
            for: audioURL
        )
        let segmentURLs = SystemAudioTrackWriter.completedSegmentURLs(
            for: audioURL
        )
        if !Self.isNonemptyFile(at: audioURL), !segmentURLs.isEmpty {
            _ = try assembleAudioSegments(
                segmentURLs,
                outputURL: audioURL,
                allowsTrailingCorruption: true
            )
        }
        guard Self.isNonemptyFile(at: audioURL) else { return videoURL }

        let videoAsset = AVURLAsset(url: videoURL)
        if !(try await videoAsset.loadTracks(withMediaType: .audio)).isEmpty {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: segmentDirectory)
            return videoURL
        }

        let result = try await muxSystemAudio(
            videoURL: videoURL,
            audioURL: audioURL,
            trimVideoToAudio: trimVideoToRecoveredAudio
        )
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: segmentDirectory)
        return result
    }

    func muxSystemAudio(
        videoURL: URL,
        audioURL: URL,
        trimVideoToAudio: Bool = false
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let sourceVideoTrack = try await videoAsset
            .loadTracks(withMediaType: .video).first else {
            throw RecordingSegmentAssemblerError.missingVideoTrack(
                videoURL.lastPathComponent
            )
        }
        guard let sourceAudioTrack = try await audioAsset
            .loadTracks(withMediaType: .audio).first else {
            throw RecordingSegmentAssemblerError.missingAudioTrack(
                audioURL.lastPathComponent
            )
        }
        let videoRange = try await sourceVideoTrack.load(.timeRange)
        let audioRange = try await sourceAudioTrack.load(.timeRange)
        let usableAudioDuration = CMTimeMinimum(
            videoRange.duration,
            audioRange.duration
        )
        guard videoRange.duration.isNumeric,
              videoRange.duration > .zero,
              usableAudioDuration.isNumeric,
              usableAudioDuration > .zero else {
            throw RecordingSegmentAssemblerError.emptyOutput
        }

        let composition = AVMutableComposition()
        guard let outputVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let outputAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingSegmentAssemblerError.exportSessionUnavailable
        }
        let outputVideoRange = trimVideoToAudio
            ? CMTimeRange(start: videoRange.start, duration: usableAudioDuration)
            : videoRange
        try outputVideoTrack.insertTimeRange(
            outputVideoRange,
            of: sourceVideoTrack,
            at: .zero
        )
        outputVideoTrack.preferredTransform = try await sourceVideoTrack
            .load(.preferredTransform)
        try outputAudioTrack.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: usableAudioDuration),
            of: sourceAudioTrack,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RecordingSegmentAssemblerError.exportSessionUnavailable
        }
        let temporaryURL = Self.temporaryOutputURL(for: videoURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await exporter.export(to: temporaryURL, as: .mp4)
        try Self.validateNonemptyFile(at: temporaryURL)
        try Self.replace(videoURL, with: temporaryURL)
        return videoURL
    }

    /// Whole-file archival copies for the first segment run here so the stop
    /// path never blocks the main thread on multi-gigabyte media.
    func copyFileIfNeeded(_ sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try Self.validateNonemptyFile(at: destinationURL)
            return
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func concatenateAudio(
        _ segmentURLs: [URL],
        maximumDurations: [Double]?,
        allowsTrailingCorruption: Bool,
        to outputURL: URL
    ) throws {
        let first = try AVAudioFile(forReading: segmentURLs[0])
        let format = first.processingFormat
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: outputURL,
            settings: first.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        var writtenFrameCount: AVAudioFramePosition = 0
        segmentLoop: for (position, url) in segmentURLs.enumerated() {
            let input: AVAudioFile
            do {
                input = try AVAudioFile(forReading: url)
            } catch {
                if allowsTrailingCorruption, writtenFrameCount > 0 {
                    break segmentLoop
                }
                throw error
            }
            guard input.processingFormat.sampleRate == format.sampleRate,
                  input.processingFormat.channelCount == format.channelCount,
                  input.processingFormat.commonFormat == format.commonFormat,
                  input.processingFormat.isInterleaved == format.isInterleaved else {
                if allowsTrailingCorruption, writtenFrameCount > 0 {
                    break segmentLoop
                }
                throw RecordingSegmentAssemblerError.incompatibleAudioFormat
            }
            let capacity: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw RecordingSegmentAssemblerError.incompatibleAudioFormat
            }
            let maximumFrameCount = maximumDurations.map {
                AVAudioFramePosition(max(0, $0[position]) * format.sampleRate)
            }
            let endingFrame = min(input.length, maximumFrameCount ?? input.length)
            while input.framePosition < endingFrame {
                let remaining = endingFrame - input.framePosition
                let frameCount = AVAudioFrameCount(min(Int64(capacity), remaining))
                do {
                    try input.read(into: buffer, frameCount: frameCount)
                } catch {
                    if allowsTrailingCorruption, writtenFrameCount > 0 {
                        break segmentLoop
                    }
                    throw error
                }
                guard buffer.frameLength > 0 else { break }
                try output?.write(from: buffer)
                writtenFrameCount += AVAudioFramePosition(buffer.frameLength)
            }
        }
        guard writtenFrameCount > 0 else {
            throw RecordingSegmentAssemblerError.emptyOutput
        }
        output = nil
    }

    private static func replace(_ outputURL: URL, with temporaryURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
    }

    private static func copy(_ sourceURL: URL, to outputURL: URL) throws {
        let temporaryURL = temporaryOutputURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        try replace(outputURL, with: temporaryURL)
    }

    private static func validateNonemptyFile(at url: URL) throws {
        guard isNonemptyFile(at: url) else {
            throw RecordingSegmentAssemblerError.emptyOutput
        }
    }

    private static func isNonemptyFile(at url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private static func temporaryOutputURL(
        for outputURL: URL,
        pathExtension: String? = nil
    ) -> URL {
        let ext = pathExtension ?? outputURL.pathExtension
        return outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.deletingPathExtension().lastPathComponent)-assembled-\(UUID().uuidString).\(ext)"
        )
    }
}
