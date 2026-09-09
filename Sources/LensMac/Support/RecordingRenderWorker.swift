import Foundation
import LensCore

/// The stable boundary between render-task orchestration and the media
/// implementation. AppDelegate owns the platform-specific operation for now;
/// this value type lets the operation move to a dedicated worker without
/// changing task identity, cancellation, or publication rules.
struct RecordingRenderWorkRequest: Equatable, Sendable {
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

@MainActor
final class RecordingRenderWorker {
    typealias Operation = @MainActor @Sendable (
        RecordingRenderWorkRequest
    ) async throws -> AutoEditPlan?

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run(_ request: RecordingRenderWorkRequest) async throws -> AutoEditPlan? {
        try await operation(request)
    }
}
