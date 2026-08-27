@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LensCore

struct DuckingEnvelope: Equatable, Sendable {
    let attackStartSeconds: Double
    let fullDuckStartSeconds: Double
    let fullDuckEndSeconds: Double
    let releaseEndSeconds: Double
}

enum AudioMixdownRendererError: LocalizedError {
    case missingVideoTrack
    case missingMicrophoneTrack
    case compositionTrackUnavailable
    case exportSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack: "自动预览缺少视频轨。"
        case .missingMicrophoneTrack: "麦克风原始文件缺少音频轨。"
        case .compositionTrackUnavailable: "无法创建自动混音轨道。"
        case .exportSessionUnavailable: "无法创建自动混音导出任务。"
        }
    }
}

struct AudioMixdownRenderReport: Sendable {
    let outputURL: URL
    let voiceProcessingResult: VoiceAudioProcessingResult?
    let voiceProcessingErrorDescription: String?
}

final class AudioMixdownRenderer: @unchecked Sendable {
    private let analyzer = NarrationActivityAnalyzer()
    private let voiceProcessor = VoiceAudioProcessor()

    func render(
        inputURL: URL,
        microphoneURL: URL?,
        outputURL: URL,
        plan: AutoEditPlan.Audio,
        timeline: VideoEditTimeline? = nil,
        export: AutoEditPlan.Export? = nil
    ) async throws -> URL {
        try await renderWithReport(
            inputURL: inputURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            plan: plan,
            timeline: timeline,
            export: export
        ).outputURL
    }

