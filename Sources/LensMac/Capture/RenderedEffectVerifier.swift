@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import LensCore

/// Verifies that requested visual effects reached the encoded preview, rather
/// than trusting edit-plan values or renderer completion alone.
@MainActor
final class RenderedEffectVerifier {
    private struct SampleCandidate: Hashable {
        let outputTime: Double
        let sourceTime: Double
    }

    private struct PixelComparison {
        let changedPixelCount: Int
        let expectedDifference: Double
        let actualErrorWithEffect: Double
        let actualErrorWithoutEffect: Double
        let effectCorrelation: Double
        let effectProjectionStrength: Double

        var similarityGain: Double {
            (actualErrorWithoutEffect - actualErrorWithEffect)
                / max(expectedDifference, 0.000_001)
        }

        /// Favors a clearly visible footprint rather than a tiny cluster with
        /// unusually high per-pixel contrast (for example a narrow I-beam).
        var visibleDifferenceEnergy: Double {
            Double(changedPixelCount) * expectedDifference
        }
    }

    private struct VisualSample {
        let time: Double
        let comparison: PixelComparison
    }

    private let renderer: AutoPreviewRenderer
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(renderer: AutoPreviewRenderer) {
        self.renderer = renderer
    }

    func validate(
        rawURL: URL,
        previewURL: URL,
        plan: AutoEditPlan,
        cameraURL: URL? = nil,
        microphoneURL: URL? = nil,
        transcript: TranscriptDocument? = nil
    ) async -> RenderedEffectVerificationReport {
        let rawMetrics = await RecordingArtifactValidator.inspectVideo(at: rawURL)
        let previewMetrics = await RecordingArtifactValidator.inspectVideo(at: previewURL)
        let rawFramesPerSecond = rawMetrics?.measuredFramesPerSecond
        let previewFramesPerSecond = previewMetrics?.measuredFramesPerSecond
        let minimumExpectedFramesPerSecond = Self.minimumExpectedFramesPerSecond(
            rawFramesPerSecond: rawFramesPerSecond,
            preset: plan.export?.preset ?? .source
        )

        do {
            let rawAsset = AVURLAsset(url: rawURL)
            let previewAsset = AVURLAsset(url: previewURL)
            let previewDuration = try await previewAsset.load(.duration).seconds
            let previewTracks = try await previewAsset.loadTracks(withMediaType: .video)
            guard previewDuration.isFinite,
                  previewDuration > 0,
                  !previewTracks.isEmpty else {
                return failedReport(
                    plan: plan,
                    rawFramesPerSecond: rawFramesPerSecond,
                    previewFramesPerSecond: previewFramesPerSecond,
                    minimumExpectedFramesPerSecond: minimumExpectedFramesPerSecond,
                    cameraURL: cameraURL,
                    microphoneURL: microphoneURL,
                    transcript: transcript,
                    description: "自动成片没有可解码的视频轨。"
                )
            }

            let rawGenerator = AVAssetImageGenerator(asset: rawAsset)
            rawGenerator.appliesPreferredTrackTransform = true
            rawGenerator.requestedTimeToleranceBefore = .zero
            rawGenerator.requestedTimeToleranceAfter = .zero
            let previewGenerator = AVAssetImageGenerator(asset: previewAsset)
            previewGenerator.appliesPreferredTrackTransform = true
            previewGenerator.requestedTimeToleranceBefore = .zero
            previewGenerator.requestedTimeToleranceAfter = .zero
            let cameraGenerator: AVAssetImageGenerator? = cameraURL.flatMap { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                return generator
            }

            var effects: [RenderedEffectVerification] = []
            for effect in RenderedEffectKind.allCases {
                guard Self.isRequested(
                    effect,
                    in: plan,
                    cameraURL: cameraURL,
                    microphoneURL: microphoneURL,
                    transcript: transcript
                ) else {
                    effects.append(RenderedEffectVerification(
                        effect: effect,
                        state: .notRequested,
                        detail: "当前计划未请求此效果。"
                    ))
                    continue
                }
                if effect == .audioMix {
                    effects.append(await verifyAudioMix(
                        rawURL: rawURL,
                        previewURL: previewURL,
                        microphoneURL: microphoneURL,
                        plan: plan,
                        previewVideoDuration: previewDuration
                    ))
                    continue
                }
                let candidates = Self.sampleCandidates(
                    for: effect,
                    plan: plan,
                    previewDuration: previewDuration,
                    transcript: transcript
                )
                effects.append(await verify(
                    effect: effect,
                    candidates: candidates,
                    plan: plan,
                    rawGenerator: rawGenerator,
                    previewGenerator: previewGenerator,
                    cameraGenerator: cameraGenerator,
                    transcript: transcript,
                    previewDuration: previewDuration
                ))
            }

            return RenderedEffectVerificationReport(
                previewPlayable: true,
                previewDurationSeconds: previewDuration,
                rawMeasuredFramesPerSecond: rawFramesPerSecond,
                previewMeasuredFramesPerSecond: previewFramesPerSecond,
                minimumExpectedFramesPerSecond: minimumExpectedFramesPerSecond,
                effects: effects
            )
        } catch {
            return failedReport(
                plan: plan,
                rawFramesPerSecond: rawFramesPerSecond,
                previewFramesPerSecond: previewFramesPerSecond,
                minimumExpectedFramesPerSecond: minimumExpectedFramesPerSecond,
                cameraURL: cameraURL,
                microphoneURL: microphoneURL,
                transcript: transcript,
                description: error.localizedDescription
            )
        }
    }

