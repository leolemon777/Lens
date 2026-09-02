import Foundation

public enum RecordingComponentStatus: String, Codable, Equatable, Sendable {
    case healthy
    case degraded
    case failed
    case notRequested
    case notMeasured
}

public enum RecordingHealthWarning: String, Codable, Equatable, Hashable, Sendable {
    case measuredFrameRateBelowRequest
    case highFrameIntervalVariance
    case droppedVideoFrames
    case eventCaptureDegraded
    case pointerTrackEmpty
    case clickTrackEmpty
    case automaticCameraNotGenerated
    case cursorPlanNotGenerated
    case clickEffectsNotGenerated
    case cameraMotionMayCauseDiscomfort
    case renderedPreviewUnavailable
    case renderedFrameRateBelowExpectation
    case renderedEffectNotVerified
    case requestedMediaTrackMissing
    case rawTrackDurationDrift
    case rawTrackStartOffset
    case microphoneInterrupted
    case cameraInterrupted
}

public enum RecordingRawTrackKind: String, Codable, CaseIterable, Hashable, Sendable {
    case systemAudio
    case microphone
    case camera

    public var title: String {
        switch self {
        case .systemAudio: "系统声"
        case .microphone: "麦克风"
        case .camera: "摄像头"
        }
    }
}

/// Evidence from the physical raw tracks after recording finalization. This is
/// intentionally separate from edit-plan and preview evidence: a requested
/// microphone/camera track must exist and stay aligned with the screen track
/// before any automatic effect can truthfully claim success.
public struct RecordingTrackIntegrityReport: Codable, Equatable, Sendable {
    public let screenVideoDurationSeconds: Double?
    public let systemAudioDurationSeconds: Double?
    public let microphoneDurationSeconds: Double?
    public let cameraDurationSeconds: Double?
    public let requestedSystemAudio: Bool
    public let requestedMicrophone: Bool
    public let requestedCamera: Bool
    public let durationToleranceSeconds: Double
    public let systemAudioStartOffsetSeconds: Double?
    public let microphoneStartOffsetSeconds: Double?
    public let cameraStartOffsetSeconds: Double?

    public init(
        screenVideoDurationSeconds: Double?,
        systemAudioDurationSeconds: Double?,
        microphoneDurationSeconds: Double?,
        cameraDurationSeconds: Double?,
        requestedSystemAudio: Bool,
        requestedMicrophone: Bool,
        requestedCamera: Bool,
        durationToleranceSeconds: Double = 0.15,
        systemAudioStartOffsetSeconds: Double? = nil,
        microphoneStartOffsetSeconds: Double? = nil,
        cameraStartOffsetSeconds: Double? = nil
    ) {
        self.screenVideoDurationSeconds = Self.positive(screenVideoDurationSeconds)
        self.systemAudioDurationSeconds = Self.positive(systemAudioDurationSeconds)
        self.microphoneDurationSeconds = Self.positive(microphoneDurationSeconds)
        self.cameraDurationSeconds = Self.positive(cameraDurationSeconds)
        self.requestedSystemAudio = requestedSystemAudio
        self.requestedMicrophone = requestedMicrophone
        self.requestedCamera = requestedCamera
        self.durationToleranceSeconds = max(
            durationToleranceSeconds.isFinite ? durationToleranceSeconds : 0.15,
            0
        )
        self.systemAudioStartOffsetSeconds = Self.finite(systemAudioStartOffsetSeconds)
        self.microphoneStartOffsetSeconds = Self.finite(microphoneStartOffsetSeconds)
        self.cameraStartOffsetSeconds = Self.finite(cameraStartOffsetSeconds)
    }

    public var missingRequestedTracks: [RecordingRawTrackKind] {
        [
            requestedSystemAudio && systemAudioDurationSeconds == nil
                ? .systemAudio : nil,
            requestedMicrophone && microphoneDurationSeconds == nil
                ? .microphone : nil,
            requestedCamera && cameraDurationSeconds == nil
                ? .camera : nil
        ].compactMap { $0 }
    }

    public var outOfSyncTracks: [RecordingRawTrackKind] {
        guard let screenVideoDurationSeconds else { return [] }
        return [
            drifted(
                .systemAudio,
                duration: systemAudioDurationSeconds,
                requested: requestedSystemAudio,
                screenDuration: screenVideoDurationSeconds
            ),
            drifted(
                .microphone,
                duration: microphoneDurationSeconds,
                requested: requestedMicrophone,
                screenDuration: screenVideoDurationSeconds
            ),
            drifted(
                .camera,
                duration: cameraDurationSeconds,
                requested: requestedCamera,
                screenDuration: screenVideoDurationSeconds
            )
        ].compactMap { $0 }
    }

