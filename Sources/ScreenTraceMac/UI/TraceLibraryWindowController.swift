import AppKit
import ScreenTraceCore
import SwiftUI

@MainActor
final class TraceLibraryWindowController {
    private let store: TraceProjectStore
    private let model: TraceLibraryModel
    private let window: TraceLibraryWindow

    var onAnnotateRequested: ((SavedTrace, NSImage) -> Void)?
    var onEditRecordingRequested: ((TraceLibraryEntry) -> Void)?
    var onTranscriptionRequested: ((TraceLibraryEntry) -> Void)?
    var onOrganizationRequested: ((TraceLibraryEntry) -> Void)?
    var onInsightsCustomizationRequested: ((TraceLibraryEntry, TraceInsightsCustomization?) -> Void)?

    init(store: TraceProjectStore) {
        self.store = store
        model = TraceLibraryModel(store: store)
        window = TraceLibraryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        model.reload()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    func setTranscribing(_ isTranscribing: Bool, traceID: UUID) {
        model.setTranscribing(isTranscribing, id: traceID)
    }

    func setOrganizing(_ isOrganizing: Bool, traceID: UUID) {
        model.setOrganizing(isOrganizing, id: traceID)
    }

    private func configureWindow() {
        window.title = "屏迹库"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 580)
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenPrimary]
        window.onEscape = { [weak self] in self?.hide() }

        let root = TraceLibraryView(
            model: model,
            onOpen: { [weak self] in self?.open($0) },
            onReveal: { [weak self] in self?.reveal($0) },
            onCopy: { [weak self] in self?.copy($0) },
            onAnnotate: { [weak self] in self?.annotate($0) },
            onTranscribe: { [weak self] in self?.transcribe($0) },
            onOrganize: { [weak self] in self?.organize($0) },
            onSaveInsights: { [weak self] entry, customization in
                self?.saveInsights(entry, customization: customization)
            },
            onOpenFolder: { [weak self] in self?.openFolder() },
            onClose: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    private func open(_ entry: TraceLibraryEntry) {
        if entry.manifest.kind == .recording {
            onEditRecordingRequested?(entry)
            return
        }
        let url = FileManager.default.fileExists(atPath: entry.displayAssetURL.path)
            ? entry.displayAssetURL
            : entry.packageURL
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ entry: TraceLibraryEntry) {
        let url = FileManager.default.fileExists(atPath: entry.displayAssetURL.path)
            ? entry.displayAssetURL
            : entry.packageURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ entry: TraceLibraryEntry) {
        guard entry.manifest.kind == .screenshot,
              let image = NSImage(contentsOf: entry.displayAssetURL) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func annotate(_ entry: TraceLibraryEntry) {
        guard entry.manifest.kind == .screenshot,
              let image = NSImage(contentsOf: entry.primaryAssetURL) else { return }
        let trace = SavedTrace(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        )
        onAnnotateRequested?(trace, image)
    }

    private func transcribe(_ entry: TraceLibraryEntry) {
        guard entry.manifest.kind == .recording else { return }
        onTranscriptionRequested?(entry)
    }

    private func organize(_ entry: TraceLibraryEntry) {
        onOrganizationRequested?(entry)
    }

    private func saveInsights(
        _ entry: TraceLibraryEntry,
        customization: TraceInsightsCustomization?
    ) {
        onInsightsCustomizationRequested?(entry, customization)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.rootDirectory)
    }
}

private final class TraceLibraryWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