    private func verify(
        effect: RenderedEffectKind,
        candidates: [SampleCandidate],
        plan: AutoEditPlan,
        rawGenerator: AVAssetImageGenerator,
        previewGenerator: AVAssetImageGenerator,
        cameraGenerator: AVAssetImageGenerator?,
        transcript: TranscriptDocument?,
        previewDuration: Double
    ) async -> RenderedEffectVerification {
        guard !candidates.isEmpty else {
            return RenderedEffectVerification(
                effect: effect,
                state: .inconclusive,
                detail: "效果已请求，但时间线中没有可验证的可见采样点。"
            )
        }

        var strongest: VisualSample?
        var lastError: Error?
        for candidate in candidates {
            do {
                let requestedOutputTime = min(max(candidate.outputTime, 0), previewDuration)
                let previewSample = try await previewGenerator.image(at: CMTime(
                    seconds: requestedOutputTime,
                    preferredTimescale: 60_000
                ))
                let actualOutputTime = previewSample.actualTime.seconds.isFinite
                    ? previewSample.actualTime.seconds
                    : requestedOutputTime
                let actualSourceTime = plan.timeline?.position(
                    atOutputTime: actualOutputTime
                )?.sourceTimeSeconds ?? candidate.sourceTime
                let rawSample = try await rawGenerator.image(at: CMTime(
                    seconds: max(actualSourceTime, 0),
                    preferredTimescale: 60_000
                ))
                let cameraSample: CGImage? = if let cameraGenerator {
                    try await cameraGenerator.image(at: CMTime(
                        seconds: max(actualSourceTime, 0),
                        preferredTimescale: 60_000
                    )).image
                } else {
                    nil
                }
                let targetSize = Self.diagnosticSize(for: previewSample.image)
                let actualImage = try resized(previewSample.image, to: targetSize)
                // Render at the real capture resolution first, then downscale
                // the expected frame exactly like a viewer. Rendering a 4K
                // source at a synthetic 640 px extent makes cursor minimum-size
                // rules look four times larger and can falsely pass an effect
                // that is imperceptible in the encoded media.
                let fullResolutionWithEffect = try renderExpectedFrame(
                    sourceImage: rawSample.image,
                    cameraImage: cameraSample,
                    outputTime: actualOutputTime,
                    sourceTime: actualSourceTime,
                    plan: plan,
                    transcript: transcript
                )
                let fullResolutionWithoutEffect = try renderExpectedFrame(
                    sourceImage: rawSample.image,
                    cameraImage: cameraSample,
                    outputTime: actualOutputTime,
                    sourceTime: actualSourceTime,
                    plan: Self.disabling(effect, in: plan),
                    transcript: transcript
                )
                let withEffect = try resized(
                    fullResolutionWithEffect,
                    to: targetSize
                )
                let withoutEffect = try resized(
                    fullResolutionWithoutEffect,
                    to: targetSize
                )
                let comparison = try compare(
                    actual: actualImage,
                    withEffect: withEffect,
                    withoutEffect: withoutEffect
                )
                if strongest == nil
                    || comparison.visibleDifferenceEnergy
                        > strongest!.comparison.visibleDifferenceEnergy {
                    strongest = VisualSample(
                        time: actualOutputTime,
                        comparison: comparison
                    )
                }
            } catch {
                lastError = error
            }
        }

        guard let strongest else {
            return RenderedEffectVerification(
                effect: effect,
                state: .failed,
                detail: lastError?.localizedDescription ?? "无法读取验证帧。"
            )
        }
        let comparison = strongest.comparison
        let hasVisibleCounterfactual = comparison.changedPixelCount
            >= Self.minimumChangedPixelCount(for: effect)
            && comparison.expectedDifference >= 0.025
        guard hasVisibleCounterfactual else {
            return RenderedEffectVerification(
                effect: effect,
                state: .inconclusive,
                outputTimeSeconds: strongest.time,
                changedPixelCount: comparison.changedPixelCount,
                expectedDifference: comparison.expectedDifference,
                actualErrorWithEffect: comparison.actualErrorWithEffect,
                actualErrorWithoutEffect: comparison.actualErrorWithoutEffect,
                similarityGain: comparison.similarityGain,
                effectCorrelation: comparison.effectCorrelation,
                effectProjectionStrength: comparison.effectProjectionStrength,
                detail: "开启和关闭的可见差异不足，不能用该帧证明效果。"
            )
        }

        let directSimilarityVerified = comparison.actualErrorWithEffect
            < comparison.actualErrorWithoutEffect
            && comparison.similarityGain >= 0.12
        // H.264 changes the values of anti-aliased glyph edges and translucent
        // glass backgrounds far more than it changes large flat effects. For
        // captions, also require the decoded frame's signed change to point in
        // the same direction as the enabled-vs-disabled counterfactual. This
        // proves presence without pretending a lossy frame is pixel-identical.
        let compressionRobustCaptionVerified = effect == .captions
            && comparison.effectCorrelation >= 0.18
            && comparison.effectProjectionStrength >= 0.12
        let verified = directSimilarityVerified || compressionRobustCaptionVerified
        return RenderedEffectVerification(
            effect: effect,
            state: verified ? .verified : .failed,
            outputTimeSeconds: strongest.time,
            changedPixelCount: comparison.changedPixelCount,
            expectedDifference: comparison.expectedDifference,
            actualErrorWithEffect: comparison.actualErrorWithEffect,
            actualErrorWithoutEffect: comparison.actualErrorWithoutEffect,
            similarityGain: comparison.similarityGain,
            effectCorrelation: comparison.effectCorrelation,
            effectProjectionStrength: comparison.effectProjectionStrength,
            detail: verified
                ? (directSimilarityVerified
                    ? "最终编码帧通过开启/关闭反事实对照。"
                    : "最终编码帧通过压缩鲁棒的反事实方向与强度对照。")
                : "最终编码帧未能证明该效果已生效。"
        )
    }

