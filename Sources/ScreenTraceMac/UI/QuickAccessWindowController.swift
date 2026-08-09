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

    func show(trace: SavedTrace, image: NSImage) {
        dismissTask?.cancel()
        activeTrace = trace
        activeImage = image

        let panel = panel ?? makePanel()
        self.panel = panel
        let view = QuickAccessView(
            trace: trace,
            image: image,
            onCopy: { [weak self] in self?.copyActiveImage() },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([trace.rawAssetURL]) },
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
            contentRect: NSRect(x: 0, y: 0, width: 486, height: 128),
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([activeImage])
    }

    private func requestPin() {
        guard let activeTrace, let activeImage else { return }
        onPinRequested?(activeTrace, activeImage)
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
