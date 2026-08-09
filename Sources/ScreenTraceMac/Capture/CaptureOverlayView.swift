import AppKit
import ScreenTraceCore

enum CaptureOverlayMode {
    case region(action: CaptureOverlayAction)
    case window(candidates: [WindowSelectionCandidate], action: CaptureOverlayAction)
}

enum CaptureOverlayAction {
    case screenshot
    case recording

    var regionGuidance: String {
        switch self {
        case .screenshot: "拖动选择区域  ·  Esc 取消"
        case .recording: "拖动选择录制区域  ·  Esc 取消"
        }
    }

    var windowGuidance: String {
        switch self {
        case .screenshot: "移动选择窗口  ·  单击截取  ·  Esc 取消"
        case .recording: "移动选择窗口  ·  单击开始录制  ·  Esc 取消"
        }
    }
}

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidCancel(_ view: CaptureOverlayView)
    func captureOverlay(_ view: CaptureOverlayView, didSelect rect: CGRect, displayID: CGDirectDisplayID)
    func captureOverlay(_ view: CaptureOverlayView, didSelectWindow windowID: CGWindowID)
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?

    private let displayID: CGDirectDisplayID
    private let displayBounds: CGRect
    private let mode: CaptureOverlayMode
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hoveredWindow: WindowSelectionCandidate?
    private var mouseTrackingArea: NSTrackingArea?

    init(
        frame: CGRect,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        mode: CaptureOverlayMode
    ) {
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.mode = mode
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

        switch mode {
        case let .region(action):
            guard let selection else {
                drawGuidance(action.regionGuidance)
                return
            }
            punchOut(selection)
            drawSelectionBorder(selection)
            drawDimensionPill(for: selection)
        case let .window(_, action):
            guard let hoveredWindow,
                  let localRect = CaptureGeometry.localIntersection(
                    of: hoveredWindow.globalFrame,
                    displayBounds: displayBounds
                  ) else {
                drawGuidance(action.windowGuidance)
                return
            }
            punchOut(localRect)
            drawSelectionBorder(localRect)
            drawWindowPill(for: hoveredWindow, selection: localRect)
        }
    }

    override func resetCursorRects() {
        switch mode {
        case .region:
            addCursorRect(bounds, cursor: .crosshair)
        case .window:
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func updateTrackingAreas() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        guard case .region = mode else {
            updateHoveredWindow(with: event)
            return
        }
        let point = clipped(convert(event.locationInWindow, from: nil))
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .region = mode else { return }
        currentPoint = clipped(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            currentPoint = clipped(convert(event.locationInWindow, from: nil))
            guard let selection, selection.width >= 3, selection.height >= 3 else {
                startPoint = nil
                currentPoint = nil
                needsDisplay = true
                return
            }
            delegate?.captureOverlay(self, didSelect: selection, displayID: displayID)
        case .window:
            updateHoveredWindow(with: event)
            guard let hoveredWindow else { return }
            delegate?.captureOverlay(self, didSelectWindow: hoveredWindow.id)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .window = mode else { return }
        updateHoveredWindow(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard case .window = mode else { return }
        hoveredWindow = nil
        needsDisplay = true
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

    private func updateHoveredWindow(with event: NSEvent) {
        guard case let .window(candidates, _) = mode else { return }
        let localPoint = clipped(convert(event.locationInWindow, from: nil))
        let globalPoint = CaptureGeometry.globalPoint(
            fromLocalPoint: localPoint,
            displayBounds: displayBounds
        )
        let next = CaptureGeometry.topmostWindow(at: globalPoint, candidates: candidates)
        if next?.id != hoveredWindow?.id {
            hoveredWindow = next
            needsDisplay = true
        }
    }

    private func punchOut(_ rect: CGRect) {
        NSColor.clear.setFill()
        rect.fill(using: .copy)
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.96).setStroke()
        border.lineWidth = 1.5
        border.stroke()

        let accent: NSColor = switch mode {
        case .region(.recording), .window(_, .recording): .systemRed
        case .region(.screenshot), .window(_, .screenshot): .systemCyan
        }
        accent.withAlphaComponent(0.76).setStroke()
        let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
        glow.lineWidth = 1
        glow.stroke()
    }

    private func drawGuidance(_ text: String) {
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

    private func drawWindowPill(
        for candidate: WindowSelectionCandidate,
        selection: CGRect
    ) {
        let rawText = candidate.title == candidate.applicationName
            ? candidate.applicationName
            : "\(candidate.applicationName)  ·  \(candidate.title)"
        let text = rawText.count > 54 ? String(rawText.prefix(53)) + "…" : rawText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = min(textSize.width + 22, max(bounds.width - 20, 80))
        let height = textSize.height + 11
        let desiredY = selection.maxY + 9
        let y = desiredY + height <= bounds.maxY
            ? desiredY
            : max(bounds.minY + 6, selection.minY - height - 9)
        let x = min(
            max(selection.midX - width / 2, bounds.minX + 6),
            bounds.maxX - width - 6
        )
        let frame = CGRect(x: x, y: y, width: width, height: height)

        let pill = NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.76).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        text.draw(
            at: CGPoint(x: frame.minX + 11, y: frame.minY + 5.5),
            withAttributes: attributes
        )
    }
}
