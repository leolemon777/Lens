import AppKit
import QuartzCore
import LensCore

enum CaptureOverlayMode {
    case region(action: CaptureOverlayAction, snapRects: [CGRect])
    case window(candidates: [WindowSelectionCandidate], action: CaptureOverlayAction)
    case multiWindow(candidates: [WindowSelectionCandidate])
}

enum CaptureOverlayAction {
    case screenshot
    case conversationInbox
    case ocr
    case recording
    case scrollingCapture

    var regionGuidance: String {
        switch self {
        case .screenshot: "拖动选择区域  ·  方向键微调  ·  Option 暂停吸附  ·  Esc 取消"
        case .conversationInbox: "拖动选择区域  ·  松手后保存 PNG 并复制路径  ·  Esc 取消"
        case .ocr: "拖动选择要识别的文字  ·  松手后可改再复制  ·  Esc 取消"
        case .recording: "拖动选择录制区域  ·  方向键微调  ·  Option 暂停吸附  ·  Esc 取消"
        case .scrollingCapture: "拖动选择滚动内容区域  ·  方向键微调  ·  Option 暂停吸附"
        }
    }

    var windowGuidance: String {
        switch self {
        case .screenshot: "移动选择窗口  ·  单击截取  ·  Esc 取消"
        case .conversationInbox: "单击截取到对话文件夹  ·  Esc 取消"
        case .ocr: "选择要识别的窗口  ·  单击后可改再复制  ·  Esc 取消"
        case .recording: "移动选择窗口  ·  单击开始录制  ·  Esc 取消"
        case .scrollingCapture: "选择需要滚动拼接的内容区域"
        }
    }

    var diagnosticValue: String {
        switch self {
        case .screenshot: "screenshot"
        case .conversationInbox: "conversationInbox"
        case .ocr: "ocr"
        case .recording: "recording"
        case .scrollingCapture: "scrollingCapture"
        }
    }
}

struct CaptureOverlayDragPerformance: Equatable {
    let eventCount: Int
    let totalUpdateMilliseconds: Double
    let maximumUpdateMilliseconds: Double

    var averageUpdateMilliseconds: Double {
        guard eventCount > 0 else { return 0 }
        return totalUpdateMilliseconds / Double(eventCount)
    }
}

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidCancel(_ view: CaptureOverlayView)
    func captureOverlay(_ view: CaptureOverlayView, didSelect rect: CGRect, displayID: CGDirectDisplayID)
    func captureOverlay(_ view: CaptureOverlayView, didSelectWindow windowID: CGWindowID)
    func captureOverlay(_ view: CaptureOverlayView, didToggleWindow windowID: CGWindowID)
    func captureOverlayDidConfirmWindows(_ view: CaptureOverlayView)
    func captureOverlay(
        _ view: CaptureOverlayView,
        didMeasureRegionDrag performance: CaptureOverlayDragPerformance
    )
    /// Samples a small region for the magnifier. Runs on its own throttled,
    /// sequential loop — never from `mouseDragged`/`mouseMoved` — so a slow
    /// or failed sample can never affect drag responsiveness; `nil` on
    /// failure just leaves the magnifier showing its last good frame.
    func captureOverlay(
        _ view: CaptureOverlayView,
        didRequestMagnifierSample globalRect: CGRect
    ) async -> CGImage?
    func captureOverlay(_ view: CaptureOverlayView, didCopyMagnifierHex hex: String)
}

extension CaptureOverlayViewDelegate {
    func captureOverlay(
        _ view: CaptureOverlayView,
        didMeasureRegionDrag performance: CaptureOverlayDragPerformance
    ) {}
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?

    private let displayID: CGDirectDisplayID
    private let displayBounds: CGRect
    private let mode: CaptureOverlayMode
    private var regionSnapRects: [CGRect]
    private var regionSnapTargets = CaptureSnapTargets(x: [], y: [])
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var currentSnapResult: CaptureSnapResult?
    private var isClickAnchoredSelection = false
    private var didFineAdjustCurrentPoint = false
    private var hoveredWindow: WindowSelectionCandidate?
    private var selectedWindowIDs: Set<CGWindowID> = []
    private var mouseTrackingArea: NSTrackingArea?
    private let regionDimmingLayer = CAShapeLayer()
    private let regionAccentLayer = CAShapeLayer()
    private let regionBorderLayer = CAShapeLayer()
    private let regionGuideLayer = CAShapeLayer()
    private let regionGuidanceLabel = NSTextField(labelWithString: "")
    private let regionDimensionLabel = NSTextField(labelWithString: "")
    private var regionDragEventCount = 0
    private var regionDragTotalDuration = 0.0
    private var regionDragMaximumDuration = 0.0