    private func verifyAudioMix(
        rawURL: URL,
        previewURL: URL,
        microphoneURL: URL?,
        plan: AutoEditPlan,
        previewVideoDuration: Double
    ) async -> RenderedEffectVerification {
        async let outputTask = AudioMediaEvidenceAnalyzer.analyze(url: previewURL)
        async let rawTask = AudioMediaEvidenceAnalyzer.analyze(url: rawURL)
        guard let output = await outputTask else {
            return RenderedEffectVerification(
                effect: .audioMix,
                state: .failed,
                detail: "混音已请求，但最终 MP4 没有可解码音频轨。"
            )
        }
        let raw = await rawTask
        let microphone: AudioMediaEvidence?
        if let microphoneURL {
            microphone = await AudioMediaEvidenceAnalyzer.analyze(url: microphoneURL)
        } else {
            microphone = nil
        }
        let durationDrift = abs(output.durationSeconds - previewVideoDuration)
        guard durationDrift <= 0.15 else {
            return RenderedEffectVerification(
                effect: .audioMix,
                state: .failed,
                comparedAudioSampleCount: output.samples.count,
                outputAudioRMS: output.rootMeanSquare,
                referenceAudioRMS: raw?.rootMeanSquare,
                audioDurationDriftSeconds: durationDrift,
                detail: String(
                    format: "最终音轨与视频相差 %.3f 秒，超过 0.15 秒门槛。",
                    durationDrift
                )
            )
        }
        let difference = raw.flatMap {
            AudioMediaEvidenceAnalyzer.meanAbsoluteDifference(
                output.samples,
                $0.samples
            )
        }
        let comparedSampleCount = min(output.samples.count, raw?.samples.count ?? 0)
        guard let audioPlan = plan.audio else {
            return RenderedEffectVerification(
                effect: .audioMix,
                state: .failed,
                detail: "混音计划缺失。"
            )
        }

        if microphoneURL == nil {
            guard let raw, raw.rootMeanSquare > 0.000_01 else {
                return RenderedEffectVerification(
                    effect: .audioMix,
                    state: .inconclusive,
                    comparedAudioSampleCount: comparedSampleCount,
                    outputAudioRMS: output.rootMeanSquare,
                    audioDifference: difference,
                    audioDurationDriftSeconds: durationDrift,
                    detail: "系统声采样为静音，无法证明音量倍率。"
                )
            }
            let measuredRatio = output.rootMeanSquare / raw.rootMeanSquare
            let expectedRatio = audioPlan.systemVolume
            let tolerance = max(0.10, expectedRatio * 0.25)
            let verified = abs(measuredRatio - expectedRatio) <= tolerance
            return RenderedEffectVerification(
                effect: .audioMix,
                state: verified ? .verified : .failed,
                comparedAudioSampleCount: comparedSampleCount,
                outputAudioRMS: output.rootMeanSquare,
                referenceAudioRMS: raw.rootMeanSquare,
                audioDifference: difference,
                audioDurationDriftSeconds: durationDrift,
                detail: String(
                    format: verified
                        ? "最终音轨响度倍率 %.3f，与请求 %.3f 一致。"
                        : "最终音轨响度倍率 %.3f，未达到请求 %.3f。",
                    measuredRatio,
                    expectedRatio
                )
            )
        }

        let microphoneIsAudible = (microphone?.rootMeanSquare ?? 0) > 0.000_5
            && audioPlan.microphoneVolume > 0.000_1
        let audibleDifference: Bool
        if let raw {
            audibleDifference = (difference ?? 0) > max(
                0.001_5,
                min(microphone?.rootMeanSquare ?? 0, 0.05) * 0.04
            ) || abs(output.rootMeanSquare - raw.rootMeanSquare) > 0.001
        } else {
            audibleDifference = output.rootMeanSquare > 0.000_3
        }
        let verified = !microphoneIsAudible || audibleDifference
        let detail: String
        if !microphoneIsAudible {
            detail = "麦克风采样为静音；最终音轨存在且与视频时长对齐。"
        } else if verified {
            detail = "最终 PCM 与系统声反事实不同，麦克风混音已进入成片。"
        } else {
            detail = "麦克风有有效信号，但最终 PCM 未检测到可辨混音差异。"
        }
        return RenderedEffectVerification(
            effect: .audioMix,
            state: verified ? .verified : .failed,
            comparedAudioSampleCount: comparedSampleCount,
            outputAudioRMS: output.rootMeanSquare,
            referenceAudioRMS: raw?.rootMeanSquare ?? microphone?.rootMeanSquare,
            audioDifference: difference,
            audioDurationDriftSeconds: durationDrift,
            detail: detail
        )
    }

