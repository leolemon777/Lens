import AppKit

/// Shared floating-panel chrome for Lens's glass surfaces. Controllers pick a
/// ``Placement`` instead of copying `canBecomeKey` / `cancelOperation` /
/// origin math in every window subclass.
final class LensGlassPanel: NSPanel {
    enum Placement {
        case center
        case pointer
        case bottomTrailing
        case bottomCenter
        case top

        var presenterAnchor: LensPanelPresenter.Anchor {
            switch self {
            case .center, .pointer: .center
            case .bottomTrailing: .bottomTrailing
            case .bottomCenter, .top: .top
            }
        }
    }

    var onEscape: (() -> Void)?
    var allowsKey: Bool
    var placement: Placement

    init(
        contentRect: NSRect,
        placement: Placement,
        allowsKey: Bool = true,
        nonactivating: Bool = false
    ) {
        self.allowsKey = allowsKey
        self.placement = placement
        var style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if nonactivating {
            style.insert(.nonactivatingPanel)
        }
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    func placeOnScreen(offset: NSPoint = .zero) {
        let size = frame.size
        switch placement {
        case .center:
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            ))
        case .pointer:
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(location) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            setFrameOrigin(NSPoint(
                x: min(
                    max(location.x - size.width / 2, screen.visibleFrame.minX + 12),
                    screen.visibleFrame.maxX - size.width - 12
                ),
                y: min(
                    max(location.y - size.height / 2, screen.visibleFrame.minY + 12),
                    screen.visibleFrame.maxY - size.height - 12
                )
            ))
        case .bottomTrailing:
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(location) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size.width - 18,
                y: screen.visibleFrame.minY + 18
            ))
        case .bottomCenter:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 26
            ))
        case .top:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 18
            ))
        }
        if offset != .zero {
            setFrameOrigin(NSPoint(
                x: frame.origin.x + offset.x,
                y: frame.origin.y + offset.y
            ))
        }
    }
}
