import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class ActionCenterWindowController {
    private let panel: LensGlassPanel
    private let model: AppModel
    private let onAction: (ActionCenterAction) -> Void

    init(model: AppModel, onAction: @escaping (ActionCenterAction) -> Void) {
        self.model = model
        self.onAction = onAction
        panel = LensGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 688, height: 430),
            placement: .center
        )
        configurePanel()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        installRoot()
        panel.placeOnScreen()
        NSApp.activate(ignoringOtherApps: true)
        LensPanelPresenter.present(panel, from: panel.placement.presenterAnchor)
        panel.makeKey()
    }

    func hide() {
        LensPanelPresenter.dismiss(panel)
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.hide() }
        installRoot()
    }

    private func installRoot() {
        let root = ActionCenterView(
            model: model,
            hotKeysNeedAccessibility: !AXIsProcessTrusted(),
            onAction: { [weak self] action in
                self?.onAction(action)
            }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }
}