    private func renderExpectedFrame(
        sourceImage: CGImage,
        cameraImage: CGImage?,
        outputTime: Double,
        sourceTime: Double,
        plan: AutoEditPlan,
        transcript: TranscriptDocument?
    ) throws -> CGImage {
        let screen = try renderer.renderDiagnosticFrame(
            sourceImage: sourceImage,
            outputTime: outputTime,
            plan: plan,
            transcript: transcript,
            hasPresenterCamera: cameraImage != nil
        )
        guard let layout = plan.presenterCamera,
              layout.isEnabled,
              let cameraImage else { return screen }
        let extent = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        let captionCues: [CaptionCue] = {
            guard let configuration = plan.captions,
                  configuration.isEnabled,
                  let transcript else { return [] }
            return CaptionCuePlanner.cues(
                transcript: transcript,
                configuration: configuration,
                timeline: plan.timeline
            )
        }()
        let captionAmount = CaptionCuePlanner.avoidanceAmount(
            at: outputTime,
            in: captionCues
        )
        let activeCaptions = captionAmount > 0.001 ? plan.captions : nil
        let frameState = PresenterCameraPlacementPlanner.state(
            atSourceTime: sourceTime,
            layout: layout,
            cameraKeyframes: EffectTimeline.effectiveCameraKeyframes(
                for: plan.camera
            ),
            captions: activeCaptions,
            captionAvoidanceAmount: captionAmount,
            canvasAspectRatio: extent.width / max(extent.height, 1)
        )
        let composed = PresenterCameraRenderer.compose(
            screen: CIImage(cgImage: screen),
            camera: CIImage(cgImage: cameraImage),
            layout: layout,
            outputExtent: extent,
            frameState: frameState
        )
        guard let image = imageContext.createCGImage(composed, from: extent) else {
            throw NSError(
                domain: "Lens.RenderedEffectVerifier",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法生成摄像头反事实验证帧。"]
            )
        }
        return image
    }

