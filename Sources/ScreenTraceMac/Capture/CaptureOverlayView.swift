import AppKit

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidCancel(_ view: CaptureOverlayView)
    func captureOverlay(_ view: CaptureOverlayView, didSelect rect: CGRect, displayID: CGDirectDisplayID)
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?

    private let displayID: CGDirectDisplayID
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(frame: CGRect, displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selection else {
            drawGuidance()
            return
        }

        NSColor.clear.setFill()
        selection.fill(using: .copy)

        let border = NSBezierPath(roundedRect: selection, xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.96).setStroke()
        border.lineWidth = 1.5
        border.stroke()

        NSColor.systemCyan.withAlphaComponent(0.76).setStroke()
        let glow = NSBezierPath(roundedRect: selection.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4)
        glow.lineWidth = 1
        glow.stroke()

        drawDimensionPill(for: selection)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clipped(convert(event.locationInWindow, from: nil))
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clipped(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = clipped(convert(event.locationInWindow, from: nil))
        guard let selection, selection.width >= 3, selection.height >= 3 else {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
            return
        }
        delegate?.captureOverlay(self, didSelect: selection, displayID: displayID)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.captureOverlayDidCancel(self)
            return
        }
        super.keyDown(with: event)
    }

    private var selection: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private func clipped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func drawGuidance() {
        let text = "拖动选择区域  ·  Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let size = text.size(withAttributes: attributes)
        let frame = CGRect(
            x: bounds.midX - size.width / 2 - 13,
            y: bounds.midY - size.height / 2 - 8,
            width: size.width + 26,
            height: size.height + 16
        )
        let pill = NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
        NSColor.black.withAlphaComponent(0.38).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        text.draw(at: CGPoint(x: frame.minX + 13, y: frame.minY + 8), withAttributes: attributes)
    }

    private func drawDimensionPill(for rect: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = textSize.width + 18
        let height = textSize.height + 10
        let desiredY = rect.maxY + 9
        let y = desiredY + height <= bounds.maxY ? desiredY : max(bounds.minY + 6, rect.minY - height - 9)
        let x = min(max(rect.midX - width / 2, bounds.minX + 6), bounds.maxX - width - 6)
        let frame = CGRect(x: x, y: y, width: width, height: height)

        let pill = NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        text.draw(
            at: CGPoint(x: frame.minX + 9, y: frame.minY + 5),
            withAttributes: attributes
        )
    }
}
