import Foundation

/// Finishes transcription and organization tasks in one place. The worker
/// still owns its result and failure handling; this boundary owns the shared
/// cleanup that must happen for every terminal path.
@MainActor
final class RecordingContentTaskFinalizer {
    typealias MetricsRecorder = @MainActor @Sendable (
        URL,
        RecordingTaskKind,
        String
    ) async -> Void
    typealias RegistryFinisher = @MainActor @Sendable (
        URL,
        RecordingContentTaskRegistry.Kind
    ) -> Void
    typealias BusyStateUpdater = @MainActor @Sendable (UUID, Bool) -> Void
    typealias MigrationStarter = @MainActor @Sendable () -> Void

    private let recordMetrics: MetricsRecorder
    private let finishRegistry: RegistryFinisher
    private let setTranscribing: BusyStateUpdater
    private let setOrganizing: BusyStateUpdater
    private let startMigration: MigrationStarter

    init(
        recordMetrics: @escaping MetricsRecorder,
        finishRegistry: @escaping RegistryFinisher,
        setTranscribing: @escaping BusyStateUpdater,
        setOrganizing: @escaping BusyStateUpdater,
        startMigration: @escaping MigrationStarter
    ) {
        self.recordMetrics = recordMetrics
        self.finishRegistry = finishRegistry
        self.setTranscribing = setTranscribing
        self.setOrganizing = setOrganizing
        self.startMigration = startMigration
    }

    func finishTranscription(
        packageURL: URL,
        version: String,
        lensID: UUID,
        afterCleanup: @escaping @MainActor @Sendable () -> Void
    ) {
        finish(
            packageURL: packageURL,
            taskKind: .transcription,
            registryKind: .transcription,
            version: version,
            lensID: lensID,
            updateBusy: setTranscribing,
            afterCleanup: afterCleanup
        )
    }

    func finishOrganization(
        packageURL: URL,
        version: String,
        lensID: UUID
    ) {
        finish(
            packageURL: packageURL,
            taskKind: .organization,
            registryKind: .organization,
            version: version,
            lensID: lensID,
            updateBusy: setOrganizing,
            afterCleanup: {}
        )
    }

    private func finish(
        packageURL: URL,
        taskKind: RecordingTaskKind,
        registryKind: RecordingContentTaskRegistry.Kind,
        version: String,
        lensID: UUID,
        updateBusy: BusyStateUpdater,
        afterCleanup: @escaping @MainActor @Sendable () -> Void
    ) {
        let recordMetrics = self.recordMetrics
        Task { @MainActor in
            await recordMetrics(packageURL, taskKind, version)
        }
        finishRegistry(packageURL, registryKind)
        updateBusy(lensID, false)
        afterCleanup()
        startMigration()
    }
}
