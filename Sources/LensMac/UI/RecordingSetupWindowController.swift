import AppKit
import SwiftUI

@MainActor
final class RecordingSetupWindowController {
    private let model: AppModel
    private let window: RecordingSetupPanel
    private let onStart: (RecordingSetupStartRequest) -> Void

    init(model: AppModel, onStart: @escaping (RecordingSetupStartRequest) -> Void) {
        self.model = model
        self.onStart = onStart
        window = RecordingSetupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 844, height: 724),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    func show(initialSource: RecordingSourceChoice = .region) {
        // Privacy-safe default: entering setup never inherits a previous camera opt-in.
        model.capturesCamera = false
        installContent(initialSource: initialSource)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        model.capturesCamera = false
        window.orderOut(nil)
    }

    private func hideForRecordingStart() {
        // Preserve this one explicit camera opt-in until the asynchronous source
        // selection reaches ScreenRecordingOptions. A successful start resets it.
        window.orderOut(nil)
    }

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        // The SwiftUI glass surface owns the rounded rim and shadow. A transparent
        // AppKit titlebar/native shadow here creates an uncovered top strip and a
        // doubled, jagged edge in screenshots.
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.onEscape = { [weak self] in self?.hide() }
    }

    private func installContent(initialSource: RecordingSourceChoice) {
        window.contentView = NSHostingView(
            rootView: RecordingSetupView(
                model: model,
                initialSource: initialSource,
                onStart: { [weak self] request in
                    self?.hideForRecordingStart()
                    self?.onStart(request)
                },
                onClose: { [weak self] in self?.hide() }
            )
            .padding(32)
        )
    }
}

private final class RecordingSetupPanel: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performClose(_ sender: Any?) {
        onEscape?()
    }
}
