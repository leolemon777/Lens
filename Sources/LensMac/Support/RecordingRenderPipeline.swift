import Foundation
import LensCore

/// Media inputs passed from AppDelegate's orchestration layer to the render
/// implementation. Loading the plan and project documents stays at the
/// boundary so this worker never owns UI or project publication.
struct RecordingRenderPipelineRequest: Sendable {
    let saved: SavedLens
    let plan: AutoEditPlan
    let existingHealthReport: RecordingHealthReport?
    let cameraURL: URL?
    let microphoneURL: URL?
    let transcript: TranscriptDocument?
    let workingOutputURL: URL
    let taskToken: RecordingTaskToken

    init(
        saved: SavedLens,
        plan: AutoEditPlan,
        existingHealthReport: RecordingHealthReport?,
        cameraURL: URL?,
        microphoneURL: URL?,
        transcript: TranscriptDocument?,
        workingOutputURL: URL,
        taskToken: RecordingTaskToken
    ) {
        self.saved = saved
        self.plan = plan
        self.existingHealthReport = existingHealthReport
        self.cameraURL = cameraURL
        self.microphoneURL = microphoneURL
        self.transcript = transcript
        self.workingOutputURL = workingOutputURL
        self.taskToken = taskToken
    }
}

/// Result of the media part of post-recording processing. Publication and
/// user-facing delivery remain in AppDelegate so a failed or superseded render
/// cannot alter the currently published project.
struct RecordingRenderPipelineResult: Sendable {
    let healthReport: RecordingHealthReport
    let renderedEffectVerification: RenderedEffectVerificationReport
    let microphoneWasMixed: Bool
    let voiceProcessingFellBack: Bool
    let audioMixErrorDescription: String?
    let presenterWasRendered: Bool
    let renderEncodePassCount: Int
    let renderElapsedMilliseconds: Double
    let renderPeakPhysicalFootprintBytes: UInt64
}

@MainActor
final class RecordingRenderPipeline {
    typealias PhaseAdvancer = @MainActor @Sendable (
        RecordingTaskToken,
        RecordingTaskPhase
    ) async -> Void
    typealias ProgressReporter = @MainActor @Sendable (
        Double,
        SavedLens
    ) -> Void
    typealias DiagnosticRecorder = @MainActor @Sendable (
        String,
        DiagnosticLevel,
        [String: String]
    ) -> Void

    private let audioMixdownRenderer: AudioMixdownRenderer
    private let previewRenderer: AutoPreviewRenderer
    private let renderedEffectVerifier: RenderedEffectVerifier
    private let advancePhase: PhaseAdvancer
    private let reportProgress: ProgressReporter
    private let recordDiagnostic: DiagnosticRecorder

    init(
        audioMixdownRenderer: AudioMixdownRenderer,
        previewRenderer: AutoPreviewRenderer,
        renderedEffectVerifier: RenderedEffectVerifier,
        advancePhase: @escaping PhaseAdvancer,
        reportProgress: @escaping ProgressReporter,
        recordDiagnostic: @escaping DiagnosticRecorder
    ) {
        self.audioMixdownRenderer = audioMixdownRenderer
        self.previewRenderer = previewRenderer
        self.renderedEffectVerifier = renderedEffectVerifier
        self.advancePhase = advancePhase
        self.reportProgress = reportProgress
        self.recordDiagnostic = recordDiagnostic
    }

