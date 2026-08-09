import AppKit
import ScreenTraceCore

@MainActor
final class PinnedImageWindowController {
    private var windows: [NSWindow] = []

    func pin(trace: SavedTrace, image: NSImage) {
        let maxSize = CGSize(width: 520, height: 420)
        let scale = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let window = PinnedImageWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = imageView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.title = trace.manifest.title
        window.center()
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.windows.removeAll { $0 === window }
        }
        windows.append(window)
        window.orderFrontRegardless()
    }
}

private final class PinnedImageWindow: NSWindow {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            orderOut(nil)
            onClose?()
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            orderOut(nil)
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}