    public var maximumDurationDriftSeconds: Double? {
        guard let screenVideoDurationSeconds else { return nil }
        let durations = [
            requestedSystemAudio ? systemAudioDurationSeconds : nil,
            requestedMicrophone ? microphoneDurationSeconds : nil,
            requestedCamera ? cameraDurationSeconds : nil
        ].compactMap { $0 }
        return durations.map { abs($0 - screenVideoDurationSeconds) }.max()
    }

    public var startOffsetTracks: [RecordingRawTrackKind] {
        [
            offset(.systemAudio, offset: systemAudioStartOffsetSeconds, requested: requestedSystemAudio),
            offset(.microphone, offset: microphoneStartOffsetSeconds, requested: requestedMicrophone),
            offset(.camera, offset: cameraStartOffsetSeconds, requested: requestedCamera)
        ].compactMap { $0 }
    }

    public var isVerified: Bool {
        screenVideoDurationSeconds != nil
            && missingRequestedTracks.isEmpty
            && outOfSyncTracks.isEmpty
            && startOffsetTracks.isEmpty
    }

    private func drifted(
        _ track: RecordingRawTrackKind,
        duration: Double?,
        requested: Bool,
        screenDuration: Double
    ) -> RecordingRawTrackKind? {
        guard requested, let duration else { return nil }
        return abs(duration - screenDuration) > durationToleranceSeconds
            ? track
            : nil
    }

    private func offset(
        _ track: RecordingRawTrackKind,
        offset: Double?,
        requested: Bool
    ) -> RecordingRawTrackKind? {
        guard requested, let offset else { return nil }
        return abs(offset) > durationToleranceSeconds ? track : nil
    }

    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }
}

public enum RenderedEffectKind: String, Codable, CaseIterable, Sendable {
    case automaticCamera
    case cursor
    case clickFeedback
    case canvas
    case presenterCamera
    case captions
    case videoAnnotation
    case audioMix

    public var title: String {
        switch self {
        case .automaticCamera: "自动运镜"
        case .cursor: "光标"
        case .clickFeedback: "点击反馈"
        case .canvas: "背景画布"
        case .presenterCamera: "摄像头画中画"
        case .captions: "字幕"
        case .videoAnnotation: "视频标注"
        case .audioMix: "音频混音"
        }
    }
}

public enum RenderedEffectVerificationState: String, Codable, Sendable {
    case verified
    case notRequested
    case inconclusive
    case failed
}

/// Media-level evidence that one requested effect reached the encoded preview.
/// The verifier renders the same decoded source frame twice, with only this
/// effect toggled, then checks which counterfactual the final encoded frame
/// actually resembles. Counts and edit-plan values alone are not sufficient.
public struct RenderedEffectVerification: Codable, Equatable, Sendable {
    public let effect: RenderedEffectKind
    public let state: RenderedEffectVerificationState
    public let outputTimeSeconds: Double?
    public let changedPixelCount: Int
    public let expectedDifference: Double
    public let actualErrorWithEffect: Double?
    public let actualErrorWithoutEffect: Double?
    public let similarityGain: Double?
    /// Cosine similarity between the decoded final-media change vector and
    /// the renderer's enabled-vs-disabled counterfactual. This remains useful
    /// when lossy video encoding changes anti-aliased text edge values.
    public let effectCorrelation: Double?
    /// Signed amount of the expected effect retained in decoded final media.
    /// A value near zero means the requested effect is absent.
    public let effectProjectionStrength: Double?
    public let comparedAudioSampleCount: Int?
    public let outputAudioRMS: Double?
    public let referenceAudioRMS: Double?
    public let audioDifference: Double?
    public let audioDurationDriftSeconds: Double?
    public let detail: String?

