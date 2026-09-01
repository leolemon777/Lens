import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class ActionCenterWindowController {
    private let panel: LensPanel
    private let model: AppModel
    private let onAction: (ActionCenterAction) -> Void

    init(model: AppModel, onAction: @escaping (ActionCenterAction) -> Void) {
        self.model = model
        self.onAction = onAction
        panel = LensPanel(
            contentRect: NSRect(x: 0, y: 0, width: 688, height: 430),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        installRoot()
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2 + 24
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        LensPanelPresenter.present(panel, from: .center)
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

    private func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}

private final class LensPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
