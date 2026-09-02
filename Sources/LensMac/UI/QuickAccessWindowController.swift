import AppKit
import LensCore
import SwiftUI

@MainActor
final class QuickAccessWindowController {
    private var panel: LensGlassPanel?
    private var hostingView: NSHostingView<QuickAccessView>?
    private var dismissTask: Task<Void, Never>?
    private var activeLens: SavedLens?
    private var activeImage: NSImage?
    private var confirmationTitle = "截图已复制"
    private let progressModel = QuickAccessProgressModel()
    private let stackModel = QuickAccessStackModel()
    var onPinRequested: ((SavedLens, NSImage) -> Void)?
    var onAnnotateRequested: ((SavedLens, NSImage) -> Void)?
    var onEditRequested: ((SavedLens) -> Void)?
    var onConversationInboxRequested: ((Data) -> Void)?
    var onRetryRequested: ((SavedLens) -> Void)?
    var onCopyResult: ((Bool) -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }
    var panelForTesting: NSPanel? { panel }
    var stackModelForTesting: QuickAccessStackModel { stackModel }
    /// Overrides the real 9-second auto-dismiss so tests don't block for it.
    static var dismissDurationOverride: Duration?

    func show(
        lens: SavedLens,
        image: NSImage,
        confirmationTitle: String = "截图已复制",
        deliveryState: QuickAccessDeliveryState? = nil,
        handoffFrom outgoingWindow: NSWindow? = nil
    ) {
        dismissTask?.cancel()
        activeLens = lens
        activeImage = image
        self.confirmationTitle = confirmationTitle
        let resolvedDeliveryState = deliveryState
            ?? QuickAccessDeliveryState.inferred(
                for: lens,
                confirmationTitle: confirmationTitle
            )

        let panel = panel ?? makePanel()
        self.panel = panel
        // Reset only when a processing run is starting: `updateIfShowing`
        // replays through this same path when processing finishes, and
        // that later call must not wipe the fraction it is about to render
        // one last time at 100%.
        if resolvedDeliveryState == .processing {
            progressModel.reset()
        }
        _ = stackModel.upsert(QuickAccessStackEntry(
            lens: lens,
            thumbnail: Self.thumbnail(from: image),
            confirmationTitle: confirmationTitle,
            deliveryState: resolvedDeliveryState
        ))
        let dragFileURL = QuickAccessFileTransfer.bestFileURL(for: lens)
        let view = QuickAccessView(
            lens: lens,
            image: image,
            dragFileURL: dragFileURL,
            dragSuggestedName: dragFileURL.map {
                QuickAccessFileTransfer.suggestedFileName(for: lens, fileURL: $0)
            },
            confirmationTitle: confirmationTitle,
            deliveryState: resolvedDeliveryState,
            progressModel: progressModel,
            stackModel: stackModel,
            onToggleExpansion: { [weak self] in self?.toggleExpansion() },
            onCopyStackEntry: { [weak self] id in self?.copyStackEntry(id: id) },
            onRemoveStackEntry: { [weak self] id in self?.removeStackEntry(id: id) },
            onCopy: { [weak self] in self?.copyActive() },
            onAnnotate: { [weak self] in self?.requestAnnotation() },
            onEdit: { [weak self] in self?.requestEdit() },
            onReveal: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([revealURL(for: lens)])
            },
            onPin: { [weak self] in self?.requestPin() },
            onConversationInbox: { [weak self] in self?.requestConversationInbox() },
            onShare: { [weak self] in self?.shareActive() },
            onRetry: { [weak self] in self?.requestRetry() },
            onClose: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: view)
        self.hostingView = hostingView
        panel.contentView = hostingView
        resizeToFitContent()
        if let outgoingWindow {
            LensPanelPresenter.handoff(from: outgoingWindow, to: panel, anchor: .bottomTrailing)
        } else if panel.isVisible {
            LensPanelPresenter.update(panel)
        } else {
            LensPanelPresenter.present(panel, from: .bottomTrailing)
        }
        panel.makeKey()

