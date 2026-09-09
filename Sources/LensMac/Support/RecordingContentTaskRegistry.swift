import Foundation

/// Tracks content-processing ownership separately from the worker
/// implementation. The registry is main-actor isolated because the UI state
/// and automatic transcription queue are main-actor state as well.
@MainActor
final class RecordingContentTaskRegistry {
    enum Kind: Hashable {
        case transcription
        case organization
    }

    private struct Key: Hashable {
        let packageURL: URL
        let kind: Kind
    }

    private var active: Set<Key> = []

    var activePackageURLs: [URL] {
        Array(Set(active.map(\.packageURL)))
    }

    func contains(packageURL: URL, kind: Kind) -> Bool {
        active.contains(Key(packageURL: packageURL.standardizedFileURL, kind: kind))
    }

    func count(kind: Kind) -> Int {
        active.reduce(into: 0) { count, key in
            if key.kind == kind { count += 1 }
        }
    }

    @discardableResult
    func begin(packageURL: URL, kind: Kind) -> Bool {
        active.insert(
            Key(packageURL: packageURL.standardizedFileURL, kind: kind)
        ).inserted
    }

    func finish(packageURL: URL, kind: Kind) {
        active.remove(
            Key(packageURL: packageURL.standardizedFileURL, kind: kind)
        )
    }
}
