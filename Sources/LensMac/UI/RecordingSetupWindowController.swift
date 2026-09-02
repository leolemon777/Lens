import AppKit
import SwiftUI

@MainActor
final class RecordingSetupWindowController {
    private let model: AppModel
    private let window: LensGlassPanel
    private let onStart: (RecordingSetupStartRequest) -> Void

    init(model: AppModel, onStart: @escaping (RecordingSetupStartRequest) -> Void) {
        self.model = model
        self.onStart = onStart
        window = LensGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 844, height: 724),
            placement: .center
        )
        configureWindow()
    }

    func show(initialSource: RecordingSourceChoice = .region) {
        // Privacy-safe default: entering setup never inherits a previous camera opt-in.
        model.capturesCamera = false
        installContent(initialSource: initialSource)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        LensPanelPresenter.present(window, from: .center)
        window.makeKey()
    }

    func hide() {
        model.capturesCamera = false
        LensPanelPresenter.dismiss(window)
    }

    private func hideForRecordingStart() {
        LensPanelPresenter.dismiss(window)
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
