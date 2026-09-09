import Foundation
import LensCore

/// Owns the render-task lifecycle between AppDelegate adapters and the
/// disk-facing render execution. Generation ownership, cancellation, result
/// presentation, and terminal metrics stay together so the application
/// delegate only supplies platform dependencies and starts the task.
@MainActor
final class RecordingRenderTaskCoordinator {
    private let taskCoordinator: RecordingTaskCoordinator
    private let registry: RecordingRenderTaskRegistry
    private let execution: RecordingRenderExecution
    private let presentation: RecordingRenderPresentation
    private let metrics: RecordingTaskMetricsReporter
    private let startMigration: @MainActor @Sendable () -> Void
    private let injectedWorker: RecordingRenderWorker?
    private lazy var defaultWorker = RecordingRenderWorker { [weak self] request in
        guard let self else { throw CancellationError() }
        return try await self.perform(request)
    }

    init(
        taskCoordinator: RecordingTaskCoordinator,
        registry: RecordingRenderTaskRegistry,
        execution: RecordingRenderExecution,
        presentation: RecordingRenderPresentation,
        metrics: RecordingTaskMetricsReporter,
        startMigration: @escaping @MainActor @Sendable () -> Void,
        worker: RecordingRenderWorker? = nil
    ) {
        self.taskCoordinator = taskCoordinator
        self.registry = registry
        self.execution = execution
        self.presentation = presentation
        self.metrics = metrics
        self.startMigration = startMigration
        self.injectedWorker = worker
    }

    @discardableResult
    func process(_ saved: SavedLens) async -> AutoEditPlan? {
        let packageKey = saved.packageURL.standardizedFileURL
        registry.cancel(for: packageKey)
        let generation = UUID()
        let worker = injectedWorker ?? defaultWorker
        let task: Task<AutoEditPlan?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                return try await self.taskCoordinator.run(
                    packageURL: packageKey,
                    kind: .render,
                    version: generation.uuidString,
                    priority: .recordingFinalization,
                    serializePackage: true
                ) { taskToken in
                    try await worker.run(
                        RecordingRenderWorkRequest(
                            saved: saved,
                            generation: generation,
                            taskToken: taskToken
                        )
                    )
                }
            } catch {
                return nil
            }
        }
        registry.track(task, for: packageKey, generation: generation)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await metrics.record(
            packageURL: packageKey,
            kind: .render,
            version: generation.uuidString
        )
        if registry.finish(
            packageURL: packageKey,
            generation: generation,
            task: task
        ) {
            startMigration()
        }
        return result
    }

    private func perform(
        _ request: RecordingRenderWorkRequest
    ) async throws -> AutoEditPlan? {
        let processingStartedAt = ProcessInfo.processInfo.systemUptime
        let packageKey = request.saved.packageURL.standardizedFileURL
        do {
            let result = try await execution.run(
                RecordingRenderExecutionRequest(
                    saved: request.saved,
                    generation: request.generation,
                    taskToken: request.taskToken
                )
            )
            return presentation.present(
                RecordingRenderPresentationInput(
                    saved: request.saved,
                    updated: result.updated,
                    plan: result.plan,
                    pipelineResult: result.pipelineResult,
                    cameraURL: result.cameraURL,
                    microphoneURL: result.microphoneURL,
                    elapsedMilliseconds: max(
                        (ProcessInfo.processInfo.systemUptime - processingStartedAt)
                            * 1_000,
                        0
                    ),
                    presenterWasRendered: result.pipelineResult.presenterWasRendered
                )
            )
        } catch is CancellationError {
            presentation.presentCancellation(
                for: request.saved,
                isCurrent: registry.isCurrent(
                    packageURL: packageKey,
                    generation: request.generation
                )
            )
            throw CancellationError()
        } catch {
            presentation.presentFailure(
                for: request.saved,
                isCurrent: registry.isCurrent(
                    packageURL: packageKey,
                    generation: request.generation
                ),
                metadata: DiagnosticEvent.errorMetadata(error)
            )
            throw error
        }
    }
}
