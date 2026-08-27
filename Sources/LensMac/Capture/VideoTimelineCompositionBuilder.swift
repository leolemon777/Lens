@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LensCore

enum VideoTimelineCompositionBuilderError: LocalizedError {
    case noActiveSegments
    case missingVideoTrack
    case missingAudioTrack
    case compositionTrackUnavailable
    case exportSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveSegments: "时间线没有可播放片段。"
        case .missingVideoTrack: "原始素材缺少视频轨道。"
        case .missingAudioTrack: "原始素材缺少音频轨道。"
        case .compositionTrackUnavailable: "无法创建非破坏性时间线轨道。"
        case .exportSessionUnavailable: "无法创建时间线转场导出任务。"
        }
    }
}

struct VideoTimelineCompositionPackage {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix?
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
        try await buildPackage(
            inputURL: inputURL,
            timeline: timeline,
            includesVideo: includesVideo,
            includesAudio: includesAudio,
            requiresVideo: requiresVideo,
            requiresAudio: requiresAudio
        ).composition
    }

    func buildPackage(
        inputURL: URL,
        timeline requestedTimeline: VideoEditTimeline,
        includesVideo: Bool,
        includesAudio: Bool,
        requiresVideo: Bool = false,
        requiresAudio: Bool = false
    ) async throws -> VideoTimelineCompositionPackage {
        let asset = AVURLAsset(url: inputURL)
        let timeline = requestedTimeline.normalized()
        guard !timeline.activeSegments.isEmpty else {
            throw VideoTimelineCompositionBuilderError.noActiveSegments
        }

        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        var audioTracks: [AVMutableCompositionTrack] = []
        var sourceVideo: AVAssetTrack?

        if includesVideo {
            sourceVideo = try await asset.loadTracks(withMediaType: .video).first
            if let sourceVideo {
                videoTracks = try await insert(
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
                audioTracks = try await insert(
                    sourceTrack: sourceAudio,
                    mediaType: .audio,
                    timeline: timeline,
                    into: composition
                )
            } else if requiresAudio {
                throw VideoTimelineCompositionBuilderError.missingAudioTrack
            }
        }

        let videoComposition: AVMutableVideoComposition?
        if timeline.hasActiveTransitions,
           let sourceVideo,
           !videoTracks.isEmpty {
            videoComposition = try await makeVideoComposition(
                sourceTrack: sourceVideo,
                destinationTracks: videoTracks,
                timeline: timeline
            )
        } else {
            videoComposition = nil
        }
        let audioMix = timeline.hasActiveTransitions && !audioTracks.isEmpty
            ? makeAudioMix(destinationTracks: audioTracks, timeline: timeline)
            : nil

        return VideoTimelineCompositionPackage(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix
        )
    }

    @discardableResult
    func export(
        inputURL: URL,
        timeline: VideoEditTimeline,
        outputURL: URL,
        includesVideo: Bool,
        includesAudio: Bool,
        requiresVideo: Bool = false,
        requiresAudio: Bool = false
    ) async throws -> URL {
        let package = try await buildPackage(
            inputURL: inputURL,
            timeline: timeline,
            includesVideo: includesVideo,
            includesAudio: includesAudio,
            requiresVideo: requiresVideo,
            requiresAudio: requiresAudio
        )
        let preset = includesVideo
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetAppleM4A
        guard let exporter = AVAssetExportSession(
            asset: package.composition,
            presetName: preset
        ) else {
            throw VideoTimelineCompositionBuilderError.exportSessionUnavailable
        }
        exporter.videoComposition = package.videoComposition
        exporter.audioMix = package.audioMix
        exporter.shouldOptimizeForNetworkUse = includesVideo
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await exporter.export(
            to: outputURL,
            as: includesVideo ? .mp4 : .m4a
        )
        return outputURL
    }

    private func insert(
        sourceTrack: AVAssetTrack,
        mediaType: AVMediaType,
        timeline: VideoEditTimeline,
        into composition: AVMutableComposition
    ) async throws -> [AVMutableCompositionTrack] {
        let destinationCount = timeline.hasActiveTransitions
            ? min(timeline.activeSegments.count, 2)
            : 1
        var destinations: [AVMutableCompositionTrack] = []
        for _ in 0..<destinationCount {
            guard let destination = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoTimelineCompositionBuilderError.compositionTrackUnavailable
            }
            if mediaType == .video {
                destination.preferredTransform = try await sourceTrack.load(.preferredTransform)
            }
            destinations.append(destination)
        }

        let trackRange = try await sourceTrack.load(.timeRange)
        let trackDurationSeconds = max(trackRange.duration.seconds, 0)
        for (index, pair) in zip(timeline.activeSegments, timeline.segmentLayouts).enumerated() {
            let segment = pair.0
            let layout = pair.1
            let destination = destinations[index % destinations.count]
            let outputStart = CMTime(
                seconds: layout.outputStartSeconds,
                preferredTimescale: 600
            )
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
                    start: outputStart,
                    duration: plannedOutputDuration
                ))
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
                at: outputStart
            )
            let insertedRange = CMTimeRange(
                start: outputStart,
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
                    start: CMTimeAdd(outputStart, insertedOutputDuration),
                    duration: missingOutputDuration
                ))
            }
        }
        return destinations
    }

    private func makeVideoComposition(
        sourceTrack: AVAssetTrack,
        destinationTracks: [AVMutableCompositionTrack],
        timeline: VideoEditTimeline
    ) async throws -> AVMutableVideoComposition {
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let transform = try await sourceTrack.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
        let renderSize = CGSize(
            width: max(abs(orientedRect.width), 2),
            height: max(abs(orientedRect.height), 2)
        )
        let nominalFrameRate = try await sourceTrack.load(.nominalFrameRate)
        let frameRate = nominalFrameRate.isFinite && nominalFrameRate > 0
            ? min(max(Double(nominalFrameRate), 1), 120)
            : 60
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(
            seconds: 1 / frameRate,
            preferredTimescale: 60_000
        )

        let active = timeline.activeSegments
        let layouts = timeline.segmentLayouts
        let transitions = timeline.resolvedTransitions
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for index in active.indices {
            let layout = layouts[index]
            let incoming = index > 0 ? transitions.first {
                $0.toSegmentID == active[index].id
            } : nil
            let outgoing = transitions.first {
                $0.fromSegmentID == active[index].id
            }
            let passStart = incoming?.outputEndSeconds ?? layout.outputStartSeconds
            let passEnd = outgoing?.outputStartSeconds ?? layout.outputEndSeconds
            if passEnd - passStart > 0.000_1 {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = Self.timeRange(
                    start: passStart,
                    end: passEnd
                )
                instruction.backgroundColor = CGColor.black
                let layer = AVMutableVideoCompositionLayerInstruction(
                    assetTrack: destinationTracks[index % destinationTracks.count]
                )
                layer.setTransform(transform, at: instruction.timeRange.start)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }
            guard let outgoing else { continue }
            let nextIndex = index + 1
            let range = Self.timeRange(
                start: outgoing.outputStartSeconds,
                end: outgoing.outputEndSeconds
            )
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            instruction.backgroundColor = CGColor.black
            let outgoingLayer = AVMutableVideoCompositionLayerInstruction(
                assetTrack: destinationTracks[index % destinationTracks.count]
            )
            let incomingLayer = AVMutableVideoCompositionLayerInstruction(
                assetTrack: destinationTracks[nextIndex % destinationTracks.count]
            )
            outgoingLayer.setTransform(transform, at: range.start)
            incomingLayer.setTransform(transform, at: range.start)
            Self.applyVideoTransition(
                outgoing,
                range: range,
                outgoingLayer: outgoingLayer,
                incomingLayer: incomingLayer
            )
            instruction.layerInstructions = [incomingLayer, outgoingLayer]
            instructions.append(instruction)
        }
        composition.instructions = instructions.sorted {
            CMTimeCompare($0.timeRange.start, $1.timeRange.start) < 0
        }
        return composition
    }

    private func makeAudioMix(
        destinationTracks: [AVMutableCompositionTrack],
        timeline: VideoEditTimeline
    ) -> AVMutableAudioMix {
        let parameters = destinationTracks.map(AVMutableAudioMixInputParameters.init(track:))
        let active = timeline.activeSegments
        let layouts = timeline.segmentLayouts
        let transitions = timeline.resolvedTransitions

        for index in active.indices {
            let parameter = parameters[index % parameters.count]
            let layout = layouts[index]
            let start = Self.time(layout.outputStartSeconds)
            let incoming = index > 0 ? transitions.first {
                $0.toSegmentID == active[index].id
            } : nil
            let outgoing = transitions.first {
                $0.fromSegmentID == active[index].id
            }
            parameter.setVolume(incoming == nil ? 1 : 0, at: start)
            if let incoming {
                Self.applyIncomingAudioTransition(incoming, to: parameter)
            }
            if let outgoing {
                Self.applyOutgoingAudioTransition(outgoing, to: parameter)
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func applyVideoTransition(
        _ transition: VideoEditResolvedTransition,
        range: CMTimeRange,
        outgoingLayer: AVMutableVideoCompositionLayerInstruction,
        incomingLayer: AVMutableVideoCompositionLayerInstruction
    ) {
        switch transition.kind {
        case .cut:
            break
        case .crossDissolve:
            outgoingLayer.setOpacityRamp(
                fromStartOpacity: 1,
                toEndOpacity: 0,
                timeRange: range
            )
            incomingLayer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: 1,
                timeRange: range
            )
        case .dipToBlack:
            let halves = split(range)
            outgoingLayer.setOpacityRamp(
                fromStartOpacity: 1,
                toEndOpacity: 0,
                timeRange: halves.first
            )
            outgoingLayer.setOpacity(0, at: halves.second.start)
            incomingLayer.setOpacity(0, at: range.start)
            incomingLayer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: 1,
                timeRange: halves.second
            )
        }
    }

    private static func applyIncomingAudioTransition(
        _ transition: VideoEditResolvedTransition,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let range = timeRange(
            start: transition.outputStartSeconds,
            end: transition.outputEndSeconds
        )
        switch transition.kind {
        case .cut:
            parameters.setVolume(1, at: range.start)
        case .crossDissolve:
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: range
            )
        case .dipToBlack:
            let halves = split(range)
            parameters.setVolume(0, at: range.start)
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: halves.second
            )
        }
    }

    private static func applyOutgoingAudioTransition(
        _ transition: VideoEditResolvedTransition,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let range = timeRange(
            start: transition.outputStartSeconds,
            end: transition.outputEndSeconds
        )
        switch transition.kind {
        case .cut:
            break
        case .crossDissolve:
            parameters.setVolumeRamp(
                fromStartVolume: 1,
                toEndVolume: 0,
                timeRange: range
            )
        case .dipToBlack:
            parameters.setVolumeRamp(
                fromStartVolume: 1,
                toEndVolume: 0,
                timeRange: split(range).first
            )
        }
    }

    private static func split(_ range: CMTimeRange) -> (
        first: CMTimeRange,
        second: CMTimeRange
    ) {
        let halfDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
        let midpoint = CMTimeAdd(range.start, halfDuration)
        return (
            CMTimeRange(start: range.start, duration: halfDuration),
            CMTimeRange(start: midpoint, end: range.end)
        )
    }

    private static func timeRange(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