    private static let magnifierSize: CGFloat = 96
    private static let magnifierSourcePoints: CGFloat = 9
    private static let magnifierMargin: CGFloat = 22
    private static let magnifierRefreshInterval: Duration = .milliseconds(80)

    private let magnifierContainerLayer = CALayer()
    private let magnifierImageLayer = CALayer()
    private let magnifierCrosshairLayer = CAShapeLayer()
    private let magnifierCaptionLayer = CALayer()
    private let magnifierHexLabel = NSTextField(labelWithString: "")
    private var isMagnifierSuppressed = false
    private var lastMagnifierHex: String?
    private var magnifierPoint: CGPoint?
    /// Only ever written on the main actor; read again by `deinit` purely to
    /// cancel it, which by definition holds the last reference and cannot
    /// race with the loop's own MainActor-isolated body.
    private nonisolated(unsafe) var magnifierTask: Task<Void, Never>?
    private let magnifierPasteboard: NSPasteboard

    init(
        frame: CGRect,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        mode: CaptureOverlayMode,
        magnifierPasteboard: NSPasteboard = .general
    ) {
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.mode = mode
        self.magnifierPasteboard = magnifierPasteboard
        if case let .region(_, globalSnapRects) = mode {
            regionSnapRects = globalSnapRects.compactMap {
                CaptureGeometry.localIntersection(of: $0, displayBounds: displayBounds)
            }
        } else {
            regionSnapRects = []
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        if case let .region(action, _) = mode {
            configureRegionLayerRendering(action: action)
            configureMagnifierRendering()
            refreshRegionSnapTargets()
            updateRegionLayerRendering()
            startMagnifierLoopIfNeeded()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        magnifierTask?.cancel()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRegionSelectionMode, bounds.contains(point) else {
            return super.hitTest(point)
        }
        // Guidance labels are informational. Keeping the overlay as the hit
        // target prevents a light first click over a label from being consumed.
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegionContentsScale()
    }

    override func layout() {
        super.layout()
        guard isRegionSelectionMode else { return }
        refreshRegionSnapTargets()
        updateRegionLayerRendering()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Region selection uses compositor-backed shape layers. Redrawing a full
        // transparent Retina window for every mouse event is visibly slower.
        guard !isRegionSelectionMode else { return }

        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        switch mode {
        case .region:
            return
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
        case let .multiWindow(candidates):
            for candidate in candidates where selectedWindowIDs.contains(candidate.id) {
                guard let localRect = CaptureGeometry.localIntersection(
                    of: candidate.globalFrame,
                    displayBounds: displayBounds
                ) else { continue }
                punchOut(localRect)
                drawSelectionBorder(localRect)
            }
            if let hoveredWindow,
               let localRect = CaptureGeometry.localIntersection(
                of: hoveredWindow.globalFrame,
                displayBounds: displayBounds
               ) {
                punchOut(localRect)
                drawSelectionBorder(localRect)
                drawWindowPill(for: hoveredWindow, selection: localRect)
            }
            let guidance = selectedWindowIDs.isEmpty
                ? "单击选择多个窗口  ·  Return 截取  ·  Esc 取消"
                : "已选择 \(selectedWindowIDs.count) 个窗口  ·  Return 截取  ·  再次单击取消"
            drawGuidance(guidance)
        }
    }

    override func resetCursorRects() {
        switch mode {
        case .region:
            addCursorRect(bounds, cursor: .crosshair)
        case .window, .multiWindow:
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
        let result = regionPoint(for: point, event: event)
        if isClickAnchoredSelection {
            currentPoint = result.point
            currentSnapResult = result
            didFineAdjustCurrentPoint = false
            updateRegionLayerRendering()
            return
        }
        startPoint = result.point
        currentPoint = result.point
        currentSnapResult = result
        didFineAdjustCurrentPoint = false
        resetRegionDragPerformance()
        updateRegionLayerRendering()
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .region = mode else { return }
        let updateStartedAt = CACurrentMediaTime()
        defer {
            recordRegionDragUpdate(startedAt: updateStartedAt)
        }
        let result = regionPoint(
            for: clipped(convert(event.locationInWindow, from: nil)),
            event: event
        )
        let changed = currentPoint != result.point
            || currentSnapResult != result
            || didFineAdjustCurrentPoint
        currentPoint = result.point
        currentSnapResult = result
        didFineAdjustCurrentPoint = false
        // Cheap position-only update; the magnifier's own zoomed content
        // refreshes on its independent throttled loop, never here, so this
        // can never be the thing that pushes drag-update timing over budget.
        updateMagnifierPoint(result.point)
        if changed {
            updateRegionLayerRendering()
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            if !didFineAdjustCurrentPoint {
                let result = regionPoint(
                    for: clipped(convert(event.locationInWindow, from: nil)),
                    event: event
                )
                currentPoint = result.point
                currentSnapResult = result
            }
            reportRegionDragPerformance()
            guard let selection, selection.width >= 3, selection.height >= 3 else {
                if !isClickAnchoredSelection {
                    isClickAnchoredSelection = true
                    updateRegionLayerRendering()
                    return
                }
                resetRegionSelection()
                updateRegionLayerRendering()
                return
            }
            delegate?.captureOverlay(self, didSelect: selection, displayID: displayID)
        case .window:
            updateHoveredWindow(with: event)
            guard let hoveredWindow else { return }
            delegate?.captureOverlay(self, didSelectWindow: hoveredWindow.id)
        case .multiWindow:
            updateHoveredWindow(with: event)
            guard let hoveredWindow else { return }
            delegate?.captureOverlay(self, didToggleWindow: hoveredWindow.id)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if case .region = mode {
            let point = clipped(convert(event.locationInWindow, from: nil))
            // Tracked independently of `currentPoint`/selection state so the
            // magnifier is visible the moment the pointer enters the overlay,
            // not only once a drag actually starts.
            updateMagnifierPoint(point)
            if isClickAnchoredSelection {
                let result = regionPoint(for: point, event: event)
                let changed = currentPoint != result.point || currentSnapResult != result
                currentPoint = result.point
                currentSnapResult = result
                didFineAdjustCurrentPoint = false
                if changed {
                    updateRegionLayerRendering()
                }
            }
            return
        }
        guard isWindowSelectionMode else { return }
        updateHoveredWindow(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if case .region = mode {
            magnifierPoint = nil
            updateMagnifierPosition()
        }
        guard isWindowSelectionMode else { return }
        hoveredWindow = nil
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if case .region = mode {
            let suppressed = event.modifierFlags.contains(.option)
            if suppressed != isMagnifierSuppressed {
                isMagnifierSuppressed = suppressed
                updateMagnifierPosition()
            }
        }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.captureOverlayDidCancel(self)
            return
        }
        if case .region = mode,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           let lastMagnifierHex {
            magnifierPasteboard.clearContents()
            magnifierPasteboard.setString(lastMagnifierHex, forType: .string)
            delegate?.captureOverlay(self, didCopyMagnifierHex: lastMagnifierHex)
            return
        }
        if case .region = mode,
           startPoint != nil,
           let currentPoint,
           let delta = regionFineAdjustment(for: event) {
            self.currentPoint = clipped(CGPoint(
                x: currentPoint.x + delta.x,
                y: currentPoint.y + delta.y
            ))
            currentSnapResult = nil
            didFineAdjustCurrentPoint = true
            updateRegionLayerRendering()
            return
        }
        if case .multiWindow = mode,
           !selectedWindowIDs.isEmpty,
           event.keyCode == 36 || event.keyCode == 76 {
            delegate?.captureOverlayDidConfirmWindows(self)
            return
        }
        super.keyDown(with: event)
    }

    func setSelectedWindowIDs(_ ids: Set<CGWindowID>) {
        guard case .multiWindow = mode else { return }
        selectedWindowIDs = ids
        needsDisplay = true
    }

    func setRegionSnapRects(_ globalRects: [CGRect]) {
        guard isRegionSelectionMode else { return }
        regionSnapRects = globalRects.compactMap {
            CaptureGeometry.localIntersection(of: $0, displayBounds: displayBounds)
        }
        refreshRegionSnapTargets()
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

    private func regionPoint(for point: CGPoint, event: NSEvent) -> CaptureSnapResult {
        guard case .region = mode,
              !event.modifierFlags.contains(.option) else {
            return CaptureSnapResult(point: clipped(point), snappedX: nil, snappedY: nil)
        }
        return CaptureGeometry.snappedPoint(
            point,
            to: regionSnapTargets,
            inside: bounds,
            threshold: 8
        )
    }

    private func regionFineAdjustment(for event: NSEvent) -> CGPoint? {
        let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        return switch event.keyCode {
        case 123: CGPoint(x: -amount, y: 0)
        case 124: CGPoint(x: amount, y: 0)
        case 125: CGPoint(x: 0, y: amount)
        case 126: CGPoint(x: 0, y: -amount)
        default: nil
        }
    }

    private func updateHoveredWindow(with event: NSEvent) {
        let candidates: [WindowSelectionCandidate]
        switch mode {
        case let .window(values, _), let .multiWindow(values):
            candidates = values
        case .region:
            return
        }
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

    private var isWindowSelectionMode: Bool {
        switch mode {
        case .window, .multiWindow: true
        case .region: false
        }
    }

    private var isRegionSelectionMode: Bool {
        if case .region = mode { return true }
        return false
    }

    private func configureRegionLayerRendering(action: CaptureOverlayAction) {
        guard let rootLayer = layer else { return }
        layerContentsRedrawPolicy = .never

        regionDimmingLayer.name = "capture-region-dimming"
        regionDimmingLayer.fillRule = .evenOdd
        regionDimmingLayer.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor

        regionAccentLayer.name = "capture-region-accent"
        regionAccentLayer.fillColor = nil
        regionAccentLayer.strokeColor = regionAccentColor(for: action)
            .withAlphaComponent(0.76).cgColor
        regionAccentLayer.lineWidth = 1

        regionBorderLayer.name = "capture-region-border"
        regionBorderLayer.fillColor = nil
        regionBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.96).cgColor
        regionBorderLayer.lineWidth = 1.5

        regionGuideLayer.name = "capture-region-guides"
        regionGuideLayer.fillColor = nil
        regionGuideLayer.strokeColor = LensGlassPalette.accentColor.withAlphaComponent(0.7).cgColor
        regionGuideLayer.lineWidth = 0.8
        regionGuideLayer.lineDashPattern = [4, 4]

        rootLayer.addSublayer(regionDimmingLayer)
        rootLayer.addSublayer(regionAccentLayer)
        rootLayer.addSublayer(regionBorderLayer)
        rootLayer.addSublayer(regionGuideLayer)

        configureRegionLabel(
            regionGuidanceLabel,
            font: .systemFont(ofSize: 13, weight: .semibold),
            backgroundAlpha: 0.38,
            borderAlpha: 0.16
        )
        regionGuidanceLabel.stringValue = action.regionGuidance
        addSubview(regionGuidanceLabel)

        configureRegionLabel(
            regionDimensionLabel,
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            backgroundAlpha: 0.72,
            borderAlpha: 0.24
        )
        regionDimensionLabel.isHidden = true
        addSubview(regionDimensionLabel)
        needsDisplay = false
    }

    private func configureRegionLabel(
        _ label: NSTextField,
        font: NSFont,
        backgroundAlpha: CGFloat,
        borderAlpha: CGFloat
    ) {
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(backgroundAlpha)
        label.focusRingType = .none
        label.wantsLayer = true
        label.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        label.layer?.borderWidth = 1
        label.layer?.masksToBounds = true
        label.layer?.zPosition = 10
    }

    private func refreshRegionSnapTargets() {
        regionSnapTargets = CaptureGeometry.snapTargets(
            for: regionSnapRects,
            inside: bounds
        )
    }

    private func resetRegionSelection() {
        startPoint = nil
        currentPoint = nil
        currentSnapResult = nil
        isClickAnchoredSelection = false
        didFineAdjustCurrentPoint = false
        resetRegionDragPerformance()
    }

    private func resetRegionDragPerformance() {
        regionDragEventCount = 0
        regionDragTotalDuration = 0
        regionDragMaximumDuration = 0
    }

    private func recordRegionDragUpdate(startedAt: CFTimeInterval) {
        let duration = max(0, (CACurrentMediaTime() - startedAt) * 1_000)
        regionDragEventCount += 1
        regionDragTotalDuration += duration
        regionDragMaximumDuration = max(regionDragMaximumDuration, duration)
    }

    private func reportRegionDragPerformance() {
        guard regionDragEventCount > 0 else { return }
        delegate?.captureOverlay(
            self,
            didMeasureRegionDrag: CaptureOverlayDragPerformance(
                eventCount: regionDragEventCount,
                totalUpdateMilliseconds: regionDragTotalDuration,
                maximumUpdateMilliseconds: regionDragMaximumDuration
            )
        )
        resetRegionDragPerformance()
    }

    private func updateRegionContentsScale() {
        guard isRegionSelectionMode else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for shapeLayer in [
            regionDimmingLayer,
            regionAccentLayer,
            regionBorderLayer,
            regionGuideLayer
        ] {
            shapeLayer.contentsScale = scale
        }
        regionGuidanceLabel.layer?.contentsScale = scale
        regionDimensionLabel.layer?.contentsScale = scale
    }

    private func updateRegionLayerRendering() {
        guard isRegionSelectionMode else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in [
            regionDimmingLayer,
            regionAccentLayer,
            regionBorderLayer,
            regionGuideLayer
        ] {
            shapeLayer.frame = bounds
        }

        let dimmingPath = CGMutablePath()
        dimmingPath.addRect(bounds)
        if let selection, selection.width > 0, selection.height > 0 {
            let radius = min(4, selection.width / 2, selection.height / 2)
            dimmingPath.addRoundedRect(
                in: selection,
                cornerWidth: radius,
                cornerHeight: radius
            )
        }
        regionDimmingLayer.path = dimmingPath

        if let selection {
            let radius = min(4, selection.width / 2, selection.height / 2)
            regionBorderLayer.path = CGPath(
                roundedRect: selection,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            let accentRect = selection.insetBy(dx: -1, dy: -1)
            regionAccentLayer.path = CGPath(
                roundedRect: accentRect,
                cornerWidth: radius + 1,
                cornerHeight: radius + 1,
                transform: nil
            )
            regionGuideLayer.path = regionGuidePath()
            regionGuidanceLabel.isHidden = true
            updateRegionDimensionLabel(for: selection)
        } else {
            regionBorderLayer.path = nil
            regionAccentLayer.path = nil
            regionGuideLayer.path = nil
            regionDimensionLabel.isHidden = true
            updateRegionGuidanceLabel()
        }
        CATransaction.commit()
    }

    private func regionGuidePath() -> CGPath? {
        guard let currentSnapResult else { return nil }
        let path = CGMutablePath()
        var hasGuide = false
        if let x = currentSnapResult.snappedX {
            path.move(to: CGPoint(x: x, y: bounds.minY))
            path.addLine(to: CGPoint(x: x, y: bounds.maxY))
            hasGuide = true
        }
        if let y = currentSnapResult.snappedY {
            path.move(to: CGPoint(x: bounds.minX, y: y))
            path.addLine(to: CGPoint(x: bounds.maxX, y: y))
            hasGuide = true
        }
        return hasGuide ? path : nil
    }

    private func updateRegionGuidanceLabel() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: regionGuidanceLabel.font as Any
        ]
        let size = regionGuidanceLabel.stringValue.size(withAttributes: attributes)
        let frame = CGRect(
            x: bounds.midX - size.width / 2 - 13,
            y: bounds.midY - size.height / 2 - 8,
            width: size.width + 26,
            height: size.height + 16
        ).integral
        regionGuidanceLabel.frame = frame
        regionGuidanceLabel.layer?.cornerRadius = frame.height / 2
        regionGuidanceLabel.isHidden = false
    }

    private func updateRegionDimensionLabel(for selection: CGRect) {
        let dimensions = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let text: String
        if isClickAnchoredSelection {
            text = selection.width >= 3 && selection.height >= 3
                ? "再轻点完成 · \(dimensions)"
                : "移动指针，再轻点完成"
        } else {
            text = dimensions
        }
        regionDimensionLabel.stringValue = text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: regionDimensionLabel.font as Any
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = textSize.width + 18
        let height = textSize.height + 10
        let desiredY = selection.maxY + 9
        let y = desiredY + height <= bounds.maxY
            ? desiredY
            : max(bounds.minY + 6, selection.minY - height - 9)
        let x = min(
            max(selection.midX - width / 2, bounds.minX + 6),
            bounds.maxX - width - 6
        )
        let frame = CGRect(x: x, y: y, width: width, height: height).integral
        regionDimensionLabel.frame = frame
        regionDimensionLabel.layer?.cornerRadius = frame.height / 2
        regionDimensionLabel.isHidden = false
    }

    private func regionAccentColor(for action: CaptureOverlayAction) -> NSColor {
        switch action {
        case .recording: LensGlassPalette.recordingColor
        case .screenshot, .conversationInbox, .ocr, .scrollingCapture: LensGlassPalette.accentColor
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
        case .region(.recording, _), .window(_, .recording):
            LensGlassPalette.recordingColor
        case .region(.screenshot, _), .window(_, .screenshot), .multiWindow,
             .region(.conversationInbox, _), .window(_, .conversationInbox),
             .region(.ocr, _), .window(_, .ocr),
             .region(.scrollingCapture, _), .window(_, .scrollingCapture):
            LensGlassPalette.accentColor
        }
        accent.withAlphaComponent(0.76).setStroke()
        let glow = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
        glow.lineWidth = 1
        glow.stroke()
    }

    private func drawSnapGuides() {
        guard let currentSnapResult else { return }
        LensGlassPalette.accentColor.withAlphaComponent(0.7).setStroke()
        if let x = currentSnapResult.snappedX {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x, y: bounds.minY))
            path.line(to: CGPoint(x: x, y: bounds.maxY))
            path.lineWidth = 0.8
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        }
        if let y = currentSnapResult.snappedY {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: bounds.minX, y: y))
            path.line(to: CGPoint(x: bounds.maxX, y: y))
            path.lineWidth = 0.8
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        }
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

    // MARK: - Magnifier

    private func configureMagnifierRendering() {
        guard let rootLayer = layer else { return }
        magnifierContainerLayer.name = "capture-magnifier-container"
        magnifierContainerLayer.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        magnifierContainerLayer.cornerRadius = LensGlassMetrics.tileCornerRadius
        magnifierContainerLayer.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        magnifierContainerLayer.borderWidth = 1
        magnifierContainerLayer.masksToBounds = true
        // A freshly created CALayer defaults to non-flipped geometry
        // regardless of the (flipped) view it's hosted in; without this,
        // the caption bar math below would land at the visual top instead
        // of the bottom.
        magnifierContainerLayer.isGeometryFlipped = true
        magnifierContainerLayer.isHidden = true
        magnifierContainerLayer.zPosition = 20

        magnifierImageLayer.name = "capture-magnifier-image"
        magnifierImageLayer.magnificationFilter = .nearest
        magnifierImageLayer.minificationFilter = .nearest
        magnifierImageLayer.contentsGravity = .resize
        magnifierContainerLayer.addSublayer(magnifierImageLayer)

        magnifierCrosshairLayer.name = "capture-magnifier-crosshair"
        magnifierCrosshairLayer.strokeColor = LensGlassPalette.accentColor.withAlphaComponent(0.92).cgColor
        magnifierCrosshairLayer.fillColor = nil
        magnifierCrosshairLayer.lineWidth = 1
        magnifierContainerLayer.addSublayer(magnifierCrosshairLayer)

        magnifierCaptionLayer.name = "capture-magnifier-caption"
        magnifierCaptionLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        magnifierContainerLayer.addSublayer(magnifierCaptionLayer)

        rootLayer.addSublayer(magnifierContainerLayer)

        configureRegionLabel(
            magnifierHexLabel,
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            backgroundAlpha: 0,
            borderAlpha: 0
        )
        magnifierHexLabel.alignment = .center
        magnifierHexLabel.layer?.zPosition = 21
        addSubview(magnifierHexLabel)
    }

    private func updateMagnifierPoint(_ point: CGPoint) {
        magnifierPoint = point
        updateMagnifierPosition()
    }

    /// Cheap, synchronous, and safe to call from the drag hot path: only
    /// arithmetic and layer property assignment, never capture I/O.
    private func updateMagnifierPosition() {
        guard let magnifierPoint, !isMagnifierSuppressed else {
            magnifierContainerLayer.isHidden = true
            return
        }
        let size = Self.magnifierSize
        let margin = Self.magnifierMargin
        var origin = CGPoint(x: magnifierPoint.x + margin, y: magnifierPoint.y + margin)
        let candidateFrame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        if let selection, selection.width > 0, selection.height > 0,
           candidateFrame.intersects(selection) {
            // Auto-avoid: flip to the opposite corner of the pointer so the
            // magnifier never sits on top of the selection it's helping to
            // draw.
            origin = CGPoint(x: magnifierPoint.x - margin - size, y: magnifierPoint.y - margin - size)
        }
        origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size))
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let captionHeight: CGFloat = 20

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifierContainerLayer.isHidden = false
        magnifierContainerLayer.frame = frame
        magnifierImageLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        magnifierCrosshairLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        magnifierCrosshairLayer.path = Self.crosshairPath(size: size)
        magnifierCaptionLayer.frame = CGRect(x: 0, y: size - captionHeight, width: size, height: captionHeight)
        CATransaction.commit()
        magnifierHexLabel.frame = CGRect(
            x: frame.minX,
            y: frame.maxY - captionHeight,
            width: size,
            height: captionHeight
        )
    }

    nonisolated private static func crosshairPath(size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let mid = size / 2
        let armLength: CGFloat = 5
        path.move(to: CGPoint(x: mid - armLength, y: mid))
        path.addLine(to: CGPoint(x: mid + armLength, y: mid))
        path.move(to: CGPoint(x: mid, y: mid - armLength))
        path.addLine(to: CGPoint(x: mid, y: mid + armLength))
        return path
    }

    private func startMagnifierLoopIfNeeded() {
        guard magnifierTask == nil else { return }
        magnifierTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshMagnifierSample()
                try? await Task.sleep(for: Self.magnifierRefreshInterval)
            }
        }
    }

    /// Drives one sampling cycle synchronously with the caller instead of
    /// waiting on the real throttled loop, so tests don't depend on timing.
    func refreshMagnifierSampleForTesting() async {
        await refreshMagnifierSample()
    }

    /// Runs sequentially on its own loop, fully independent of
    /// `mouseDragged`/`mouseMoved` — a slow or failed sample here can never
    /// delay the selection rectangle's own responsiveness.
    private func refreshMagnifierSample() async {
        guard !isMagnifierSuppressed, let magnifierPoint, let delegate else { return }
        let half = Self.magnifierSourcePoints / 2
        let localSampleRect = CGRect(
            x: magnifierPoint.x - half,
            y: magnifierPoint.y - half,
            width: Self.magnifierSourcePoints,
            height: Self.magnifierSourcePoints
        )
        let globalSampleRect = CaptureGeometry.globalRect(
            fromLocalRect: localSampleRect,
            displayBounds: displayBounds
        )
        guard let sample = await delegate.captureOverlay(
            self,
            didRequestMagnifierSample: globalSampleRect
        ) else { return }
        applyMagnifierSample(sample)
    }

    private func applyMagnifierSample(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifierImageLayer.contents = image
        CATransaction.commit()
        guard let hex = Self.centerPixelHex(of: image) else { return }
        lastMagnifierHex = hex
        if let magnifierPoint {
            let globalPoint = CaptureGeometry.globalPoint(
                fromLocalPoint: magnifierPoint,
                displayBounds: displayBounds
            )
            magnifierHexLabel.stringValue = "\(hex) · \(Int(globalPoint.x.rounded())), \(Int(globalPoint.y.rounded()))"
        } else {
            magnifierHexLabel.stringValue = hex
        }
    }

    /// Draws into a context whose pixel layout is fully known (rather than
    /// trusting the source image's own, possibly-BGRA `bitmapInfo`), so the
    /// extracted bytes are reliably R/G/B regardless of how the screen
    /// capture backend encoded them.
    nonisolated static func centerPixelHex(of image: CGImage) -> String? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        let centerX = width / 2
        let centerY = height / 2
        let offset = centerY * bytesPerRow + centerX * bytesPerPixel
        guard offset + 2 < buffer.count else { return nil }
        let sampled: (UInt8, UInt8, UInt8)? = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let base = rawBuffer.bindMemory(to: UInt8.self)
            return (base[offset], base[offset + 1], base[offset + 2])
        }
        guard let sampled else { return nil }
        return String(format: "#%02X%02X%02X", sampled.0, sampled.1, sampled.2)
    }
}
