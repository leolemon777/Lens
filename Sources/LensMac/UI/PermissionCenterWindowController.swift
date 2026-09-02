import AppKit
import SwiftUI

@MainActor
final class PermissionCenterWindowController {
    private let model: PermissionCenterModel
    private let window: LensChromeWindow
    private let appModel: AppModel
    private let onShortcutsChanged: () -> Void
    private let onShortcutCaptureActiveChange: (Bool) -> Void

    init(
        appModel: AppModel,
        onShortcutsChanged: @escaping () -> Void,
        onShortcutCaptureActiveChange: @escaping (Bool) -> Void = { _ in },
        diagnosticSummaryProvider: @escaping @MainActor () async -> String
    ) {
        self.appModel = appModel
        self.onShortcutsChanged = onShortcutsChanged
        self.onShortcutCaptureActiveChange = onShortcutCaptureActiveChange
        model = PermissionCenterModel(
            diagnosticSummaryProvider: diagnosticSummaryProvider
        )
        window = LensChromeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 678, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
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
        LensPanelPresenter.present(window, from: .center)
        window.makeKey()
    }

    func hide() {
        LensPanelPresenter.dismiss(window)
        onShortcutCaptureActiveChange(false)
    }

    private func configureWindow() {
        window.title = "设置与权限"
        window.titleVisibility = .visible
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.onEscape = { [weak self] in self?.hide() }

        let root = PermissionCenterView(
            model: model,
            appModel: appModel,
            onShortcutsChanged: onShortcutsChanged,
            onShortcutCaptureActiveChange: onShortcutCaptureActiveChange,
            onClose: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }
}