    private func compare(
        actual: CGImage,
        withEffect: CGImage,
        withoutEffect: CGImage
    ) throws -> PixelComparison {
        let width = min(actual.width, min(withEffect.width, withoutEffect.width))
        let height = min(actual.height, min(withEffect.height, withoutEffect.height))
        guard width > 0, height > 0 else {
            throw NSError(
                domain: "Lens.RenderedEffectVerifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "验证帧尺寸无效。"]
            )
        }
        let actualBytes = try rgbaBytes(actual, width: width, height: height)
        let withBytes = try rgbaBytes(withEffect, width: width, height: height)
        let withoutBytes = try rgbaBytes(withoutEffect, width: width, height: height)
        var changedPixelCount = 0
        var expectedDifference = 0.0
        var actualErrorWithEffect = 0.0
        var actualErrorWithoutEffect = 0.0
        var effectDotProduct = 0.0
        var expectedEffectEnergy = 0.0
        var actualEffectEnergy = 0.0
        for offset in stride(from: 0, to: actualBytes.count, by: 4) {
            let effectDifference = (
                abs(Double(withBytes[offset]) - Double(withoutBytes[offset]))
                    + abs(Double(withBytes[offset + 1]) - Double(withoutBytes[offset + 1]))
                    + abs(Double(withBytes[offset + 2]) - Double(withoutBytes[offset + 2]))
            ) / 765
            guard effectDifference >= 0.02 else { continue }
            changedPixelCount += 1
            expectedDifference += effectDifference
            actualErrorWithEffect += (
                abs(Double(actualBytes[offset]) - Double(withBytes[offset]))
                    + abs(Double(actualBytes[offset + 1]) - Double(withBytes[offset + 1]))
                    + abs(Double(actualBytes[offset + 2]) - Double(withBytes[offset + 2]))
            ) / 765
            actualErrorWithoutEffect += (
                abs(Double(actualBytes[offset]) - Double(withoutBytes[offset]))
                    + abs(Double(actualBytes[offset + 1]) - Double(withoutBytes[offset + 1]))
                    + abs(Double(actualBytes[offset + 2]) - Double(withoutBytes[offset + 2]))
            ) / 765
            for channel in 0..<3 {
                let expectedDelta = (
                    Double(withBytes[offset + channel])
                        - Double(withoutBytes[offset + channel])
                ) / 255
                let actualDelta = (
                    Double(actualBytes[offset + channel])
                        - Double(withoutBytes[offset + channel])
                ) / 255
                effectDotProduct += expectedDelta * actualDelta
                expectedEffectEnergy += expectedDelta * expectedDelta
                actualEffectEnergy += actualDelta * actualDelta
            }
        }
        let divisor = Double(max(changedPixelCount, 1))
        let correlationDenominator = sqrt(
            expectedEffectEnergy * actualEffectEnergy
        )
        return PixelComparison(
            changedPixelCount: changedPixelCount,
            expectedDifference: expectedDifference / divisor,
            actualErrorWithEffect: actualErrorWithEffect / divisor,
            actualErrorWithoutEffect: actualErrorWithoutEffect / divisor,
            effectCorrelation: correlationDenominator > 0.000_001
                ? effectDotProduct / correlationDenominator
                : 0,
            effectProjectionStrength: expectedEffectEnergy > 0.000_001
                ? effectDotProduct / expectedEffectEnergy
                : 0
        )
    }

