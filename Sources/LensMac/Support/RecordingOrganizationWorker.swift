import Foundation
import LensCore

/// Stable input for local OCR/transcript organization. The supplied documents
/// are optional because the worker can load missing inputs from the project;
/// existing customization remains part of the worker's persistence contract.
struct RecordingOrganizationWorkRequest: Equatable, Sendable {
    let lens: SavedLens
    let suppliedOCR: OCRDocument?
    let suppliedTranscript: TranscriptDocument?
    let taskToken: RecordingTaskToken

    init(
        lens: SavedLens,
        suppliedOCR: OCRDocument? = nil,
        suppliedTranscript: TranscriptDocument? = nil,
        taskToken: RecordingTaskToken
    ) {
        self.lens = lens
        self.suppliedOCR = suppliedOCR
        self.suppliedTranscript = suppliedTranscript
        self.taskToken = taskToken
    }
}

@MainActor
final class RecordingOrganizationWorker {
    typealias Operation = @MainActor @Sendable (
        RecordingOrganizationWorkRequest
    ) async throws -> LensInsightsDocument

    typealias ManifestLoader = @Sendable (URL) throws -> LensManifest
    typealias OCRLoader = @Sendable (URL) throws -> OCRDocument
    typealias TranscriptLoader = @Sendable (URL) throws -> TranscriptDocument
    typealias InsightsLoader = @Sendable (URL) throws -> LensInsightsDocument
    typealias DiagnosticRecorder = @Sendable (
        String,
        [String: String]
    ) async -> Void

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    /// Builds the local organization implementation behind the same injected
    /// operation boundary used by tests. The synchronous project reads and
    /// pure organizer work run in a detached task so AppDelegate only owns
    /// task identity and UI publication; cancellation still reaches the
    /// detached read/analysis task.
    init(
        loadManifest: @escaping ManifestLoader,
        loadOCR: @escaping OCRLoader,
        loadTranscript: @escaping TranscriptLoader,
        loadInsights: @escaping InsightsLoader,
        recordDiagnostic: @escaping DiagnosticRecorder = { _, _ in }
    ) {
        self.operation = { request in
            let work = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let manifest = try loadManifest(request.lens.packageURL)
                let ocr: OCRDocument?
                if let suppliedOCR = request.suppliedOCR {
                    ocr = suppliedOCR
                } else {
                    do {
                        ocr = try loadOCR(request.lens.packageURL)
                    } catch {
                        await recordDiagnostic(
                            "organization.ocr_load_failed",
                            DiagnosticEvent.errorMetadata(error)
                        )
                        ocr = nil
                    }
                }
                try Task.checkCancellation()
                let transcript: TranscriptDocument?
                if let suppliedTranscript = request.suppliedTranscript {
                    transcript = suppliedTranscript
                } else {
                    do {
                        transcript = try loadTranscript(request.lens.packageURL)
                    } catch {
                        await recordDiagnostic(
                            "organization.transcript_load_failed",
                            DiagnosticEvent.errorMetadata(error)
                        )
                        transcript = nil
                    }
                }
                try Task.checkCancellation()
                let previous: LensInsightsDocument?
                do {
                    previous = try loadInsights(request.lens.packageURL)
                } catch {
                    await recordDiagnostic(
                        "organization.insights_load_failed",
                        DiagnosticEvent.errorMetadata(error)
                    )
                    previous = nil
                }
                try Task.checkCancellation()
                return LocalLensOrganizer.organize(
                    manifest: manifest,
                    ocr: ocr,
                    transcript: transcript,
                    tokenizer: NaturalLanguageTokenizer()
                ).replacingCustomization(previous?.customization)
            }
            return try await withTaskCancellationHandler(operation: {
                try await work.value
            }, onCancel: {
                work.cancel()
            })
        }
    }

    func run(
        _ request: RecordingOrganizationWorkRequest
    ) async throws -> LensInsightsDocument {
        try await operation(request)
    }
}
