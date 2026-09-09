import Foundation
import LensCore

/// Owns the transcription task after admission. Queue policy stays in
/// AppDelegate, while execution, persistence, caption-triggered rendering,
/// organization handoff, and terminal presentation share one boundary.
@MainActor
final class RecordingTranscriptionTaskCoordinator {
    typealias WorkerFactory = @MainActor @Sendable () -> RecordingTranscriptionWorker?
    typealias AttachTranscript = @MainActor @Sendable (
        TranscriptDocument,
        SavedLens
    ) throws -> SavedLens
    typealias LoadPlan = @MainActor @Sendable (URL) throws -> AutoEditPlan
    typealias WritePlan = @MainActor @Sendable (
        AutoEditPlan,
        URL
    ) throws -> SavedLens
    typealias StartOrganization = @MainActor @Sendable (
        SavedLens,
        TranscriptDocument
    ) -> Void
    typealias Render = @MainActor @Sendable (SavedLens) async -> AutoEditPlan?
    typealias LoadManifest = @MainActor @Sendable (URL) throws -> LensManifest
    typealias Cleanup = @MainActor @Sendable () -> Void
    typealias BusyStateUpdater = @MainActor @Sendable (UUID, Bool) -> Void

    private let registry: RecordingContentTaskRegistry
    private let execution: RecordingContentTaskExecution
    private let finalizer: RecordingContentTaskFinalizer
    private let presentation: RecordingContentTaskPresentation
    private let workerFactory: WorkerFactory
    private let attachTranscript: AttachTranscript
    private let loadPlan: LoadPlan
    private let writePlan: WritePlan
    private let startOrganization: StartOrganization
    private let render: Render
    private let loadManifest: LoadManifest
    private let setTranscribing: BusyStateUpdater

    init(
        registry: RecordingContentTaskRegistry,
        execution: RecordingContentTaskExecution,
        finalizer: RecordingContentTaskFinalizer,
        presentation: RecordingContentTaskPresentation,
        workerFactory: @escaping WorkerFactory,
        attachTranscript: @escaping AttachTranscript,
        loadPlan: @escaping LoadPlan,
        writePlan: @escaping WritePlan,
        startOrganization: @escaping StartOrganization,
        render: @escaping Render,
        loadManifest: @escaping LoadManifest,
        setTranscribing: @escaping BusyStateUpdater
    ) {
        self.registry = registry
        self.execution = execution
        self.finalizer = finalizer
        self.presentation = presentation
        self.workerFactory = workerFactory
        self.attachTranscript = attachTranscript
        self.loadPlan = loadPlan
        self.writePlan = writePlan
        self.startOrganization = startOrganization
        self.render = render
        self.loadManifest = loadManifest
        self.setTranscribing = setTranscribing
    }

    /// Starts the post-admission transcription task. The caller owns queue
    /// cleanup through `afterCleanup`, so automatic retry bookkeeping remains
    /// next to the queue policy rather than hidden in this worker boundary.
    @discardableResult
    func start(
        entry: LensLibraryEntry,
        automatic: Bool,
        afterCleanup: @escaping Cleanup
    ) -> Task<Void, Never>? {
        let packageKey = entry.packageURL.standardizedFileURL
        guard registry.begin(
            packageURL: packageKey,
            kind: .transcription
        ) else {
            return nil
        }
        setTranscribing(entry.id, true)

        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                finalizer.finishTranscription(
                    packageURL: packageKey,
                    version: entry.manifest.id.uuidString,
                    lensID: entry.id,
                    afterCleanup: afterCleanup
                )
            }
            do {
                let document: TranscriptDocument = try await execution.run(
                    packageURL: packageKey,
                    kind: .transcription,
                    version: entry.manifest.id.uuidString,
                    priority: automatic ? .background : .userInitiated,
                    phase: .transcription
                ) { [workerFactory] taskToken in
                    guard let worker = workerFactory() else {
                        throw CancellationError()
                    }
                    return try await worker.run(
                        RecordingTranscriptionWorkRequest(
                            entry: entry,
                            automatic: automatic,
                            taskToken: taskToken
                        )
                    )
                }
                try Task.checkCancellation()
                let saved = SavedLens(
                    packageURL: entry.packageURL,
                    rawAssetURL: entry.primaryAssetURL,
                    manifest: entry.manifest
                )
                var updatedLens = try attachTranscript(document, saved)
                presentation.transcriptionCompleted(document)
                let trimmed = document.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    var plan = try loadPlan(entry.packageURL)
                    let isFirstTranscript = entry.transcriptText?.isEmpty != false
                    if isFirstTranscript {
                        if plan.captions == nil { plan.captions = .init() }
                        plan.captions?.isEnabled = true
                        updatedLens = try writePlan(plan, entry.packageURL)
                    }
                    startOrganization(updatedLens, document)
                    if plan.captions?.isEnabled == true {
                        _ = await render(updatedLens)
                    }
                } else {
                    startOrganization(updatedLens, document)
                }
            } catch is CancellationError {
                presentation.transcriptionCancelled()
            } catch {
                presentation.transcriptionFailed(
                    DiagnosticEvent.errorMetadata(error),
                    detail: error.localizedDescription
                )
                if automatic,
                   let manifest = try? loadManifest(entry.packageURL),
                   let primaryAsset = manifest.assets.first(where: { $0.role == .screenVideo }) {
                    // If captions cannot be produced, keep the automatic
                    // pipeline useful by publishing a verified non-caption
                    // preview instead of leaving only the raw recording.
                    _ = await render(SavedLens(
                        packageURL: entry.packageURL,
                        rawAssetURL: entry.packageURL
                            .appendingPathComponent(primaryAsset.relativePath),
                        manifest: manifest
                    ))
                }
            }
        }
    }
}
