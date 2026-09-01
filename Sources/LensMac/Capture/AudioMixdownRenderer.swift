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
    case missingSystemAudioTrack
    case compositionTrackUnavailable
    case exportSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack: "自动预览缺少视频轨。"
        case .missingMicrophoneTrack: "麦克风原始文件缺少音频轨。"
        case .missingSystemAudioTrack: "源录屏没有可混音的系统声音轨。"
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
        let inputAsset = AVURLAsset(url: inputURL)
        let microphone = try await preparedMicrophone(
            microphoneURL: microphoneURL,
            plan: plan,
            timeline: timeline,
            outputDirectory: outputURL.deletingLastPathComponent()
        )
        defer {
            microphone.temporaryURLs.forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
        guard let sourceVideo = try await inputAsset.loadTracks(withMediaType: .video).first else {
            throw AudioMixdownRendererError.missingVideoTrack
        }
        let sourceMicrophone = try await microphone.asset?
            .loadTracks(withMediaType: .audio).first
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
            parameters.append(try await systemAudioParameters(
                for: outputSystemAudio,
                plan: plan,
                timeline: timeline,
                microphoneMixURL: microphone.mixURL,
                loudnessMeasurementURL: inputURL,
                microphonePresent: sourceMicrophone != nil,
                durationSeconds: outputDuration.seconds
            ))
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
            voiceProcessingResult: microphone.processingResult,
            voiceProcessingErrorDescription: microphone.processingErrorDescription
        )
    }

    /// Renders the narration/system mix as a standalone audio file. The
    /// effects render embeds it during its single video encode, so a
    /// microphone recording no longer pays a second full video generation
    /// just to attach its audio.
    func prepareMixedAudioSidecar(
        sourceURL: URL,
        microphoneURL: URL?,
        outputURL: URL,
        plan: AutoEditPlan.Audio,
        timeline: VideoEditTimeline? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioMixdownRenderReport {
        let outputDirectory = outputURL.deletingLastPathComponent()
        let sourceAsset = AVURLAsset(url: sourceURL)
        let microphone = try await preparedMicrophone(
            microphoneURL: microphoneURL,
            plan: plan,
            timeline: timeline,
            outputDirectory: outputDirectory
        )
        defer {
            microphone.temporaryURLs.forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
        let anchorDuration: CMTime = if let videoTrack = try await sourceAsset
            .loadTracks(withMediaType: .video).first {
            try await videoTrack.load(.timeRange).duration
        } else if let audioTrack = try await sourceAsset
            .loadTracks(withMediaType: .audio).first {
            try await audioTrack.load(.timeRange).duration
        } else {
            throw AudioMixdownRendererError.missingSystemAudioTrack
        }

        // The legacy two-pass mix consumed the transitions-baked preview's
        // audio. Building from the raw source instead requires flattening the
        // timeline onto the system track first so both paths mix identical
        // content.
        var systemTemporaryURL: URL?
        let systemAsset: AVAsset
        if let timeline, timeline.hasActiveTransitions {
            let flattened = outputDirectory.appendingPathComponent(
                ".system-transitions-\(UUID().uuidString).m4a"
            )
            _ = try await VideoTimelineCompositionBuilder().export(
                inputURL: sourceURL,
                timeline: timeline,
                outputURL: flattened,
                includesVideo: false,
                includesAudio: true
            )
            systemTemporaryURL = flattened
            systemAsset = AVURLAsset(url: flattened)
        } else {
            systemAsset = sourceAsset
        }
        defer {
            if let systemTemporaryURL {
                try? FileManager.default.removeItem(at: systemTemporaryURL)
            }
        }

        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        var mixedTracks: [AVCompositionTrack] = []
        if let microphoneAsset = microphone.asset,
           let sourceMicrophone = try await microphoneAsset
               .loadTracks(withMediaType: .audio).first,
           let outputMicrophone = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            mixedTracks.append(outputMicrophone)
            let microphoneRange = try await sourceMicrophone.load(.timeRange)
            let microphoneDuration = CMTimeMinimum(microphoneRange.duration, anchorDuration)
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
        if let sourceSystemAudio = try await systemAsset
            .loadTracks(withMediaType: .audio).first,
           let outputSystemAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            mixedTracks.append(outputSystemAudio)
            let systemRange = try await sourceSystemAudio.load(.timeRange)
            let systemDuration = CMTimeMinimum(systemRange.duration, anchorDuration)
            if systemDuration > .zero {
                try outputSystemAudio.insertTimeRange(
                    CMTimeRange(start: systemRange.start, duration: systemDuration),
                    of: sourceSystemAudio,
                    at: .zero
                )
            }
            parameters.append(try await systemAudioParameters(
                for: outputSystemAudio,
                plan: plan,
                timeline: timeline,
                microphoneMixURL: microphone.mixURL,
                loudnessMeasurementURL: sourceURL,
                microphonePresent: microphone.asset != nil,
                durationSeconds: anchorDuration.seconds
            ))
        }
        guard !parameters.isEmpty else {
            throw AudioMixdownRendererError.missingSystemAudioTrack
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        try Self.writeMixedPCM(
            composition: composition,
            mixedTracks: mixedTracks,
            audioMix: audioMix,
            to: outputURL,
            expectedDurationSeconds: anchorDuration.seconds,
            progress: progress
        )
        return AudioMixdownRenderReport(
            outputURL: outputURL,
            voiceProcessingResult: microphone.processingResult,
            voiceProcessingErrorDescription: microphone.processingErrorDescription
        )
    }

    /// Renders the mix offline as plain PCM. The reader applies the audio mix
    /// while decoding, and PCM CAF is the one audio shape composition
    /// insertion accepts everywhere else in this pipeline — an intermediate
    /// AAC m4a export produced tracks that AVMutableComposition rejected on
    /// insertion, so no AAC generation happens before the final encode.
    private static func writeMixedPCM(
        composition: AVMutableComposition,
        mixedTracks: [AVCompositionTrack],
        audioMix: AVMutableAudioMix,
        to outputURL: URL,
        expectedDurationSeconds: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        guard let mixFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ) else {
            throw AudioMixdownRendererError.exportSessionUnavailable
        }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: mixedTracks,
            audioSettings: mixFormat.settings
        )
        output.audioMix = audioMix
        guard reader.canAdd(output) else {
            throw AudioMixdownRendererError.exportSessionUnavailable
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioMixdownRendererError.exportSessionUnavailable
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: mixFormat.settings,
            commonFormat: mixFormat.commonFormat,
            interleaved: mixFormat.isInterleaved
        )
        let expectedFrames = max(expectedDurationSeconds * mixFormat.sampleRate, 1)
        var writtenFrames: AVAudioFramePosition = 0
        var lastProgressReportedAt = Date.distantPast
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let buffer = try AudioSampleBufferPCMConverter.convert(sampleBuffer)
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            if let progress {
                let now = Date()
                if now.timeIntervalSince(lastProgressReportedAt) >= 0.1 {
                    lastProgressReportedAt = now
                    progress(min(Double(writtenFrames) / expectedFrames, 1))
                }
            }
        }
        guard reader.status == .completed, writtenFrames > 0 else {
            throw reader.error ?? AudioMixdownRendererError.missingSystemAudioTrack
        }
        progress?(1)
    }

    private struct PreparedMicrophone {
        let asset: AVAsset?
        /// The conditioned microphone in source time, used for narration
        /// activity analysis; nil when no microphone participates.
        let mixURL: URL?
        let temporaryURLs: [URL]
        let processingResult: VoiceAudioProcessingResult?
        let processingErrorDescription: String?
    }

    private func preparedMicrophone(
        microphoneURL: URL?,
        plan: AutoEditPlan.Audio,
        timeline: VideoEditTimeline?,
        outputDirectory: URL
    ) async throws -> PreparedMicrophone {
        guard let microphoneURL else {
            return PreparedMicrophone(
                asset: nil,
                mixURL: nil,
                temporaryURLs: [],
                processingResult: nil,
                processingErrorDescription: nil
            )
        }
        var processingResult: VoiceAudioProcessingResult?
        var processingErrorDescription: String?
        let conditionedURL = outputDirectory.appendingPathComponent(
            ".conditioned-microphone-\(UUID().uuidString).caf"
        )
        var temporaryURLs = [conditionedURL]
        let mixURL: URL
        if plan.reducesMicrophoneNoise || plan.normalizesLoudness {
            do {
                let result = try await voiceProcessor.process(
                    inputURL: microphoneURL,
                    outputURL: conditionedURL,
                    plan: plan
                )
                processingResult = result
                mixURL = result.outputURL
            } catch {
                processingErrorDescription = error.localizedDescription
                mixURL = microphoneURL
            }
        } else {
            mixURL = microphoneURL
        }
        if let timeline {
            if timeline.hasActiveTransitions {
                let transitionedURL = outputDirectory.appendingPathComponent(
                    ".microphone-transitions-\(UUID().uuidString).m4a"
                )
                _ = try await VideoTimelineCompositionBuilder().export(
                    inputURL: mixURL,
                    timeline: timeline,
                    outputURL: transitionedURL,
                    includesVideo: false,
                    includesAudio: true,
                    requiresAudio: true
                )
                temporaryURLs.append(transitionedURL)
                return PreparedMicrophone(
                    asset: AVURLAsset(url: transitionedURL),
                    mixURL: mixURL,
                    temporaryURLs: temporaryURLs,
                    processingResult: processingResult,
                    processingErrorDescription: processingErrorDescription
                )
            }
            let composition = try await VideoTimelineCompositionBuilder().build(
                inputURL: mixURL,
                timeline: timeline,
                includesVideo: false,
                includesAudio: true,
                requiresAudio: true
            )
            return PreparedMicrophone(
                asset: composition,
                mixURL: mixURL,
                temporaryURLs: temporaryURLs,
                processingResult: processingResult,
                processingErrorDescription: processingErrorDescription
            )
        }
        return PreparedMicrophone(
            asset: AVURLAsset(url: mixURL),
            mixURL: mixURL,
            temporaryURLs: temporaryURLs,
            processingResult: processingResult,
            processingErrorDescription: processingErrorDescription
        )
    }

    /// Loudness normalization and narration ducking for the system-audio
    /// track, shared by the two-pass fallback and the single-pass sidecar.
    private func systemAudioParameters(
        for track: AVMutableCompositionTrack,
        plan: AutoEditPlan.Audio,
        timeline: VideoEditTimeline?,
        microphoneMixURL: URL?,
        loudnessMeasurementURL: URL,
        microphonePresent: Bool,
        durationSeconds: Double
    ) async throws -> AVMutableAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let systemNormalizationGain: Double
        if microphonePresent,
           plan.normalizesLoudness,
           let metrics = try? await voiceProcessor.analyze(url: loudnessMeasurementURL) {
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
        parameters.setVolume(baseVolume, at: .zero)
        if plan.ducksSystemUnderNarration,
           let microphoneMixURL {
            let sourceActivity = try analyzer.analyze(
                url: microphoneMixURL,
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
                durationSeconds: durationSeconds
            )
            for envelope in envelopes {
                Self.apply(
                    envelope,
                    to: parameters,
                    baseVolume: baseVolume,
                    duckedVolume: duckedVolume
                )
            }
        }
        return parameters
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
