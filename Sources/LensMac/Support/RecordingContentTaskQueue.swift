import Foundation
import LensCore

struct RecordingContentTaskQueueRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued
        case running
    }

    let lensID: UUID
    let packageURL: URL
    var state: State
    var attempts: Int
}

struct RecordingContentTaskQueueStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Lens", isDirectory: true)
            .appendingPathComponent("recording-transcription-queue.json")
    }

    func load() -> [RecordingContentTaskQueueRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode(
            [RecordingContentTaskQueueRecord].self,
            from: data
        )) ?? []
    }

    func save(_ records: [RecordingContentTaskQueueRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Lens transcription queue checkpoint failed: %@", error.localizedDescription)
        }
    }
}

/// Main-actor queue for automatic transcription requests. It keeps duplicate
/// suppression, retry limits, and recovery state out of AppDelegate while
/// leaving the decision to defer or start with RecordingTaskSchedulingPolicy.
@MainActor
final class RecordingContentTaskQueue {
    static let maximumAttempts = 2

    private let store: RecordingContentTaskQueueStore
    private var records: [RecordingContentTaskQueueRecord]
    private var pending: [LensLibraryEntry] = []

    init(store: RecordingContentTaskQueueStore = RecordingContentTaskQueueStore()) {
        self.store = store
        let loaded = store.load()
        self.records = loaded.filter { $0.attempts < Self.maximumAttempts }
        if self.records.count != loaded.count {
            store.save(self.records)
        }
    }

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    var recoverableRecords: [RecordingContentTaskQueueRecord] {
        records.filter { $0.attempts < Self.maximumAttempts }
    }

    func contains(lensID: UUID) -> Bool {
        pending.contains { $0.id == lensID }
    }

    @discardableResult
    func enqueue(_ entry: LensLibraryEntry) -> Bool {
        guard !contains(lensID: entry.id),
              !records.contains(where: { $0.lensID == entry.id }) else {
            return false
        }
        pending.append(entry)
        records.append(
            RecordingContentTaskQueueRecord(
                lensID: entry.id,
                packageURL: entry.packageURL,
                state: .queued,
                attempts: 0
            )
        )
        persist()
        return true
    }

    @discardableResult
    func restore(_ entry: LensLibraryEntry) -> Bool {
        guard !contains(lensID: entry.id),
              let index = records.firstIndex(where: { $0.lensID == entry.id }),
              records[index].attempts < Self.maximumAttempts else {
            return false
        }
        pending.append(entry)
        records[index].state = .queued
        persist()
        return true
    }

    @discardableResult
    func claim(_ entry: LensLibraryEntry) -> Bool {
        guard let index = records.firstIndex(where: { $0.lensID == entry.id }) else {
            guard !contains(lensID: entry.id) else { return false }
            pending.removeAll { $0.id == entry.id }
            records.append(
                RecordingContentTaskQueueRecord(
                    lensID: entry.id,
                    packageURL: entry.packageURL,
                    state: .running,
                    attempts: 1
                )
            )
            persist()
            return true
        }
        guard records[index].attempts < Self.maximumAttempts else { return false }
        pending.removeAll { $0.id == entry.id }
        records[index].state = .running
        records[index].attempts += 1
        persist()
        return true
    }

    func complete(lensID: UUID) {
        pending.removeAll { $0.id == lensID }
        records.removeAll { $0.lensID == lensID }
        persist()
    }

    @discardableResult
    func discardExhaustedRecords() -> Int {
        let before = records.count
        records.removeAll { $0.attempts >= Self.maximumAttempts }
        let discarded = before - records.count
        if discarded > 0 { persist() }
        return discarded
    }

    func dequeue() -> LensLibraryEntry? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    @discardableResult
    func requeueFront(_ entry: LensLibraryEntry) -> Bool {
        guard !contains(lensID: entry.id) else { return false }
        pending.insert(entry, at: 0)
        if let index = records.firstIndex(where: { $0.lensID == entry.id }) {
            records[index].state = .queued
        }
        persist()
        return true
    }

    private func persist() {
        store.save(records)
    }
}
