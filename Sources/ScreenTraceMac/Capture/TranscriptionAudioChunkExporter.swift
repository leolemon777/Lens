@preconcurrency import AVFoundation
import Foundation
import ScreenTraceCore

enum TranscriptionAudioChunkExporterError: LocalizedError {
    case missingAudioTrack
    case emptyChunk
    case compositionTrackUnavailable
    case exportSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAudioTrack:
            "录屏素材中没有可供转写的音轨。"
        case .emptyChunk:
            "转写音频片段为空。"
        case .compositionTrackUnavailable:
            "无法创建本地转写音频片段。"
        case .exportSessionUnavailable:
            "无法启动本地转写音频导出。"
        }
    }
}

final class TranscriptionAudioChunkExporter: @unchecked Sendable {
    func export(
        inputURL: URL,
        chunk: TranscriptChunk,
        outputURL: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionAudioChunkExporterError.missingAudioTrack
        }
        let trackRange = try await sourceTrack.load(.timeRange)
        let relativeStart = min(
            max(chunk.sourceStartSeconds, 0),
            max(trackRange.duration.seconds, 0)
        )
        let availableDuration = max(trackRange.duration.seconds - relativeStart, 0)
        let duration = min(chunk.sourceDurationSeconds, availableDuration)
        guard duration >= VideoEditTimeline.minimumSegmentDurationSeconds else {
            throw TranscriptionAudioChunkExporterError.emptyChunk
        }
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TranscriptionAudioChunkExporterError.compositionTrackUnavailable
        }
        let sourceRange = CMTimeRange(
            start: CMTimeAdd(
                trackRange.start,
                CMTime(seconds: relativeStart, preferredTimescale: 48_000)
            ),
            duration: CMTime(seconds: duration, preferredTimescale: 48_000)
        )
        try destination.insertTimeRange(sourceRange, of: sourceTrack, at: .zero)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw TranscriptionAudioChunkExporterError.exportSessionUnavailable
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try await exporter.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