    private func resized(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let target = CGRect(origin: .zero, size: size)
        let source = CIImage(cgImage: image)
        let transform = CGAffineTransform(
            scaleX: target.width / CGFloat(image.width),
            y: target.height / CGFloat(image.height)
        )
        guard let rendered = imageContext.createCGImage(
            source.transformed(by: transform).cropped(to: target),
            from: target
        ) else {
            throw NSError(
                domain: "Lens.RenderedEffectVerifier",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法缩放验证帧。"]
            )
        }
        return rendered
    }

    private func rgbaBytes(
        _ image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "Lens.RenderedEffectVerifier",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法读取验证帧像素。"]
            )
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private func failedReport(
        plan: AutoEditPlan,
        rawFramesPerSecond: Double?,
        previewFramesPerSecond: Double?,
        minimumExpectedFramesPerSecond: Double?,
        cameraURL: URL?,
        microphoneURL: URL?,
        transcript: TranscriptDocument?,
        description: String
    ) -> RenderedEffectVerificationReport {
        RenderedEffectVerificationReport(
            previewPlayable: false,
            previewDurationSeconds: nil,
            rawMeasuredFramesPerSecond: rawFramesPerSecond,
            previewMeasuredFramesPerSecond: previewFramesPerSecond,
            minimumExpectedFramesPerSecond: minimumExpectedFramesPerSecond,
            effects: RenderedEffectKind.allCases.map { effect in
                RenderedEffectVerification(
                    effect: effect,
                    state: Self.isRequested(
                        effect,
                        in: plan,
                        cameraURL: cameraURL,
                        microphoneURL: microphoneURL,
                        transcript: transcript
                    ) ? .failed : .notRequested,
                    detail: description
                )
            },
            failureDescription: description
        )
    }

    private static func disabling(
        _ effect: RenderedEffectKind,
        in plan: AutoEditPlan
    ) -> AutoEditPlan {
        var counterfactual = plan
        switch effect {
        case .automaticCamera:
            counterfactual.camera.mode = "off"
        case .cursor:
            counterfactual.cursor.isEnabled = false
        case .clickFeedback:
            counterfactual.interaction?.showsClickPulse = false
        case .canvas:
            counterfactual.canvas?.isEnabled = false
        case .presenterCamera:
            counterfactual.presenterCamera?.isEnabled = false
        case .captions:
            counterfactual.captions?.isEnabled = false
        case .videoAnnotation:
            counterfactual.videoAnnotations = []
        case .audioMix:
            counterfactual.audio?.isEnabled = false
        }
        return counterfactual
    }

    private static func isRequested(
        _ effect: RenderedEffectKind,
        in plan: AutoEditPlan,
        cameraURL: URL?,
        microphoneURL: URL?,
        transcript: TranscriptDocument?
    ) -> Bool {
        switch effect {
        case .automaticCamera:
            return plan.camera.mode != "off"
                && EffectTimeline.effectiveCameraKeyframes(for: plan.camera).contains {
                    $0.reason != .baseline
                        && ($0.scale > 1.001
                            || abs($0.center.x - 0.5) > 0.001
                            || abs($0.center.y - 0.5) > 0.001)
                }
        case .cursor:
            return (plan.cursor.isEnabled ?? true) && !plan.cursor.keyframes.isEmpty
        case .clickFeedback:
            return plan.interaction?.showsClickPulse == true
                && plan.interaction?.clickPulses.isEmpty == false
        case .canvas:
            return plan.canvas?.isEnabled == true
        case .presenterCamera:
            return plan.presenterCamera?.isEnabled == true && cameraURL != nil
        case .captions:
            return plan.captions?.isEnabled == true
                && transcript?.segments.isEmpty == false
        case .videoAnnotation:
            return plan.videoAnnotations?.isEmpty == false
        case .audioMix:
            guard let audio = plan.audio else { return false }
            return AudioMixdownRenderer.requiresMixdown(
                microphoneURL: microphoneURL,
                plan: audio
            )
        }
    }