    func run(
        _ request: RecordingRenderPipelineRequest
    ) async throws -> RecordingRenderPipelineResult {
        try Task.checkCancellation()
        let saved = request.saved
        let plan = request.plan
        let microphoneURL = request.microphoneURL
        var audioMixErrorDescription: String?
        var microphoneWasMixed = false
        var voiceProcessingFellBack = false
        let requiresAudioMixdown = plan.audio.map { audioPlan in
            AudioMixdownRenderer.requiresMixdown(
                microphoneURL: microphoneURL,
                plan: audioPlan
            )
        } ?? false

        // Prepare narration/system audio once and let the effects renderer
        // consume the sidecar during its only video encode. If preparation
        // fails, the legacy two-pass fallback below remains available.
        let mixedAudioSidecarURL = requiresAudioMixdown
            ? saved.packageURL.appendingPathComponent(
                "previews/.audio-mix-\(UUID().uuidString).caf"
            )
            : nil
        defer {
            if let mixedAudioSidecarURL {
                try? FileManager.default.removeItem(at: mixedAudioSidecarURL)
            }
        }
        var mixedAudioReady = false
        if let mixedAudioSidecarURL, let audioPlan = plan.audio {
            do {
                let mixReport = try await audioMixdownRenderer.prepareMixedAudioSidecar(
                    sourceURL: saved.rawAssetURL,
                    microphoneURL: microphoneURL,
                    outputURL: mixedAudioSidecarURL,
                    plan: audioPlan,
                    timeline: plan.timeline,
                    progress: { [reportProgress, saved] fraction in
                        Task { @MainActor in
                            reportProgress(fraction * 0.15, saved)
                        }
                    }
                )
                voiceProcessingFellBack = mixReport
                    .voiceProcessingErrorDescription != nil
                microphoneWasMixed = microphoneURL != nil
                mixedAudioReady = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                audioMixErrorDescription = error.localizedDescription
            }
        }

        let videoProgressBase = requiresAudioMixdown ? 0.15 : 0.0
        let videoProgressScale = requiresAudioMixdown ? 0.85 : 1.0
        try Task.checkCancellation()
        await advancePhase(request.taskToken, .effects)
        _ = try await previewRenderer.render(
            inputURL: saved.rawAssetURL,
            cameraURL: request.cameraURL,
            outputURL: request.workingOutputURL,
            plan: plan,
            transcript: request.transcript,
            mixedAudioURL: mixedAudioReady ? mixedAudioSidecarURL : nil,
            progress: { [reportProgress, saved] fraction in
                Task { @MainActor in
                    reportProgress(
                        videoProgressBase + fraction * videoProgressScale,
                        saved
                    )
                }
            }
        )
        let renderMetrics = previewRenderer.lastRenderMetrics

        if requiresAudioMixdown, !mixedAudioReady, let audioPlan = plan.audio {
            let mixedURL = saved.packageURL.appendingPathComponent(
                "previews/.auto-mixed-\(UUID().uuidString).mp4"
            )
            defer { try? FileManager.default.removeItem(at: mixedURL) }
            do {
                let mixReport = try await audioMixdownRenderer.renderWithReport(
                    inputURL: request.workingOutputURL,
                    microphoneURL: microphoneURL,
                    outputURL: mixedURL,
                    plan: audioPlan,
                    timeline: plan.timeline,
                    export: plan.export
                )
                voiceProcessingFellBack = mixReport
                    .voiceProcessingErrorDescription != nil
                try Task.checkCancellation()
                _ = try FileManager.default.replaceItemAt(
                    request.workingOutputURL,
                    withItemAt: mixedURL
                )
                microphoneWasMixed = microphoneURL != nil
                audioMixErrorDescription = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                audioMixErrorDescription = error.localizedDescription
            }
        }

        let renderedEffectVerification = await renderedEffectVerifier.validate(
            rawURL: saved.rawAssetURL,
            previewURL: request.workingOutputURL,
            plan: plan,
            cameraURL: request.cameraURL,
            microphoneURL: microphoneURL,
            transcript: request.transcript
        )
        await advancePhase(request.taskToken, .verification)
        let renderedPlanDigest = try await RenderedPlanIdentity.digestAsync(
            for: plan,
            transcript: request.transcript,
            sourceURL: saved.rawAssetURL
        )
        let baseHealthReport = request.existingHealthReport ?? RecordingHealthReport(
            requestedFramesPerSecond: saved.manifest.captureSource?
                .effectiveRequestedFramesPerSecond
                ?? Int((renderedEffectVerification.rawMeasuredFramesPerSecond ?? 30).rounded()),
            measuredFramesPerSecond: renderedEffectVerification.rawMeasuredFramesPerSecond,
            p95FrameIntervalMilliseconds: nil,
            droppedFrameCount: 0,
            videoStatus: renderedEffectVerification.rawMeasuredFramesPerSecond == nil
                ? .notMeasured
                : .healthy,
            eventStatus: .notMeasured,
            pointerEventCount: 0,
            clickEventCount: 0,
            keyboardEventCount: 0,
            windowEventCount: 0,
            effectiveCameraKeyframeCount: plan.camera.keyframes.filter {
                $0.reason != .baseline
            }.count,
            cursorKeyframeCount: plan.cursor.keyframes.count,
            clickPulseCount: plan.interaction?.clickPulses.count ?? 0,
            warnings: []
        )
        let verifiedHealthReport = baseHealthReport
            .addingRenderedEffectVerification(
                renderedEffectVerification,
                renderedPlanDigest: renderedPlanDigest
            )
        recordDiagnostic(
            "preview.effects_verified",
            renderedEffectVerification.isVerified ? .info : .warning,
            [
                "status": renderedEffectVerification.isVerified
                    ? "verified"
                    : "needsReview",
                "verifiedEffects": renderedEffectVerification.verifiedEffects
                    .map(\.rawValue)
                    .joined(separator: ","),
                "previewFramesPerSecond": renderedEffectVerification
                    .previewMeasuredFramesPerSecond
                    .map { String(format: "%.2f", $0) } ?? "unavailable"
            ]
        )
        return RecordingRenderPipelineResult(
            healthReport: verifiedHealthReport,
            renderedEffectVerification: renderedEffectVerification,
            microphoneWasMixed: microphoneWasMixed,
            voiceProcessingFellBack: voiceProcessingFellBack,
            audioMixErrorDescription: audioMixErrorDescription,
            presenterWasRendered: plan.presenterCamera?.isEnabled == true
                && request.cameraURL != nil
                && previewRenderer.lastPresenterCameraError == nil,
            renderEncodePassCount: max(renderMetrics.encodePassCount, 0),
            renderElapsedMilliseconds: max(renderMetrics.elapsedMilliseconds, 0),
            renderPeakPhysicalFootprintBytes: renderMetrics.peakPhysicalFootprintBytes
        )
    }
}
