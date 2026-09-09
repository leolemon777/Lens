import AppKit
import LensCore
import SwiftUI
import UniformTypeIdentifiers

enum ScreenshotEditorClipboardStatus {
    case copied
    case copyFailed
    case notRequested
}

@MainActor
final class ScreenshotAnnotationEditorWindowController {
    private let store: LensProjectStore
    private let editingService: ScreenshotEditingService
    private let onStorageActivityChanged: () -> Void
    private var window: AnnotationEditorWindow?
    private var activeLens: SavedLens?
    private var sourceImage: NSImage?
    private var activeModel: ScreenshotAnnotationEditorModel?
    private var operationTask: Task<Void, Never>?

    var onSaved: ((SavedLens, NSImage, ScreenshotEditorClipboardStatus) -> Void)?
    var onCopyResult: ((Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    var activeStoragePackageURL: URL? {
        guard activeLens != nil || operationTask != nil else { return nil }
        return activeLens?.packageURL.standardizedFileURL
    }

    private enum ScreenshotCodeCardError: LocalizedError {
        case renderingUnavailable

        var errorDescription: String? {
            switch self {
            case .renderingUnavailable:
                "代码卡片生成失败：无法从 OCR 文本渲染图片。"
            }
        }
    }

    init(
        store: LensProjectStore,
        onStorageActivityChanged: @escaping () -> Void = {}
    ) {
        self.onStorageActivityChanged = onStorageActivityChanged
        self.store = store
        editingService = ScreenshotEditingService(store: store)
    }

    func show(lens: SavedLens, fallbackImage: NSImage) {
        guard let dimensions = lens.manifest.dimensions else { return }
        operationTask?.cancel()
        activeModel?.endRendering()
        // Capture quick access and the library already provide the full-size raw
        // image. Reusing it avoids decoding the same large PNG twice on the UI thread.
        let originalImage = fallbackImage
        let existingPlan = LensFailureLog.optional("annotation.plan_load") {
            try store.loadScreenshotEditPlan(from: lens.packageURL)
        }
        let ocrDocument = LensFailureLog.optional("annotation.ocr_load") {
            try store.loadOCR(from: lens.packageURL)
        }
        let suggestedRedactions = ocrDocument.map {
            SensitiveRedactionPlanner().suggestions(ocr: $0)
        } ?? []
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: dimensions,
            existingPlan: existingPlan,
            suggestedRedactions: suggestedRedactions,
            ocrFullText: ocrDocument?.fullText
        )

        activeLens = lens
        sourceImage = originalImage
        activeModel = model
        let window = window ?? makeWindow()
        self.window = window
        let root = ScreenshotAnnotationEditorView(
            model: model,
            image: originalImage,
            onSave: { [weak self] plan in self?.save(plan) },
            onCopy: { [weak self] plan in self?.copy(plan) },
            onExport: { [weak self] plan, format in self?.export(plan, format: format) },
            onExportCodeCard: { [weak self] in self?.exportCodeCard() },
            onCancel: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.onEscape = { [weak self] in self?.hide() }
        window.onCopy = { [weak self, weak model] in
            guard let model else { return }
            self?.copy(model.plan)
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        operationTask?.cancel()
        operationTask = nil
        activeModel?.endRendering()
        window?.orderOut(nil)
        activeLens = nil
        sourceImage = nil
        activeModel = nil
        onStorageActivityChanged()
    }

    private func save(_ plan: ScreenshotEditPlan) {
        guard let activeLens,
              let sourceImage,
              let model = activeModel,
              model.beginRendering() else { return }
        let source: CGImage
        do {
            source = try ImageEncoding.cgImage(from: sourceImage)
        } catch {
            model.endRendering()
            onFailure?(error)
            return
        }
        let service = editingService
        operationTask = Task { @MainActor [weak self, weak model] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.renderAndSave(
                        source: source,
                        plan: plan,
                        lens: activeLens
                    )
                }.value
                guard !Task.isCancelled,
                      let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                let renderedImage = ImageEncoding.nsImage(from: result.renderedImage)
                let copied = copyToClipboard(renderedImage)
                onSaved?(
                    result.lens,
                    renderedImage,
                    copied ? .copied : .copyFailed
                )
                hide()
            } catch {
                guard let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                onFailure?(error)
            }
        }
    }

    @discardableResult
    private func copyToClipboard(_ image: NSImage) -> Bool {
        ImageClipboardWriter.write(image)
    }

    private func copy(_ plan: ScreenshotEditPlan) {
        guard let sourceImage,
              let model = activeModel,
              model.beginRendering() else { return }
        let source: CGImage
        do {
            source = try ImageEncoding.cgImage(from: sourceImage)
        } catch {
            model.endRendering()
            onFailure?(error)
            return
        }
        let service = editingService
        operationTask = Task { @MainActor [weak self, weak model] in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try service.render(source: source, plan: plan)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                let copied = copyToClipboard(ImageEncoding.nsImage(from: rendered))
                model.showClipboardFeedback(succeeded: copied)
                onCopyResult?(copied)
            } catch {
                guard let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                onFailure?(error)
            }
        }
    }

    private func exportCodeCard() {
        guard let text = activeModel?.ocrFullText,
              let card = CodeCardRenderer.render(text: text) else {
            onFailure?(ScreenshotCodeCardError.renderingUnavailable)
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "代码卡片.png"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            onFailure?(ScreenshotCodeCardError.renderingUnavailable)
            return
        }
        CGImageDestinationAddImage(destination, card, nil)
        guard CGImageDestinationFinalize(destination) else {
            onFailure?(ScreenshotCodeCardError.renderingUnavailable)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.selectFile(
            outputURL.path,
            inFileViewerRootedAtPath: outputURL.deletingLastPathComponent().path
        )
    }

    private func export(
        _ plan: ScreenshotEditPlan,
        format: ScreenshotExportFormat
    ) {
        guard let activeLens,
              let sourceImage,
              let model = activeModel,
              !model.isRendering else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        let safeTitle = activeLens.manifest.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).\(format.fileExtension)"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        guard model.beginRendering() else { return }
        let source: CGImage
        do {
            source = try ImageEncoding.cgImage(from: sourceImage)
        } catch {
            model.endRendering()
            onFailure?(error)
            return
        }
        let service = editingService
        operationTask = Task { @MainActor [weak self, weak model] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try service.renderAndSave(
                        source: source,
                        plan: plan,
                        lens: activeLens
                    )
                    try service.export(
                        image: result.renderedImage,
                        to: outputURL,
                        format: format
                    )
                    return result
                }.value
                guard !Task.isCancelled,
                      let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                onSaved?(
                    result.lens,
                    ImageEncoding.nsImage(from: result.renderedImage),
                    .notRequested
                )
                hide()
            } catch {
                guard let self,
                      let model,
                      self.activeModel === model else { return }
                model.endRendering()
                operationTask = nil
                onFailure?(error)
            }
        }
    }

    private func makeWindow() -> AnnotationEditorWindow {
        let window = AnnotationEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lens · 标注截图"
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

private final class AnnotationEditorWindow: LensChromeWindow {
    var onCopy: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            if firstResponder is NSTextView || firstResponder is NSTextField {
                return super.performKeyEquivalent(with: event)
            }
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
