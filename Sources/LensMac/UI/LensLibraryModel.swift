import Foundation
import LensCore

struct LensLibraryRecoveryScanProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fractionCompleted: Double {
        guard total > 0 else { return 1 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct LensLibraryTranscriptionProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

@MainActor
final class LensLibraryModel: ObservableObject {
    let store: LensProjectStore
    private let recoveryInspector: RecordingRecoveryInspector

    @Published private(set) var entries: [LensLibraryEntry]
    @Published private(set) var visibleEntries: [LensLibraryEntry]
    @Published private(set) var isFiltering = false
    @Published var query = "" {
        didSet { scheduleFiltering() }
    }
    @Published var filter: LensLibraryFilter = .all {
        didSet { scheduleFiltering() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var transcribingIDs: Set<UUID> = []
    @Published private(set) var transcriptionProgressByID: [UUID: LensLibraryTranscriptionProgress] = [:]
    @Published private(set) var organizingIDs: Set<UUID> = []
    @Published private(set) var recoveryFindings: [UUID: RecordingRecoveryAssessment] = [:]
    @Published private(set) var repairingIDs: Set<UUID> = []
    @Published private(set) var recoveryScanProgress: LensLibraryRecoveryScanProgress?

    private var reloadTask: Task<Void, Never>?
    private var recoveryScanTask: Task<Void, Never>?
    private var filteringTask: Task<Void, Never>?
    private var reloadGeneration = UUID()
    private var filteringGeneration = UUID()
    private var recoveryScanFingerprints: [UUID: RecoveryScanFingerprint] = [:]

    private struct RecoveryScanFingerprint: Equatable {
        let components: [String]
    }

    init(
        store: LensProjectStore,
        initialEntries: [LensLibraryEntry] = [],
        initialRecoveryFindings: [UUID: RecordingRecoveryAssessment] = [:],
        recoveryDurationProvider: @escaping @Sendable (URL) async -> Double? = {
            await RecordingRecoveryInspector.mediaDurationSeconds(at: $0)
        }
    ) {
        self.store = store
        recoveryInspector = RecordingRecoveryInspector(
            store: store,
            durationProvider: recoveryDurationProvider
        )
        entries = initialEntries
        visibleEntries = LensLibrarySearch.filter(
            initialEntries,
            query: "",
            filter: .all
        )
        recoveryFindings = initialRecoveryFindings
    }

    deinit {
        reloadTask?.cancel()
        recoveryScanTask?.cancel()
        filteringTask?.cancel()
    }

    func recoveryAssessment(for id: UUID) -> RecordingRecoveryAssessment? {
        recoveryFindings[id]
    }

    func isRepairing(_ id: UUID) -> Bool {
        repairingIDs.contains(id)
    }

    /// Reading every recording's media is far too slow to gate the list on, so
    /// findings are published one at a time as they are measured and the list
    /// stays usable throughout.
    private func scanForDamagedRecordings(_ entries: [LensLibraryEntry]) {
        recoveryScanTask?.cancel()
        let recordings = entries.filter { $0.manifest.kind == .recording }
        let activeIDs = Set(recordings.map(\.id))
        recoveryFindings = recoveryFindings.filter { activeIDs.contains($0.key) }
        recoveryScanFingerprints = recoveryScanFingerprints.filter {
            activeIDs.contains($0.key)
        }
        let pending = recordings.compactMap { entry -> (LensLibraryEntry, RecoveryScanFingerprint)? in
            let fingerprint = recoveryScanFingerprint(for: entry)
            guard recoveryScanFingerprints[entry.id] != fingerprint else { return nil }
            return (entry, fingerprint)
        }
        guard !pending.isEmpty else {
            recoveryScanProgress = nil
            if recordings.isEmpty {
                recoveryFindings = [:]
                recoveryScanFingerprints = [:]
            }
            return
        }
        recoveryScanProgress = LensLibraryRecoveryScanProgress(
            completed: 0,
            total: pending.count
        )
        let inspector = recoveryInspector
        recoveryScanTask = Task { @MainActor [weak self] in
            var completed = 0
            for (entry, fingerprint) in pending {
                if Task.isCancelled { return }
                let assessment = await Task.detached(priority: .utility) {
                    await inspector.assess(packageURL: entry.packageURL)
                }.value
                guard let self, !Task.isCancelled else { return }
                recoveryScanFingerprints[entry.id] = fingerprint
                if let assessment, assessment.isDamaged {
                    recoveryFindings[entry.id] = assessment
                } else {
                    recoveryFindings[entry.id] = nil
                }
                completed += 1
                recoveryScanProgress = LensLibraryRecoveryScanProgress(
                    completed: completed,
                    total: pending.count
                )
            }
            guard let self, !Task.isCancelled else { return }
            recoveryScanProgress = nil
        }
    }

    private func recoveryScanFingerprint(
        for entry: LensLibraryEntry
    ) -> RecoveryScanFingerprint {
        var relativePaths = Set(["manifest.json", "events/segments.json"])
        relativePaths.formUnion(entry.manifest.assets.map(\.relativePath))
        let components = relativePaths.sorted().map { relativePath in
            let url = entry.packageURL.appendingPathComponent(relativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let byteCount = attributes[.size] as? NSNumber,
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                return "\(relativePath)|missing"
            }
            return "\(relativePath)|\(byteCount.uint64Value)|\(modifiedAt.timeIntervalSince1970)"
        }
        return RecoveryScanFingerprint(components: components)
    }

    /// Merges the picture a recording holds but never counted back into its
    /// screen video. Nothing already on disk is removed.
    @discardableResult
    func repairRecoverableRecording(
        _ entry: LensLibraryEntry
    ) async -> Result<RebuiltRecording, Error>? {
        guard let assessment = recoveryFindings[entry.id],
              assessment.canRebuildLongerRecording,
              !repairingIDs.contains(entry.id) else { return nil }
        repairingIDs.insert(entry.id)
        defer { repairingIDs.remove(entry.id) }
        do {
            let rebuilt = try await RecordingRecoveryRepair(store: store)
                .rebuild(packageURL: entry.packageURL, assessment: assessment)
            recoveryFindings[entry.id] = nil
            return .success(rebuilt)
        } catch {
            return .failure(error)
        }
    }

    /// Waits for the latest background filter pass. The view observes
    /// `visibleEntries` and can keep showing the previous result while a new
    /// query is being computed off the main actor.
    func waitForFiltering() async {
        await filteringTask?.value
    }

    func waitForReload() async {
        await reloadTask?.value
    }

    func waitForRecoveryScan() async {
        await recoveryScanTask?.value
    }

    var screenshotCount: Int {
        entries.count { $0.manifest.kind == .screenshot }
    }

    var recordingCount: Int {
        entries.count { $0.manifest.kind == .recording }
    }

    func isTranscribing(_ id: UUID) -> Bool {
        transcribingIDs.contains(id)
    }

    func transcriptionProgress(for id: UUID) -> LensLibraryTranscriptionProgress? {
        transcriptionProgressByID[id]
    }

    func setTranscribing(_ isTranscribing: Bool, id: UUID) {
        if isTranscribing {
            transcribingIDs.insert(id)
            transcriptionProgressByID[id] = nil
        } else {
            transcribingIDs.remove(id)
            transcriptionProgressByID[id] = nil
        }
    }

    func setTranscriptionProgress(
        _ progress: LensLibraryTranscriptionProgress?,
        id: UUID
    ) {
        guard transcribingIDs.contains(id) else { return }
        transcriptionProgressByID[id] = progress
    }

    func isOrganizing(_ id: UUID) -> Bool {
        organizingIDs.contains(id)
    }

    func setOrganizing(_ isOrganizing: Bool, id: UUID) {
        if isOrganizing {
            organizingIDs.insert(id)
        } else {
            organizingIDs.remove(id)
        }
    }

    func canDelete(_ entry: LensLibraryEntry) -> Bool {
        guard !isTranscribing(entry.id), !isOrganizing(entry.id) else { return false }
        switch entry.manifest.state {
        case .capturing, .processing:
            return false
        case .ready, .interrupted, .failed:
            return true
        }
    }

    func removeEntries(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        transcribingIDs.subtract(ids)
        transcriptionProgressByID = transcriptionProgressByID.filter { !ids.contains($0.key) }
        organizingIDs.subtract(ids)
        scheduleFiltering()
    }

    func reload() {
        reloadTask?.cancel()
        let generation = UUID()
        reloadGeneration = generation
        isLoading = true
        let store = store
        reloadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                store.libraryEntries()
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.reloadGeneration == generation else { return }
            entries = result
            scheduleFiltering()
            isLoading = false
            scanForDamagedRecordings(result)
        }
    }

    private func scheduleFiltering() {
        filteringTask?.cancel()
        let generation = UUID()
        filteringGeneration = generation
        let entries = entries
        let query = query
        let filter = filter
        isFiltering = true
        filteringTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LensLibrarySearch.filter(entries, query: query, filter: filter)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.filteringGeneration == generation else { return }
            self.visibleEntries = result
            self.isFiltering = false
        }
    }
}
