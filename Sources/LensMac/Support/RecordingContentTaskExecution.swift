import Foundation

/// Shared execution boundary for content workers such as transcription and
/// organization. UI state, registry ownership, and result publication stay in
/// AppDelegate; this type owns the task-coordinator phase contract so content
/// workers cannot accidentally bypass cancellation or timing metrics.
@MainActor
final class RecordingContentTaskExecution {
    typealias Operation<T: Sendable> = @MainActor @Sendable (
        RecordingTaskToken
    ) async throws -> T

    private let coordinator: RecordingTaskCoordinator

    init(coordinator: RecordingTaskCoordinator) {
        self.coordinator = coordinator
    }

    func run<T: Sendable>(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String,
        priority: RecordingTaskPriority,
        phase: RecordingTaskPhase,
        operation: @escaping Operation<T>
    ) async throws -> T {
        try await coordinator.run(
            packageURL: packageURL,
            kind: kind,
            version: version,
            priority: priority
        ) { [coordinator] taskToken in
            await coordinator.advance(taskToken, to: phase)
            return try await operation(taskToken)
        }
    }
}
