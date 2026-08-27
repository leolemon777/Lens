import AppKit
import LensCore
import SwiftUI

@MainActor
final class QuickAccessWindowController {
    private var panel: QuickAccessPanel?
    private var dismissTask: Task<Void, Never>?
    private var activeLens: SavedLens?
    private var activeImage: NSImage?
    private var confirmationTitle = "截图已复制"
    var onPinRequested: ((SavedLens, NSImage) -> Void)?
    var onAnnotateRequested: ((SavedLens, NSImage) -> Void)?
    var onEditRequested: ((SavedLens) -> Void)?
    var onConversationInboxRequested: ((Data) -> Void)?
    var onCopyResult: ((Bool) -> Void)?

    func show(
        lens: SavedLens,
        image: NSImage,
        confirmationTitle: String = "截图已复制"
    ) {
        dismissTask?.cancel()
        activeLens = lens
        activeImage = image
        self.confirmationTitle = confirmationTitle

        let panel = panel ?? makePanel()
        self.panel = panel
        let dragFileURL = QuickAccessFileTransfer.bestFileURL(for: lens)
        let view = QuickAccessView(
            lens: lens,
            image: image,
            dragFileURL: dragFileURL,
            dragSuggestedName: dragFileURL.map {
                QuickAccessFileTransfer.suggestedFileName(for: lens, fileURL: $0)
            },
            confirmationTitle: confirmationTitle,
            onCopy: { [weak self] in self?.copyActive() },
            onAnnotate: { [weak self] in self?.requestAnnotation() },
            onEdit: { [weak self] in self?.requestEdit() },
            onReveal: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([revealURL(for: lens)])
            },
            onPin: { [weak self] in self?.requestPin() },
            onConversationInbox: { [weak self] in self?.requestConversationInbox() },
            onClose: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: view)
        position(panel)
        panel.orderFrontRegardless()

        // Recordings stay until dismissed so the user can drag the file.
        // Screenshots already live on the clipboard, so the card can retire.
        if lens.manifest.kind == .recording {
            dismissTask = nil
        } else {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func updateIfShowing(
        _ lens: SavedLens,
        thumbnail: NSImage? = nil,
        confirmationTitle: String
    ) {
        guard let activeLens, activeLens.manifest.id == lens.manifest.id,
              panel?.isVisible == true else { return }
        show(
            lens: lens,
            image: thumbnail ?? activeImage ?? NSWorkspace.shared.icon(forFile: lens.rawAssetURL.path),
            confirmationTitle: confirmationTitle
        )
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickAccessPanel {
        let panel = QuickAccessPanel(
            contentRect: NSRect(x: 0, y: 0, width: 564, height: 152),
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

    private func copyActive() {
        guard let activeLens else { return }
        if activeLens.manifest.kind == .recording {
            let fileURL = QuickAccessFileTransfer.bestFileURL(for: activeLens)
                ?? activeLens.rawAssetURL
            onCopyResult?(FileURLPasteboard.copy(fileURL))
            return
        }
        guard let activeImage else { return }
        onCopyResult?(ImageClipboardWriter.write(activeImage))
    }

    private func requestPin() {
        guard let activeLens, let activeImage else { return }
        onPinRequested?(activeLens, activeImage)
    }

    private func requestAnnotation() {
        guard let activeLens, let activeImage else { return }
        hide()
        onAnnotateRequested?(activeLens, activeImage)
    }

    private func requestEdit() {
        guard let activeLens else { return }
        hide()
        onEditRequested?(activeLens)
    }

    private func requestConversationInbox() {
        guard let activeLens else { return }
        let fileURL = QuickAccessFileTransfer.bestFileURL(for: activeLens)
            ?? activeLens.rawAssetURL
        guard let pngData = try? Data(contentsOf: fileURL), !pngData.isEmpty else { return }
        onConversationInboxRequested?(pngData)
    }

    private func revealURL(for lens: SavedLens) -> URL {
        QuickAccessFileTransfer.bestFileURL(for: lens) ?? lens.rawAssetURL
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
