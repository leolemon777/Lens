import AppKit

@MainActor
final class CaptureOverlayWindow: NSWindow {
    init(screen: NSScreen, displayID: CGDirectDisplayID, delegate: CaptureOverlayViewDelegate) {
        let view = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            displayID: displayID
        )
        view.delegate = delegate

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        contentView = view
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