        // Recordings stay until dismissed so the user can drag the file.
        // Screenshots already live on the clipboard, so the card can retire.
        // Either way, an expanded stack pauses the countdown: dismissing out
        // from under a list the user is actively browsing would be jarring.
        if lens.manifest.kind == .recording || stackModel.isExpanded {
            dismissTask = nil
        } else {
            scheduleAutoDismiss()
        }
    }

    private func scheduleAutoDismiss() {
        let duration = Self.dismissDurationOverride ?? .seconds(9)
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Test-only entry point for the same path the "+N" badge triggers.
    func setStackExpandedForTesting(_ expanded: Bool) {
        guard expanded != stackModel.isExpanded else { return }
        toggleExpansion()
    }

    /// Downscales to the existing 118×72 preview size before it enters the
    /// stack; only the current primary capture's full-resolution image is
    /// ever retained, so keeping several recent captures alive stays cheap.
    private static func thumbnail(
        from image: NSImage,
        maxSize: CGSize = CGSize(width: 118, height: 72)
    ) -> NSImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let scale = min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height, 1)
        guard scale < 1 else { return image }
        let targetSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        image.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: CGRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }

    private func toggleExpansion() {
        stackModel.isExpanded.toggle()
        if stackModel.isExpanded {
            dismissTask?.cancel()
            dismissTask = nil
        } else if let activeLens, activeLens.manifest.kind != .recording {
            // Collapsing restarts a fresh countdown rather than resuming a
            // partially-elapsed one — simpler, and "paused while expanded"
            // only promises nothing dismisses *during* that time.
            scheduleAutoDismiss()
        }
        resizeToFitContent()
    }

    private func copyStackEntry(id: UUID) {
        guard let entry = stackModel.entries.first(where: { $0.id == id }) else { return }
        if entry.lens.manifest.kind == .recording {
            let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry.lens)
                ?? entry.lens.rawAssetURL
            onCopyResult?(FileURLPasteboard.copy(fileURL))
            return
        }
        // The full-resolution image was never retained for a background
        // entry (only its thumbnail was) — read it back from disk for this
        // one explicit action rather than holding every stacked capture's
        // original in memory continuously.
        guard let fileURL = QuickAccessFileTransfer.bestFileURL(for: entry.lens),
              let fullImage = NSImage(contentsOf: fileURL) else {
            onCopyResult?(false)
            return
        }
        onCopyResult?(ImageClipboardWriter.write(fullImage))
    }

    private func removeStackEntry(id: UUID) {
        let isNowEmpty = stackModel.remove(id: id)
        if isNowEmpty {
            hide()
        } else {
            resizeToFitContent()
        }
    }

    /// Resizes to the current SwiftUI content's ideal size, keeping the
    /// panel's bottom-right corner anchored (matching `position`) so
    /// growing to show the expanded stack extends upward from that corner
    /// instead of drifting.
    private func resizeToFitContent() {
        guard let panel, let hostingView else { return }
        let fitted = hostingView.fittingSize
        guard fitted.width > 0, fitted.height > 0 else { return }
        if panel.isVisible {
            let origin = NSPoint(
                x: panel.frame.maxX - fitted.width,
                y: panel.frame.minY
            )
            panel.setFrame(NSRect(origin: origin, size: fitted), display: true)
        } else {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: fitted), display: true)
            position(panel)
        }
    }

    func updateIfShowing(
        _ lens: SavedLens,
        thumbnail: NSImage? = nil,
        confirmationTitle: String,
        deliveryState: QuickAccessDeliveryState? = nil
    ) {
        guard let activeLens, activeLens.manifest.id == lens.manifest.id,
              panel?.isVisible == true else { return }
        show(
            lens: lens,
            image: thumbnail ?? activeImage ?? NSWorkspace.shared.icon(forFile: lens.rawAssetURL.path),
            confirmationTitle: confirmationTitle,
            deliveryState: deliveryState
        )
    }

    /// Ignored unless `lens` still matches what's on screen: a background
    /// render's progress must not bleed into a panel a newer capture has
    /// since taken over, and `AppDelegate.processRecording` never awaits
    /// its own render before returning, so a stale/superseded caller is a
    /// real possibility here, not just defensive padding.
    func updateProgress(_ fraction: Double, for lens: SavedLens) {
        guard let activeLens, activeLens.manifest.id == lens.manifest.id,
              panel?.isVisible == true else { return }
        progressModel.fraction = min(max(fraction, 0), 1)
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        LensPanelPresenter.dismiss(panel)
    }

    private func makePanel() -> LensGlassPanel {
        // Activating + key so Esc / ⌘C reach the card. Recording HUD stays
        // nonactivating; this panel is a post-capture action surface.
        let panel = LensGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 392),
            placement: .bottomTrailing
        )
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.hide() }
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
        guard let pngData = LensFailureLog.optional(
            "quickAccess.conversationInbox.read",
            { try Data(contentsOf: fileURL) }
        ), !pngData.isEmpty else { return }
        onConversationInboxRequested?(pngData)
    }

    private func requestRetry() {
        guard let activeLens else { return }
        onRetryRequested?(activeLens)
    }

    private func shareActive() {
        guard let activeLens,
              let fileURL = QuickAccessFileTransfer.bestFileURL(for: activeLens) else { return }
        LensFileSharing.present(fileURL: fileURL)
    }

    private func revealURL(for lens: SavedLens) -> URL {
        QuickAccessFileTransfer.bestFileURL(for: lens) ?? lens.rawAssetURL
    }
}
