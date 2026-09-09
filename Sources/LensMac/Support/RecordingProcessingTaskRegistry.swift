import Foundation

/// Owns the cancellable post-recording tasks that are not the render worker.
/// Keeping this registry on the main actor makes the UI-facing ownership
/// explicit while the actual media work remains in its existing workers.
@MainActor
final class RecordingProcessingTaskRegistry {
    private var tasks: [URL: Task<Void, Never>] = [:]

    var activePackageURLs: [URL] {
        Array(tasks.keys)
    }

    func track(
        _ task: Task<Void, Never>,
        for packageURL: URL,
        onCompletion: @escaping @MainActor () -> Void = {}
    ) {
        let packageKey = packageURL.standardizedFileURL
        tasks[packageKey]?.cancel()
        tasks[packageKey] = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.tasks[packageKey] == task else { return }
            self.tasks[packageKey] = nil
            onCompletion()
        }
    }

    func cancel(for packageURL: URL) {
        tasks[packageURL.standardizedFileURL]?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
