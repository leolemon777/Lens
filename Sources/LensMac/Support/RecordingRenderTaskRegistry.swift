import Foundation
import LensCore

/// Owns the latest render task and generation for each project. A newer
/// render cancels the previous worker, and only the current generation may
/// publish or update delivery state.
@MainActor
final class RecordingRenderTaskRegistry {
    private struct Entry {
        let generation: UUID
        let task: Task<AutoEditPlan?, Never>
    }

    private var entries: [URL: Entry] = [:]

    var activePackageURLs: [URL] {
        Array(entries.keys)
    }

    func track(
        _ task: Task<AutoEditPlan?, Never>,
        for packageURL: URL,
        generation: UUID
    ) {
        let packageKey = packageURL.standardizedFileURL
        entries[packageKey]?.task.cancel()
        entries[packageKey] = Entry(generation: generation, task: task)
    }

    func cancel(for packageURL: URL) {
        entries[packageURL.standardizedFileURL]?.task.cancel()
    }

    func isCurrent(packageURL: URL, generation: UUID) -> Bool {
        entries[packageURL.standardizedFileURL]?.generation == generation
    }

    @discardableResult
    func finish(
        packageURL: URL,
        generation: UUID,
        task: Task<AutoEditPlan?, Never>
    ) -> Bool {
        let packageKey = packageURL.standardizedFileURL
        guard let entry = entries[packageKey],
              entry.generation == generation,
              entry.task == task else {
            return false
        }
        entries[packageKey] = nil
        return true
    }
}