    func renderWithReport(
        inputURL: URL,
        microphoneURL: URL?,
        outputURL: URL,
        plan: AutoEditPlan.Audio,
        timeline: VideoEditTimeline? = nil,
        export: AutoEditPlan.Export? = nil
    ) async throws -> AudioMixdownRenderReport {
        var voiceProcessingErrorDescription: String?
        var voiceProcessingResult: VoiceAudioProcessingResult?
        let inputAsset = AVURLAsset(url: inputURL)
        let conditionedMicrophoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".conditioned-microphone-\(UUID().uuidString).caf"
            )
        let mixMicrophoneURL: URL?
        if let microphoneURL {
            let microphoneProcessingIsEnabled = plan.reducesMicrophoneNoise
                || plan.normalizesLoudness
            if microphoneProcessingIsEnabled {
                do {
                    let result = try await voiceProcessor.process(
                        inputURL: microphoneURL,
                        outputURL: conditionedMicrophoneURL,
                        plan: plan
                    )
                    voiceProcessingResult = result
                    mixMicrophoneURL = result.outputURL
                } catch {
                    voiceProcessingErrorDescription = error.localizedDescription
                    mixMicrophoneURL = microphoneURL
                }
            } else {
                mixMicrophoneURL = microphoneURL
            }
        } else {
            mixMicrophoneURL = nil
        }
        defer { try? FileManager.default.removeItem(at: conditionedMicrophoneURL) }
        let transitionedMicrophoneURL: URL? = if mixMicrophoneURL != nil,
                                                   timeline?.hasActiveTransitions == true {
            outputURL.deletingLastPathComponent().appendingPathComponent(
                ".microphone-transitions-\(UUID().uuidString).m4a"
            )
        } else {
            nil
        }
        let microphoneAsset: AVAsset?
        if let mixMicrophoneURL, let timeline, let transitionedMicrophoneURL {
            _ = try await VideoTimelineCompositionBuilder().export(
                inputURL: mixMicrophoneURL,
                timeline: timeline,
                outputURL: transitionedMicrophoneURL,
                includesVideo: false,
                includesAudio: true,
                requiresAudio: true
            )
            microphoneAsset = AVURLAsset(url: transitionedMicrophoneURL)
        } else if let mixMicrophoneURL, let timeline {
            microphoneAsset = try await VideoTimelineCompositionBuilder().build(
                inputURL: mixMicrophoneURL,
                timeline: timeline,
                includesVideo: false,
                includesAudio: true,
                requiresAudio: true
            )
        } else if let mixMicrophoneURL {
            microphoneAsset = AVURLAsset(url: mixMicrophoneURL)
        } else {
            microphoneAsset = nil
        }
        defer {
            if let transitionedMicrophoneURL {
                try? FileManager.default.removeItem(at: transitionedMicrophoneURL)
            }
        }
        guard let sourceVideo = try await inputAsset.loadTracks(withMediaType: .video).first else {
            throw AudioMixdownRendererError.missingVideoTrack
        }
        let sourceMicrophone: AVAssetTrack?
        if let microphoneAsset {
            guard let track = try await microphoneAsset
                .loadTracks(withMediaType: .audio).first else {
                throw AudioMixdownRendererError.missingMicrophoneTrack
            }
            sourceMicrophone = track
        } else {
            sourceMicrophone = nil
        }
        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioMixdownRendererError.compositionTrackUnavailable
        }
        let videoRange = try await sourceVideo.load(.timeRange)
        try outputVideo.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        outputVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let outputDuration = videoRange.duration

        var parameters: [AVAudioMixInputParameters] = []
        if let sourceMicrophone {
            guard let outputMicrophone = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw AudioMixdownRendererError.compositionTrackUnavailable
            }
            let microphoneRange = try await sourceMicrophone.load(.timeRange)
            let microphoneDuration = CMTimeMinimum(microphoneRange.duration, outputDuration)
            if microphoneDuration > .zero {
                try outputMicrophone.insertTimeRange(
                    CMTimeRange(start: microphoneRange.start, duration: microphoneDuration),
                    of: sourceMicrophone,
                    at: .zero
                )
            }
            let microphoneParameters = AVMutableAudioMixInputParameters(track: outputMicrophone)
            microphoneParameters.setVolume(Float(plan.microphoneVolume), at: .zero)
            parameters.append(microphoneParameters)
        }

        if let sourceSystemAudio = try await inputAsset.loadTracks(withMediaType: .audio).first,
           let outputSystemAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let systemRange = try await sourceSystemAudio.load(.timeRange)
            let systemDuration = CMTimeMinimum(systemRange.duration, outputDuration)
            if systemDuration > .zero {
                try outputSystemAudio.insertTimeRange(
                    CMTimeRange(start: systemRange.start, duration: systemDuration),
                    of: sourceSystemAudio,
                    at: .zero
                )
            }
            let systemParameters = AVMutableAudioMixInputParameters(track: outputSystemAudio)
            let systemNormalizationGain: Double
            if sourceMicrophone != nil,
               plan.normalizesLoudness,
               let metrics = try? await voiceProcessor.analyze(url: inputURL) {
                let gainDecibels = VoiceAudioProcessor.recommendedGainDecibels(
                    measuredLoudnessLUFS: metrics.integratedLoudnessLUFS,
                    targetLoudnessLUFS: plan.targetLoudnessLUFS - 6,
                    peakAmplitude: metrics.peakAmplitude,
                    maximumBoostDecibels: 6,
                    maximumCutDecibels: 12
                )
                systemNormalizationGain = VoiceAudioProcessor.linearGain(
                    decibels: gainDecibels
                )
            } else {
                systemNormalizationGain = 1
            }
            let normalizedSystemVolume = min(
                max(plan.systemVolume * systemNormalizationGain, 0),
                2
            )
            let baseVolume = Float(normalizedSystemVolume)
            let duckedVolume = Float(
                normalizedSystemVolume * plan.duckedSystemVolume
            )
            systemParameters.setVolume(baseVolume, at: .zero)
            if plan.ducksSystemUnderNarration,
               let mixMicrophoneURL {
                let sourceActivity = try analyzer.analyze(
                    url: mixMicrophoneURL,
                    thresholdDecibels: plan.narrationThresholdDecibels
                )
                let activity: [NarrationActivityRange]
                if let timeline {
                    activity = sourceActivity.flatMap { sourceRange in
                        timeline.outputRanges(forSourceRange: VideoEditTimeRange(
                            startSeconds: sourceRange.startSeconds,
                            endSeconds: sourceRange.endSeconds
                        )).map {
                            NarrationActivityRange(
                                startSeconds: $0.startSeconds,
                                endSeconds: $0.endSeconds
                            )
                        }
                    }
                } else {
                    activity = sourceActivity
                }
                let envelopes = Self.duckingEnvelopes(
                    activity: activity,
                    attackSeconds: plan.duckAttackSeconds,
                    releaseSeconds: plan.duckReleaseSeconds,
                    durationSeconds: outputDuration.seconds
                )
                for envelope in envelopes {
                    Self.apply(
                        envelope,
                        to: systemParameters,
                        baseVolume: baseVolume,
                        duckedVolume: duckedVolume
                    )
                }
            }
            parameters.append(systemParameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        let exportProfile = VideoExportProfile(export)
        let videoComposition = try await timingPreservingVideoComposition(
            asset: composition,
            sourceTrack: sourceVideo,
            outputTrack: outputVideo,
            exportProfile: exportProfile
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: exportProfile.assetExportPresetName
        ) else {
            throw AudioMixdownRendererError.exportSessionUnavailable
        }
        exporter.audioMix = audioMix
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await exporter.export(to: outputURL, as: .mp4)
        return AudioMixdownRenderReport(
            outputURL: outputURL,
            voiceProcessingResult: voiceProcessingResult,
            voiceProcessingErrorDescription: voiceProcessingErrorDescription
        )
    }

    /// `AVAssetExportSession` silently chooses a 30 FPS video composition for a
    /// large mutable composition when an audio mix is attached. That makes the
    /// source-quality preset lose half of a real 60 FPS screen recording even
    /// though the preceding effects render is still 60 FPS. Author an explicit
    /// passthrough composition and inherit timing from the actual effects track.
    private func timingPreservingVideoComposition(
        asset: AVAsset,
        sourceTrack: AVAssetTrack,
        outputTrack: AVCompositionTrack,
        exportProfile: VideoExportProfile
    ) async throws -> AVMutableVideoComposition {
        let composition = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVMutableVideoComposition, Error>) in
            AVMutableVideoComposition.videoComposition(
                withPropertiesOf: asset,
                completionHandler: { composition, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let composition {
                        continuation.resume(returning: composition)
                    } else {
                        continuation.resume(
                            throwing: AudioMixdownRendererError.exportSessionUnavailable
                        )
                    }
                }
            )
        }
        let sourceFrameDuration: CMTime = if let frameDuration = try? await sourceTrack.load(
            .minFrameDuration
        ), frameDuration.isNumeric,
           frameDuration.seconds.isFinite,
           frameDuration.seconds > 0 {
            frameDuration
        } else if let nominalFrameRate = try? await sourceTrack.load(.nominalFrameRate),
                  nominalFrameRate.isFinite,
                  nominalFrameRate > 0 {
            CMTime(
                seconds: 1 / Double(min(max(nominalFrameRate, 1), 120)),
                preferredTimescale: 60_000
            )
        } else {
            CMTime(value: 1, timescale: 30)
        }
        let limitedFrameDuration = exportProfile.limitedFrameDuration(sourceFrameDuration)
        composition.frameDuration = limitedFrameDuration
        composition.sourceTrackIDForFrameTiming = exportProfile.maximumFramesPerSecond == nil
            ? outputTrack.trackID
            : kCMPersistentTrackID_Invalid
        return composition
    }

    /// A microphone always needs a mix pass. A system-only recording only needs
    /// one when the user has authored a non-unity system-volume adjustment.
    /// This keeps the default fast path lossless while ensuring the visible
    /// system-volume control is never a no-op without a microphone track.
    static func requiresMixdown(
        microphoneURL: URL?,
        plan: AutoEditPlan.Audio
    ) -> Bool {
        plan.isEnabled
            && (microphoneURL != nil || abs(plan.systemVolume - 1) > 0.000_1)
    }

    static func duckingEnvelopes(
        activity: [NarrationActivityRange],
        attackSeconds: Double,
        releaseSeconds: Double,
        durationSeconds: Double
    ) -> [DuckingEnvelope] {
        let merged = NarrationActivityAnalyzer.merge(
            activity,
            maximumGap: max(0, attackSeconds + releaseSeconds)
        )
        return merged.map { range in
            DuckingEnvelope(
                attackStartSeconds: max(0, range.startSeconds - max(0, attackSeconds)),
                fullDuckStartSeconds: min(max(0, range.startSeconds), durationSeconds),
                fullDuckEndSeconds: min(max(0, range.endSeconds), durationSeconds),
                releaseEndSeconds: min(
                    max(0, range.endSeconds + max(0, releaseSeconds)),
                    durationSeconds
                )
            )
        }.filter { $0.fullDuckEndSeconds > $0.attackStartSeconds }
    }

    private static func apply(
        _ envelope: DuckingEnvelope,
        to parameters: AVMutableAudioMixInputParameters,
        baseVolume: Float,
        duckedVolume: Float
    ) {
        let attackStart = CMTime(seconds: envelope.attackStartSeconds, preferredTimescale: 600)
        let fullStart = CMTime(seconds: envelope.fullDuckStartSeconds, preferredTimescale: 600)
        let fullEnd = CMTime(seconds: envelope.fullDuckEndSeconds, preferredTimescale: 600)
        let releaseEnd = CMTime(seconds: envelope.releaseEndSeconds, preferredTimescale: 600)
        if fullStart > attackStart {
            parameters.setVolumeRamp(
                fromStartVolume: baseVolume,
                toEndVolume: duckedVolume,
                timeRange: CMTimeRange(start: attackStart, end: fullStart)
            )
        } else {
            parameters.setVolume(duckedVolume, at: fullStart)
        }
        parameters.setVolume(duckedVolume, at: fullStart)
        if releaseEnd > fullEnd {
            parameters.setVolumeRamp(
                fromStartVolume: duckedVolume,
                toEndVolume: baseVolume,
                timeRange: CMTimeRange(start: fullEnd, end: releaseEnd)
            )
        } else {
            parameters.setVolume(baseVolume, at: fullEnd)
        }
    }
}