    public init(
        effect: RenderedEffectKind,
        state: RenderedEffectVerificationState,
        outputTimeSeconds: Double? = nil,
        changedPixelCount: Int = 0,
        expectedDifference: Double = 0,
        actualErrorWithEffect: Double? = nil,
        actualErrorWithoutEffect: Double? = nil,
        similarityGain: Double? = nil,
        effectCorrelation: Double? = nil,
        effectProjectionStrength: Double? = nil,
        comparedAudioSampleCount: Int? = nil,
        outputAudioRMS: Double? = nil,
        referenceAudioRMS: Double? = nil,
        audioDifference: Double? = nil,
        audioDurationDriftSeconds: Double? = nil,
        detail: String? = nil
    ) {
        self.effect = effect
        self.state = state
        self.outputTimeSeconds = Self.finiteNonnegative(outputTimeSeconds)
        self.changedPixelCount = max(changedPixelCount, 0)
        self.expectedDifference = Self.finiteNonnegative(expectedDifference) ?? 0
        self.actualErrorWithEffect = Self.finiteNonnegative(actualErrorWithEffect)
        self.actualErrorWithoutEffect = Self.finiteNonnegative(actualErrorWithoutEffect)
        self.similarityGain = similarityGain.flatMap { $0.isFinite ? $0 : nil }
        self.effectCorrelation = effectCorrelation.flatMap { $0.isFinite ? $0 : nil }
        self.effectProjectionStrength = effectProjectionStrength.flatMap {
            $0.isFinite ? $0 : nil
        }
        self.comparedAudioSampleCount = comparedAudioSampleCount.map { max($0, 0) }
        self.outputAudioRMS = Self.finiteNonnegative(outputAudioRMS)
        self.referenceAudioRMS = Self.finiteNonnegative(referenceAudioRMS)
        self.audioDifference = Self.finiteNonnegative(audioDifference)
        self.audioDurationDriftSeconds = Self.finiteNonnegative(
            audioDurationDriftSeconds
        )
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

public struct RenderedEffectVerificationReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let previewPlayable: Bool
    public let previewDurationSeconds: Double?
    public let rawMeasuredFramesPerSecond: Double?
    public let previewMeasuredFramesPerSecond: Double?
    public let minimumExpectedFramesPerSecond: Double?
    public let effects: [RenderedEffectVerification]
    public let failureDescription: String?

    public init(
        generatedAt: Date = Date(),
        previewPlayable: Bool,
        previewDurationSeconds: Double?,
        rawMeasuredFramesPerSecond: Double?,
        previewMeasuredFramesPerSecond: Double?,
        minimumExpectedFramesPerSecond: Double?,
        effects: [RenderedEffectVerification],
        failureDescription: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.previewPlayable = previewPlayable
        self.previewDurationSeconds = Self.positive(previewDurationSeconds)
        self.rawMeasuredFramesPerSecond = Self.positive(rawMeasuredFramesPerSecond)
        self.previewMeasuredFramesPerSecond = Self.positive(
            previewMeasuredFramesPerSecond
        )
        self.minimumExpectedFramesPerSecond = Self.positive(
            minimumExpectedFramesPerSecond
        )
        var unique: [RenderedEffectKind: RenderedEffectVerification] = [:]
        for effect in effects {
            unique[effect.effect] = effect
        }
        self.effects = RenderedEffectKind.allCases.compactMap { unique[$0] }
        self.failureDescription = failureDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isFrameRateVerified: Bool {
        guard previewPlayable else { return false }
        guard let minimumExpectedFramesPerSecond else { return true }
        return (previewMeasuredFramesPerSecond ?? 0) >= minimumExpectedFramesPerSecond
    }

    public var allRequestedEffectsVerified: Bool {
        effects.allSatisfy {
            $0.state == .verified || $0.state == .notRequested
        }
    }

    public var isVerified: Bool {
        previewPlayable && isFrameRateVerified && allRequestedEffectsVerified
    }

    public var verifiedEffects: [RenderedEffectKind] {
        effects.compactMap { $0.state == .verified ? $0.effect : nil }
    }

    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

public struct RecordingHealthReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.4"

    public let schemaVersion: String
    public let generatedAt: Date
    public let requestedFramesPerSecond: Int
    public let measuredFramesPerSecond: Double?
    public let p95FrameIntervalMilliseconds: Double?
    public let droppedFrameCount: Int
    public let videoStatus: RecordingComponentStatus
    public let eventStatus: RecordingComponentStatus
    public let pointerEventCount: Int
    public let clickEventCount: Int
    public let keyboardEventCount: Int
    public let windowEventCount: Int
    public let effectiveCameraKeyframeCount: Int
    public let cursorKeyframeCount: Int
    public let clickPulseCount: Int
    public let cameraMotionComfort: CameraMotionComfortReport?
    public let rawTrackIntegrity: RecordingTrackIntegrityReport?
    public let renderedEffectVerification: RenderedEffectVerificationReport?
    /// SHA-256 of the exact edit plan and caption source used to produce the
    /// verified preview. Nil identifies legacy evidence that must not authorize
    /// exporting a potentially stale render.
    public let renderedPlanDigest: String?
    public let warnings: [RecordingHealthWarning]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        generatedAt: Date = Date(),
        requestedFramesPerSecond: Int,
        measuredFramesPerSecond: Double?,
        p95FrameIntervalMilliseconds: Double?,
        droppedFrameCount: Int,
        videoStatus: RecordingComponentStatus,
        eventStatus: RecordingComponentStatus,
        pointerEventCount: Int,
        clickEventCount: Int,
        keyboardEventCount: Int,
        windowEventCount: Int,
        effectiveCameraKeyframeCount: Int,
        cursorKeyframeCount: Int,
        clickPulseCount: Int,
        cameraMotionComfort: CameraMotionComfortReport? = nil,
        rawTrackIntegrity: RecordingTrackIntegrityReport? = nil,
        renderedEffectVerification: RenderedEffectVerificationReport? = nil,
        renderedPlanDigest: String? = nil,
        warnings: [RecordingHealthWarning]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.requestedFramesPerSecond = max(requestedFramesPerSecond, 1)
        self.measuredFramesPerSecond = measuredFramesPerSecond.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.p95FrameIntervalMilliseconds = p95FrameIntervalMilliseconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.droppedFrameCount = max(droppedFrameCount, 0)
        self.videoStatus = videoStatus
        self.eventStatus = eventStatus
        self.pointerEventCount = max(pointerEventCount, 0)
        self.clickEventCount = max(clickEventCount, 0)
        self.keyboardEventCount = max(keyboardEventCount, 0)
        self.windowEventCount = max(windowEventCount, 0)
        self.effectiveCameraKeyframeCount = max(effectiveCameraKeyframeCount, 0)
        self.cursorKeyframeCount = max(cursorKeyframeCount, 0)
        self.clickPulseCount = max(clickPulseCount, 0)
        self.cameraMotionComfort = cameraMotionComfort
        self.rawTrackIntegrity = rawTrackIntegrity
        self.renderedEffectVerification = renderedEffectVerification
        self.renderedPlanDigest = renderedPlanDigest?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
        self.warnings = Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }
    }

