import AppKit
import SwiftUI

@MainActor
final class PermissionCenterWindowController {
    private let model = PermissionCenterModel()
    private let window: PermissionPanel

    init() {
        window = PermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 678, height: 628),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    func show() {
        model.refresh()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    private func configureWindow() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isMovableByWindowBackground = true
        window.onEscape = { [weak self] in self?.hide() }

        let root = PermissionCenterView(model: model) { [weak self] in
            self?.hide()
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }
}

private final class PermissionPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
