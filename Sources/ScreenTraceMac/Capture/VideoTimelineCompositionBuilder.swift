@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenTraceCore

enum VideoTimelineCompositionBuilderError: LocalizedError {
    case noActiveSegments
    case missingVideoTrack
    case missingAudioTrack
    case compositionTrackUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveSegments: "时间线没有可播放片段。"
        case .missingVideoTrack: "原始素材缺少视频轨道。"
        case .missingAudioTrack: "原始素材缺少音频轨道。"
        case .compositionTrackUnavailable: "无法创建非破坏性时间线轨道。"
        }
    }
}

final class VideoTimelineCompositionBuilder: @unchecked Sendable {
    func build(
        inputURL: URL,
        timeline: VideoEditTimeline,
        includesVideo: Bool,
        includesAudio: Bool,
        requiresVideo: Bool = false,
        requiresAudio: Bool = false
    ) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: inputURL)
        let timeline = timeline.normalized()
        guard !timeline.activeSegments.isEmpty else {
            throw VideoTimelineCompositionBuilderError.noActiveSegments
        }

        let composition = AVMutableComposition()
        if includesVideo {
            if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
                try await insert(
                    sourceTrack: sourceVideo,
                    mediaType: .video,
                    timeline: timeline,
                    into: composition
                )
            } else if requiresVideo {
                throw VideoTimelineCompositionBuilderError.missingVideoTrack
            }
        }
        if includesAudio {
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try await insert(
                    sourceTrack: sourceAudio,
                    mediaType: .audio,
                    timeline: timeline,
                    into: composition
                )
            } else if requiresAudio {
                throw VideoTimelineCompositionBuilderError.missingAudioTrack
            }
        }
        return composition
    }

    private func insert(
        sourceTrack: AVAssetTrack,
        mediaType: AVMediaType,
        timeline: VideoEditTimeline,
        into composition: AVMutableComposition
    ) async throws {
        guard let destination = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoTimelineCompositionBuilderError.compositionTrackUnavailable
        }
        if mediaType == .video {
            destination.preferredTransform = try await sourceTrack.load(.preferredTransform)
        }

        let trackRange = try await sourceTrack.load(.timeRange)
        let trackDurationSeconds = max(trackRange.duration.seconds, 0)
        var outputCursor = CMTime.zero
        for segment in timeline.activeSegments {
            let plannedOutputDuration = CMTime(
                seconds: segment.outputDurationSeconds,
                preferredTimescale: 600
            )
            let sourceStartSeconds = min(segment.sourceStartSeconds, trackDurationSeconds)
            let availableSeconds = max(trackDurationSeconds - sourceStartSeconds, 0)
            let sourceDurationSeconds = min(
                segment.sourceDurationSeconds,
                availableSeconds
            )
            guard sourceDurationSeconds >= VideoEditTimeline.minimumSegmentDurationSeconds else {
                destination.insertEmptyTimeRange(CMTimeRange(
                    start: outputCursor,
                    duration: plannedOutputDuration
                ))
                outputCursor = CMTimeAdd(outputCursor, plannedOutputDuration)
                continue
            }
            let sourceRange = CMTimeRange(
                start: CMTimeAdd(
                    trackRange.start,
                    CMTime(seconds: sourceStartSeconds, preferredTimescale: 600)
                ),
                duration: CMTime(seconds: sourceDurationSeconds, preferredTimescale: 600)
            )
            try destination.insertTimeRange(
                sourceRange,
                of: sourceTrack,
                at: outputCursor
            )
            let insertedRange = CMTimeRange(
                start: outputCursor,
                duration: sourceRange.duration
            )
            let insertedOutputDuration = CMTime(
                seconds: sourceDurationSeconds / segment.playbackRate,
                preferredTimescale: 600
            )
            if abs(segment.playbackRate - 1) > 0.000_001 {
                destination.scaleTimeRange(insertedRange, toDuration: insertedOutputDuration)
            }
            let missingOutputDuration = CMTimeSubtract(
                plannedOutputDuration,
                insertedOutputDuration
            )
            if CMTimeCompare(missingOutputDuration, .zero) > 0 {
                destination.insertEmptyTimeRange(CMTimeRange(
                    start: CMTimeAdd(outputCursor, insertedOutputDuration),
                    duration: missingOutputDuration
                ))
            }
            outputCursor = CMTimeAdd(outputCursor, plannedOutputDuration)
        }
    }
}
