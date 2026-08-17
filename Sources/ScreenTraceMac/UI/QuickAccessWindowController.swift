import AppKit
import ScreenTraceCore
import SwiftUI

@MainActor
final class QuickAccessWindowController {
    private var panel: QuickAccessPanel?
    private var dismissTask: Task<Void, Never>?
    private var activeTrace: SavedTrace?
    private var activeImage: NSImage?
    var onPinRequested: ((SavedTrace, NSImage) -> Void)?
    var onAnnotateRequested: ((SavedTrace, NSImage) -> Void)?
    var onCopyResult: ((Bool) -> Void)?

    func show(
        trace: SavedTrace,
        image: NSImage,
        confirmationTitle: String = "截图已复制"
    ) {
        dismissTask?.cancel()
        activeTrace = trace
        activeImage = image

        let panel = panel ?? makePanel()
        self.panel = panel
        let dragFileURL = QuickAccessFileTransfer.bestFileURL(for: trace)
        let view = QuickAccessView(
            trace: trace,
            image: image,
            dragFileURL: dragFileURL,
            dragSuggestedName: dragFileURL.map {
                QuickAccessFileTransfer.suggestedFileName(for: trace, fileURL: $0)
            },
            confirmationTitle: confirmationTitle,
            onCopy: { [weak self] in self?.copyActiveImage() },
            onAnnotate: { [weak self] in self?.requestAnnotation() },
            onReveal: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([revealURL(for: trace)])
            },
            onPin: { [weak self] in self?.requestPin() },
            onClose: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: view)
        position(panel)
        panel.orderFrontRegardless()

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(x: 0, y: 0, width: 486, height: 152),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - 18,
            y: screen.visibleFrame.minY + 18
        ))
    }

    private func copyActiveImage() {
        guard let activeImage else { return }
        onCopyResult?(ImageClipboardWriter.write(activeImage))
    }

    private func requestPin() {
        guard let activeTrace, let activeImage else { return }
        onPinRequested?(activeTrace, activeImage)
    }

    private func requestAnnotation() {
        guard let activeTrace, let activeImage else { return }
        hide()
        onAnnotateRequested?(activeTrace, activeImage)
    }

    private func revealURL(for trace: SavedTrace) -> URL {
        trace.manifest.assets.first(where: { $0.role == .renderedScreenshot })
            .map { trace.packageURL.appendingPathComponent($0.relativePath) }
            ?? trace.rawAssetURL
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
