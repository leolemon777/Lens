import Foundation
import ScreenTraceCore

@MainActor
final class TraceLibraryModel: ObservableObject {
    let store: TraceProjectStore

    @Published private(set) var entries: [TraceLibraryEntry]
    @Published var query = ""
    @Published var filter: TraceLibraryFilter = .all
    @Published private(set) var isLoading = false
    @Published private(set) var transcribingIDs: Set<UUID> = []
    @Published private(set) var organizingIDs: Set<UUID> = []
    @Published private(set) var recoveryFindings: [UUID: RecordingRecoveryAssessment] = [:]
    @Published private(set) var repairingIDs: Set<UUID> = []

    private var reloadTask: Task<Void, Never>?
    private var recoveryScanTask: Task<Void, Never>?

    init(
        store: TraceProjectStore,
        initialEntries: [TraceLibraryEntry] = [],
        initialRecoveryFindings: [UUID: RecordingRecoveryAssessment] = [:]
    ) {
        self.store = store
        entries = initialEntries
        recoveryFindings = initialRecoveryFindings
    }

    deinit {
        reloadTask?.cancel()
        recoveryScanTask?.cancel()
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
    private func scanForDamagedRecordings(_ entries: [TraceLibraryEntry]) {
        recoveryScanTask?.cancel()
        let recordings = entries.filter { $0.manifest.kind == .recording }
        guard !recordings.isEmpty else {
            recoveryFindings = [:]
            return
        }
        let inspector = RecordingRecoveryInspector(store: store)
        recoveryScanTask = Task { @MainActor [weak self] in
            var found: [UUID: RecordingRecoveryAssessment] = [:]
            for entry in recordings {
                if Task.isCancelled { return }
                let assessment = await Task.detached(priority: .utility) {
                    await inspector.assess(packageURL: entry.packageURL)
                }.value
                guard let assessment, assessment.isDamaged else { continue }
                found[entry.id] = assessment
                guard let self, !Task.isCancelled else { return }
                recoveryFindings = found
            }
            guard let self, !Task.isCancelled else { return }
            recoveryFindings = found
        }
    }

    /// Merges the picture a recording holds but never counted back into its
    /// screen video. Nothing already on disk is removed.
    @discardableResult
    func repairRecoverableRecording(
        _ entry: TraceLibraryEntry
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

    var visibleEntries: [TraceLibraryEntry] {
        TraceLibrarySearch.filter(entries, query: query, filter: filter)
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

    func setTranscribing(_ isTranscribing: Bool, id: UUID) {
        if isTranscribing {
            transcribingIDs.insert(id)
        } else {
            transcribingIDs.remove(id)
        }
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

    func canDelete(_ entry: TraceLibraryEntry) -> Bool {
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
        organizingIDs.subtract(ids)
    }

    func reload() {
        reloadTask?.cancel()
        isLoading = true
        let store = store
        reloadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                store.libraryEntries()
            }.value
            guard !Task.isCancelled, let self else { return }
            entries = result
            isLoading = false
            scanForDamagedRecordings(result)
        }
    }
}
