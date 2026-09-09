import Foundation
import LensCore

/// The disk-facing part of post-recording rendering. AppDelegate keeps task
/// identity and user feedback, while this execution boundary owns loading the
/// edit inputs, consuming the media pipeline, publishing only verified output,
/// and persisting the resulting health report.
struct RecordingRenderExecutionRequest: Equatable, Sendable {
    let saved: SavedLens
    let generation: UUID
    let taskToken: RecordingTaskToken

    init(
        saved: SavedLens,
        generation: UUID,
        taskToken: RecordingTaskToken
    ) {
        self.saved = saved
        self.generation = generation
        self.taskToken = taskToken
    }
}

struct RecordingRenderExecutionResult: Sendable {
    let plan: AutoEditPlan
    let updated: SavedLens
    let pipelineResult: RecordingRenderPipelineResult
    let cameraURL: URL?
    let microphoneURL: URL?
}

@MainActor
final class RecordingRenderExecution {
    typealias Operation = @MainActor @Sendable (
        RecordingRenderExecutionRequest
    ) async throws -> RecordingRenderExecutionResult
    typealias CurrentGeneration = @MainActor @Sendable (URL, UUID) -> Bool
    typealias PhaseAdvancer = @MainActor @Sendable (
        RecordingTaskToken,
        RecordingTaskPhase
    ) async -> Void
    typealias DiagnosticRecorder = @MainActor @Sendable (
        String,
        DiagnosticLevel,
        [String: String]
    ) -> Void

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    init(
        store: LensProjectStore,
        pipeline: RecordingRenderPipeline,
        isCurrent: @escaping CurrentGeneration,
        advancePhase: @escaping PhaseAdvancer,
        recordDiagnostic: @escaping DiagnosticRecorder
    ) {
        self.operation = { request in
            try await Self.execute(
                request,
                store: store,
                pipeline: pipeline,
                isCurrent: isCurrent,
                advancePhase: advancePhase,
                recordDiagnostic: recordDiagnostic
            )
        }
    }

    func run(
        _ request: RecordingRenderExecutionRequest
    ) async throws -> RecordingRenderExecutionResult {
        try await operation(request)
    }

    private static func execute(
        _ request: RecordingRenderExecutionRequest,
        store: LensProjectStore,
        pipeline: RecordingRenderPipeline,
        isCurrent: @escaping CurrentGeneration,
        advancePhase: @escaping PhaseAdvancer,
        recordDiagnostic: @escaping DiagnosticRecorder
    ) async throws -> RecordingRenderExecutionResult {
        let saved = request.saved
        let packageKey = saved.packageURL.standardizedFileURL
        await advancePhase(request.taskToken, .audioPreparation)
        guard isCurrent(packageKey, request.generation) else {
            throw CancellationError()
        }

        let plan = try store.loadAutoEditPlan(from: saved.packageURL)
        try Task.checkCancellation()

        var healthReport: RecordingHealthReport?
        do {
            healthReport = try store.loadRecordingHealthReport(from: saved.packageURL)
        } catch {
            recordDiagnostic(
                "preview.health_report_load_failed",
                .warning,
                DiagnosticEvent.errorMetadata(error)
            )
        }

        let outputURL = saved.packageURL.appendingPathComponent("previews/auto.mp4")
        let workingOutputURL = saved.packageURL.appendingPathComponent(
            "previews/.auto-\(request.generation.uuidString).mp4"
        )
        try FileManager.default.createDirectory(
            at: workingOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingOutputURL) }

        let cameraURL = saved.manifest.assets.first(where: { $0.role == .camera })
            .map { saved.packageURL.appendingPathComponent($0.relativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let transcript: TranscriptDocument?
        if plan.captions?.isEnabled == true {
            do {
                transcript = try store.loadTranscript(from: saved.packageURL)
            } catch {
                recordDiagnostic(
                    "preview.transcript_load_failed",
                    .warning,
                    DiagnosticEvent.errorMetadata(error)
                )
                transcript = nil
            }
        } else {
            transcript = nil
        }
        let microphoneURL = saved.manifest.assets.first(where: { $0.role == .microphone })
            .map { saved.packageURL.appendingPathComponent($0.relativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        let pipelineResult = try await pipeline.run(
            RecordingRenderPipelineRequest(
                saved: saved,
                plan: plan,
                existingHealthReport: healthReport,
                cameraURL: cameraURL,
                microphoneURL: microphoneURL,
                transcript: transcript,
                workingOutputURL: workingOutputURL,
                taskToken: request.taskToken
            )
        )

        guard isCurrent(packageKey, request.generation) else {
            throw CancellationError()
        }

        let updated: SavedLens
        if pipelineResult.renderedEffectVerification.isVerified {
            await advancePhase(request.taskToken, .publishing)
            try publishRenderedPreview(from: workingOutputURL, to: outputURL)
            updated = try store.completeProcessing(
                packageURL: saved.packageURL,
                renderedVideoURL: outputURL
            )
        } else {
            // Keep the previously published preview and processing manifest
            // untouched until the new output passes media verification.
            updated = saved
        }

        do {
            _ = try store.writeRecordingHealthReport(
                pipelineResult.healthReport,
                to: saved.packageURL
            )
        } catch {
            recordDiagnostic(
                "preview.health_report_write_failed",
                .error,
                DiagnosticEvent.errorMetadata(error)
            )
        }

        return RecordingRenderExecutionResult(
            plan: plan,
            updated: updated,
            pipelineResult: pipelineResult,
            cameraURL: cameraURL,
            microphoneURL: microphoneURL
        )
    }

    private static func publishRenderedPreview(
        from workingURL: URL,
        to outputURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: workingURL.path) else {
            throw LensProjectStoreError.missingRenderedVideo
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(
                outputURL,
                withItemAt: workingURL
            )
        } else {
            try FileManager.default.moveItem(at: workingURL, to: outputURL)
        }
    }
}