    private static func sampleCandidates(
        for effect: RenderedEffectKind,
        plan: AutoEditPlan,
        previewDuration: Double,
        transcript: TranscriptDocument?
    ) -> [SampleCandidate] {
        let sourceTimes: [Double]
        switch effect {
        case .automaticCamera:
            sourceTimes = EffectTimeline.effectiveCameraKeyframes(for: plan.camera)
                .filter { $0.reason != .baseline }
                .map(\.time)
        case .cursor:
            sourceTimes = plan.cursor.keyframes.map(\.time)
        case .clickFeedback:
            let duration = plan.interaction?.clickPulseDuration ?? 0.55
            sourceTimes = plan.interaction?.clickPulses.map {
                $0.time + min(duration * 0.24, 0.14)
            } ?? []
        case .canvas:
            let outputTimes = [min(0.16, previewDuration * 0.25), previewDuration * 0.5]
            return outputTimes.compactMap { outputTime in
                guard outputTime >= 0, outputTime < previewDuration else { return nil }
                let sourceTime = plan.timeline?.position(atOutputTime: outputTime)?
                    .sourceTimeSeconds ?? outputTime
                return SampleCandidate(outputTime: outputTime, sourceTime: sourceTime)
            }
        case .presenterCamera:
            let authored = plan.presenterCamera?.keyframes.map(\.sourceTimeSeconds) ?? []
            sourceTimes = authored.isEmpty
                ? [min(0.18, previewDuration * 0.25), previewDuration * 0.5]
                : authored
        case .captions:
            guard let configuration = plan.captions,
                  let transcript else { return [] }
            return CaptionCuePlanner.cues(
                transcript: transcript,
                configuration: configuration,
                timeline: plan.timeline
            ).compactMap { cue in
                let outputTime = (cue.startSeconds + cue.endSeconds) / 2
                guard outputTime >= 0, outputTime < previewDuration else { return nil }
                let sourceTime = plan.timeline?.position(atOutputTime: outputTime)?
                    .sourceTimeSeconds ?? outputTime
                return SampleCandidate(outputTime: outputTime, sourceTime: sourceTime)
            }
        case .videoAnnotation:
            sourceTimes = plan.videoAnnotations?.map {
                ($0.sourceStartSeconds + $0.sourceEndSeconds) / 2
            } ?? []
        case .audioMix:
            return []
        }
        let candidates = sourceTimes.flatMap { sourceTime -> [SampleCandidate] in
            let outputTimes = plan.timeline?.outputTimes(forSourceTime: sourceTime)
                ?? [sourceTime]
            return outputTimes.compactMap { outputTime in
                guard outputTime >= 0, outputTime < previewDuration else { return nil }
                return SampleCandidate(outputTime: outputTime, sourceTime: sourceTime)
            }
        }
        let unique = Array(Set(candidates)).sorted { $0.outputTime < $1.outputTime }
        guard unique.count > 6 else { return unique }
        let indexes = [0, unique.count / 5, unique.count * 2 / 5,
                       unique.count * 3 / 5, unique.count * 4 / 5, unique.count - 1]
        return indexes.map { unique[$0] }
    }

    private static func diagnosticSize(for image: CGImage) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let maximumDimension: CGFloat = 640
        let scale = min(maximumDimension / max(width, height), 1)
        return CGSize(
            width: max((width * scale).rounded(), 1),
            height: max((height * scale).rounded(), 1)
        )
    }

    private static func minimumChangedPixelCount(for effect: RenderedEffectKind) -> Int {
        switch effect {
        case .automaticCamera: 800
        case .cursor: 72
        case .clickFeedback: 36
        case .canvas: 800
        case .presenterCamera: 800
        case .captions: 72
        case .videoAnnotation: 72
        case .audioMix: 0
        }
    }

    private static func minimumExpectedFramesPerSecond(
        rawFramesPerSecond: Double?,
        preset: AutoEditPlan.Export.Preset
    ) -> Double? {
        guard let rawFramesPerSecond, rawFramesPerSecond > 0 else { return nil }
        switch preset {
        case .source:
            return rawFramesPerSecond >= 58 ? 58 : rawFramesPerSecond * 0.95
        case .balanced:
            return min(rawFramesPerSecond, 30) * 0.95
        case .compact:
            return min(rawFramesPerSecond, 24) * 0.95
        }
    }
}
