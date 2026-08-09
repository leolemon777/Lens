import AppKit
import SwiftUI

@MainActor
final class RecordingControlWindowController {
    private let model = RecordingControlModel()
    private let panel: RecordingPanel
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?

    init() {
        panel = RecordingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 98),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    func begin(
        sourceTitle: String,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        capturesCamera: Bool
    ) {
        model.reset(
            sourceTitle: sourceTitle,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            capturesCamera: capturesCamera
        )
        showExisting()
    }

    func showExisting() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setPaused(_ paused: Bool) {
        model.setPaused(paused)
    }

    func setTransitioning(_ transitioning: Bool) {
        model.isTransitioning = transitioning
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.stop() }
        let root = RecordingControlView(
            model: model,
            onPauseToggle: { [weak self] in self?.onPauseToggle?() },
            onStop: { [weak self] in self?.stop() }
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    private func positionPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 26
        ))
    }

    private func stop() {
        guard !model.isTransitioning else { return }
        hide()
        onStop?()
    }
}

private final class RecordingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
