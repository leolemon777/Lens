@preconcurrency import AVFoundation
import Foundation

enum RecordingSegmentAssemblerError: LocalizedError {
    case noSegments
    case missingVideoTrack(String)
    case incompatibleAudioFormat
    case exportSessionUnavailable
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .noSegments: "没有可合并的录制分片。"
        case let .missingVideoTrack(filename): "录制分片 \(filename) 不包含视频轨道。"
        case .incompatibleAudioFormat: "麦克风分片的音频格式不一致。"
        case .exportSessionUnavailable: "无法创建分片合并任务。"
        case .emptyOutput: "分片合并没有生成有效文件。"
        }
    }
}

@MainActor
final class RecordingSegmentAssembler {
    func assembleVideoSegments(
        _ segmentURLs: [URL],
        outputURL: URL,
        fileType: AVFileType
    ) async throws -> URL {
        guard !segmentURLs.isEmpty else { throw RecordingSegmentAssemblerError.noSegments }
        guard segmentURLs.count > 1 else {
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
            let videoRange = try await videoTrack.load(.timeRange)
            guard videoRange.duration.isNumeric, videoRange.duration > .zero else {
                throw RecordingSegmentAssemblerError.missingVideoTrack(url.lastPathComponent)
            }
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
            insertionTime = CMTimeAdd(insertionTime, videoRange.duration)
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
        outputURL: URL
    ) throws -> URL {
        guard !segmentURLs.isEmpty else { throw RecordingSegmentAssemblerError.noSegments }
        guard segmentURLs.count > 1 else {
            try Self.validateNonemptyFile(at: segmentURLs[0])
            if segmentURLs[0].standardizedFileURL != outputURL.standardizedFileURL {
                try Self.copy(segmentURLs[0], to: outputURL)
            }
            return outputURL
        }

        let temporaryURL = Self.temporaryOutputURL(for: outputURL, pathExtension: "caf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Self.concatenateAudio(segmentURLs, to: temporaryURL)
        try Self.validateNonemptyFile(at: temporaryURL)
        try Self.replace(outputURL, with: temporaryURL)
        return outputURL
    }

    private static func concatenateAudio(_ segmentURLs: [URL], to outputURL: URL) throws {
        let first = try AVAudioFile(forReading: segmentURLs[0])
        let format = first.processingFormat
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: outputURL,
            settings: first.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        for url in segmentURLs {
            let input = try AVAudioFile(forReading: url)
            guard input.processingFormat.sampleRate == format.sampleRate,
                  input.processingFormat.channelCount == format.channelCount,
                  input.processingFormat.commonFormat == format.commonFormat,
                  input.processingFormat.isInterleaved == format.isInterleaved else {
                throw RecordingSegmentAssemblerError.incompatibleAudioFormat
            }
            let capacity: AVAudioFrameCount = 8_192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw RecordingSegmentAssemblerError.incompatibleAudioFormat
            }
            while input.framePosition < input.length {
                let remaining = input.length - input.framePosition
                let frameCount = AVAudioFrameCount(min(Int64(capacity), remaining))
                try input.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else { break }
                try output?.write(from: buffer)
            }
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
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw RecordingSegmentAssemblerError.emptyOutput }
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
