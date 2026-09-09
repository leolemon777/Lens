import AppKit
import SwiftUI

@MainActor
final class PermissionCenterWindowController {
    private let model: PermissionCenterModel
    private let window: LensChromeWindow
    private let appModel: AppModel
    private let onShortcutsChanged: () -> Void
    private let onShortcutCaptureActiveChange: (Bool) -> Void
    private let onManageStorage: () -> Void
    private let onCancelStorageMigration: () -> Void
    private let updateModel: LensUpdateCheckModel
    private let activityStateProvider: @MainActor () -> LensUpdateActivityState

    init(
        appModel: AppModel,
        onShortcutsChanged: @escaping () -> Void,
        onShortcutCaptureActiveChange: @escaping (Bool) -> Void = { _ in },
        onManageStorage: @escaping () -> Void = {},
        onCancelStorageMigration: @escaping () -> Void = {},
        updateModel: LensUpdateCheckModel = LensUpdateCheckModel(),
        activityStateProvider: @escaping @MainActor () -> LensUpdateActivityState = {
            LensUpdateActivityState()
        },
        diagnosticSummaryProvider: @escaping @MainActor () async -> String
    ) {
        self.appModel = appModel
        self.onShortcutsChanged = onShortcutsChanged
        self.onShortcutCaptureActiveChange = onShortcutCaptureActiveChange
        self.onManageStorage = onManageStorage
        self.onCancelStorageMigration = onCancelStorageMigration
        self.updateModel = updateModel
        self.activityStateProvider = activityStateProvider
        updateModel.bindActivityStateProvider(activityStateProvider)
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
        updateModel.refreshActivityState()
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
            updateModel: updateModel,
            onShortcutsChanged: onShortcutsChanged,
            onShortcutCaptureActiveChange: onShortcutCaptureActiveChange,
            onClose: { [weak self] in self?.hide() },
            onManageStorage: onManageStorage,
            onCancelStorageMigration: onCancelStorageMigration
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }
}