    public func addingRenderedEffectVerification(
        _ verification: RenderedEffectVerificationReport,
        renderedPlanDigest: String? = nil
    ) -> Self {
        var updatedWarnings = warnings.filter {
            $0 != .renderedPreviewUnavailable
                && $0 != .renderedFrameRateBelowExpectation
                && $0 != .renderedEffectNotVerified
        }
        if !verification.previewPlayable {
            updatedWarnings.append(.renderedPreviewUnavailable)
        }
        if !verification.isFrameRateVerified {
            updatedWarnings.append(.renderedFrameRateBelowExpectation)
        }
        if !verification.allRequestedEffectsVerified {
            updatedWarnings.append(.renderedEffectNotVerified)
        }
        return Self(
            schemaVersion: Self.currentSchemaVersion,
            generatedAt: generatedAt,
            requestedFramesPerSecond: requestedFramesPerSecond,
            measuredFramesPerSecond: measuredFramesPerSecond,
            p95FrameIntervalMilliseconds: p95FrameIntervalMilliseconds,
            droppedFrameCount: droppedFrameCount,
            videoStatus: videoStatus,
            eventStatus: eventStatus,
            pointerEventCount: pointerEventCount,
            clickEventCount: clickEventCount,
            keyboardEventCount: keyboardEventCount,
            windowEventCount: windowEventCount,
            effectiveCameraKeyframeCount: effectiveCameraKeyframeCount,
            cursorKeyframeCount: cursorKeyframeCount,
            clickPulseCount: clickPulseCount,
            cameraMotionComfort: cameraMotionComfort,
            rawTrackIntegrity: rawTrackIntegrity,
            renderedEffectVerification: verification,
            renderedPlanDigest: renderedPlanDigest,
            warnings: updatedWarnings
        )
    }

    public var completedSmartEffects: [String] {
        if let renderedEffectVerification {
            return renderedEffectVerification.verifiedEffects.map(\.title)
        }
        return [
            effectiveCameraKeyframeCount > 0 ? "自动运镜" : nil,
            cursorKeyframeCount > 0 ? "平滑光标" : nil,
            clickPulseCount > 0 ? "点击反馈" : nil
        ].compactMap { $0 }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
