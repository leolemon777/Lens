import Foundation

/// The packages a storage pass must leave alone while the app is writing.
///
/// Two callers read this set with different rules, so it has to carry both
/// kinds of entry. `LensStorageMigrationQueue` only asks whether the set is
/// empty, while `LensStorageManager.cleanupTemporaryFiles(protecting:)` matches
/// every temporary file against its own package. A writer that can name its
/// package therefore has to contribute the real URL — a sentinel would defer
/// the migration but protect nothing from the cleanup. The sentinel remains for
/// the busy states that have no package to name: an in-flight capture has not
/// published one yet, and a visible library window pins the storage root rather
/// than any single package.
enum ActiveStoragePackagePolicy {
    static let unnamedWriteSentinelName = ".lens-storage-write-active"

    static func resolve(
        rootDirectory: URL,
        taskPackageURLs: [URL],
        editingPackageURLs: [URL?],
        hasUnnamedWrite: Bool
    ) -> Set<URL> {
        var packages = Set(taskPackageURLs.map(\.standardizedFileURL))
        packages.formUnion(editingPackageURLs.compactMap { $0?.standardizedFileURL })
        if hasUnnamedWrite {
            packages.insert(
                rootDirectory
                    .appendingPathComponent(unnamedWriteSentinelName)
                    .standardizedFileURL
            )
        }
        return packages
    }
}

/// Keeps a user-selected storage destination until every package-writing task
/// has finished. The queue is MainActor-owned because it only coordinates UI
/// intent; the actual copy and verification remain detached work.
@MainActor
final class LensStorageMigrationQueue {
    private(set) var pendingDestination: URL?
    private(set) var isRunning = false

    /// Returns true when the caller may start immediately. A busy app or an
    /// existing migration keeps the newest destination for later.
    @discardableResult
    func request(destination: URL, activePackages: Set<URL>) -> Bool {
        let normalized = destination.standardizedFileURL
        guard !isRunning, activePackages.isEmpty else {
            pendingDestination = normalized
            return false
        }
        isRunning = true
        return true
    }

    /// Marks the current copy/verify operation as finished. A failed
    /// operation deliberately does not retry automatically; the user can
    /// choose the destination again after seeing the error.
    func finish() {
        isRunning = false
    }

    /// Starts the newest queued destination once no package can be mutated.
    @discardableResult
    func takeNextIfReady(activePackages: Set<URL>) -> URL? {
        guard !isRunning, activePackages.isEmpty, let destination = pendingDestination else {
            return nil
        }
        pendingDestination = nil
        isRunning = true
        return destination
    }
}
