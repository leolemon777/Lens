import Foundation
import LensCore

/// Owns the organization task lifecycle between AppDelegate adapters and the
/// organization worker. Persistence and user-facing delivery stay injected so
/// this boundary can be exercised without starting a real Lens window.
@MainActor
final class RecordingOrganizationTaskCoordinator {
    typealias WorkerFactory = @MainActor @Sendable () -> RecordingOrganizationWorker?
    typealias AttachInsights = @MainActor @Sendable (
        LensInsightsDocument,
        SavedLens
    ) throws -> Void
    typealias BusyStateUpdater = @MainActor @Sendable (UUID, Bool) -> Void

    private let registry: RecordingContentTaskRegistry
    private let execution: RecordingContentTaskExecution
    private let finalizer: RecordingContentTaskFinalizer
    private let presentation: RecordingContentTaskPresentation
    private let workerFactory: WorkerFactory
    private let attachInsights: AttachInsights
    private let setOrganizing: BusyStateUpdater

    init(
        registry: RecordingContentTaskRegistry,
        execution: RecordingContentTaskExecution,
        finalizer: RecordingContentTaskFinalizer,
        presentation: RecordingContentTaskPresentation,
        workerFactory: @escaping WorkerFactory,
        attachInsights: @escaping AttachInsights,
        setOrganizing: @escaping BusyStateUpdater
    ) {
        self.registry = registry
        self.execution = execution
        self.finalizer = finalizer
        self.presentation = presentation
        self.workerFactory = workerFactory
        self.attachInsights = attachInsights
        self.setOrganizing = setOrganizing
    }

    /// Starts an organization task and returns its task handle for short
    /// integration tests or a future explicit cancellation surface.
    @discardableResult
    func begin(
        lens: SavedLens,
        suppliedOCR: OCRDocument? = nil,
        suppliedTranscript: TranscriptDocument? = nil,
        announcesResult: Bool = false
    ) -> Task<Void, Never>? {
        let packageKey = lens.packageURL.standardizedFileURL
        guard registry.begin(
            packageURL: packageKey,
            kind: .organization
        ) else {
            if announcesResult {
                presentation.organizationAlreadyRunning()
            }
            return nil
        }
        setOrganizing(lens.manifest.id, true)

        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                finalizer.finishOrganization(
                    packageURL: packageKey,
                    version: lens.manifest.id.uuidString,
                    lensID: lens.manifest.id
                )
            }
            do {
                let insights: LensInsightsDocument = try await execution.run(
                    packageURL: packageKey,
                    kind: .organization,
                    version: lens.manifest.id.uuidString,
                    priority: announcesResult ? .userInitiated : .background,
                    phase: .organization
                ) { [workerFactory] taskToken in
                    guard let worker = workerFactory() else {
                        throw CancellationError()
                    }
                    return try await worker.run(
                        RecordingOrganizationWorkRequest(
                            lens: lens,
                            suppliedOCR: suppliedOCR,
                            suppliedTranscript: suppliedTranscript,
                            taskToken: taskToken
                        )
                    )
                }
                try attachInsights(insights, lens)
                presentation.organizationCompleted(
                    insights,
                    announcesResult: announcesResult
                )
            } catch is CancellationError {
                return
            } catch {
                presentation.organizationFailed(
                    DiagnosticEvent.errorMetadata(error),
                    detail: error.localizedDescription,
                    announcesResult: announcesResult
                )
            }
        }
    }
}
