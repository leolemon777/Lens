import Foundation
import ScreenTraceCore

@MainActor
final class TraceLibraryModel: ObservableObject {
    let store: TraceProjectStore

    @Published private(set) var entries: [TraceLibraryEntry]
    @Published var query = ""
    @Published var filter: TraceLibraryFilter = .all
    @Published private(set) var isLoading = false

    private var reloadTask: Task<Void, Never>?

    init(store: TraceProjectStore, initialEntries: [TraceLibraryEntry] = []) {
        self.store = store
        entries = initialEntries
    }

    deinit {
        reloadTask?.cancel()
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
        }
    }
}
