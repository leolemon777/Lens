import AppKit
import ScreenTraceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotAnnotationEditorWindowController {
    private let store: TraceProjectStore
    private let editingService: ScreenshotEditingService
    private var window: AnnotationEditorWindow?
    private var activeTrace: SavedTrace?
    private var sourceImage: NSImage?

    var onSaved: ((SavedTrace, NSImage) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(store: TraceProjectStore) {
        self.store = store
        editingService = ScreenshotEditingService(store: store)
    }

    func show(trace: SavedTrace, fallbackImage: NSImage) {
        guard let dimensions = trace.manifest.dimensions else { return }
        let originalImage = NSImage(contentsOf: trace.rawAssetURL) ?? fallbackImage
        let existingPlan = try? store.loadScreenshotEditPlan(from: trace.packageURL)
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: dimensions,
            existingPlan: existingPlan
        )

        activeTrace = trace
        sourceImage = originalImage
        let window = window ?? makeWindow()
        self.window = window
        let root = ScreenshotAnnotationEditorView(
            model: model,
            image: originalImage,
            onSave: { [weak self] plan in self?.save(plan) },
            onExport: { [weak self] plan, format in self?.export(plan, format: format) },
            onCancel: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.onEscape = { [weak self] in self?.hide() }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        activeTrace = nil
        sourceImage = nil
    }

    private func save(_ plan: ScreenshotEditPlan) {
        guard let activeTrace, let sourceImage else { return }
        do {
            let source = try ImageEncoding.cgImage(from: sourceImage)
            let result = try editingService.renderAndSave(
                source: source,
                plan: plan,
                trace: activeTrace
            )
            let renderedImage = ImageEncoding.nsImage(from: result.renderedImage)
            copyToClipboard(renderedImage)
            onSaved?(result.trace, renderedImage)
            hide()
        } catch {
            onFailure?(error)
        }
    }

    private func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func export(
        _ plan: ScreenshotEditPlan,
        format: ScreenshotExportFormat
    ) {
        guard let activeTrace, let sourceImage else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        let safeTitle = activeTrace.manifest.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).\(format.fileExtension)"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        do {
            let source = try ImageEncoding.cgImage(from: sourceImage)
            let result = try editingService.renderAndSave(
                source: source,
                plan: plan,
                trace: activeTrace
            )
            try editingService.export(
                image: result.renderedImage,
                to: outputURL,
                format: format
            )
            onSaved?(result.trace, ImageEncoding.nsImage(from: result.renderedImage))
            hide()
        } catch {
            onFailure?(error)
        }
    }

    private func makeWindow() -> AnnotationEditorWindow {
        let window = AnnotationEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "屏迹 · 标注截图"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 900, height: 620)
        window.collectionBehavior = [.fullScreenPrimary]
        return window
    }
}

private final class AnnotationEditorWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
