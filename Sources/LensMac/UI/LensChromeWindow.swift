import AppKit

/// Shared titled-window chrome for document-style Lens windows. Floating glass
/// panels stay on ``LensGlassPanel``; this type only unifies `cancelOperation`
/// so library, editor, settings and annotation no longer each copy a subclass.
class LensChromeWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
