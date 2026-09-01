import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private let model: OnboardingModel
    private let appModel: AppModel
    private let permissionRequests = PermissionCenterModel()
    private let window: OnboardingPanel
    private let onFinished: () -> Void
    private let onQuitRequested: () -> Void

    init(
        appModel: AppModel,
        model: OnboardingModel = OnboardingModel(),
        onQuitRequested: @escaping () -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.model = model
        self.onQuitRequested = onQuitRequested
        self.onFinished = onFinished
        window = OnboardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 678, height: 508),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    var shouldPresentOnLaunch: Bool { model.shouldPresentOnLaunch }

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
    }

    /// Permission grants land in System Settings, so the guide has to recheck
    /// when the user comes back rather than wait for a notification that TCC
    /// does not send.
    func refresh() {
        model.refresh()
    }

    private func configureWindow() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isMovableByWindowBackground = true
        // Escape finishes rather than only hiding, so a user who dismisses the
        // guide is not shown it again on every launch.
        window.onEscape = { [weak self] in self?.finish() }

        let root = OnboardingView(
            model: model,
            appModel: appModel,
            onGrant: { [weak self] kind in self?.grant(kind) },
            onQuit: { [weak self] in self?.onQuitRequested() },
            onFinish: { [weak self] in self?.finish() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    /// The request flows themselves already live in the permission center, so
    /// the guide drives that model rather than duplicating six system calls
    /// that would then have to be kept in sync.
    private func grant(_ kind: SystemPermissionKind) {
        if kind == .screenCapture {
            model.noteScreenCaptureRequested()
        }
        permissionRequests.performPrimaryAction(for: kind)
        model.refresh()
    }

    private func finish() {
        model.markPresentationComplete(build: BuildIdentity.current.buildNumber)
        hide()
        onFinished()
    }
}

private final class OnboardingPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
