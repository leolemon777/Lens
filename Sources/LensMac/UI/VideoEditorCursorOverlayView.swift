import AppKit
import QuartzCore
import LensCore

private struct VideoEditorCursorAsset {
    let image: CGImage
    /// Normalized from the image's top-left corner.
    let hotSpot: CGPoint
    let relativeWidth: CGFloat
}

/// A lightweight, renderer-parity overlay used while the editor is playing the
/// raw source. Cursor and click effects are normally burned into `auto.mp4`; the
/// raw path needs this layer so changing an inspector control never makes the
/// pointer disappear while the camera continues to move.
@MainActor
final class VideoEditorCursorOverlayNSView: NSView {
    private var cursor: AutoEditPlan.Cursor?
    private var interaction: AutoEditPlan.Interaction?
    private var systemAssets: [PointerCursorShape: VideoEditorCursorAsset] = [:]
    private var highContrastAsset: VideoEditorCursorAsset?
    private var minimalDotAsset: VideoEditorCursorAsset?

    private let haloLayer = CAShapeLayer()
    private let dragLayer = CAShapeLayer()
    private let cursorLayer = CALayer()
    /// Laser-pointer ring for `.ring`; a soft glow halo for `.glowDot`.
    private let styleOverlayLayer = CAShapeLayer()
    private let trailLayers = (0..<4).map { _ in CALayer() }
    private let clickLayers = (0..<4).map { _ in CAShapeLayer() }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)

        haloLayer.isHidden = true
        haloLayer.fillColor = NSColor.clear.cgColor
        dragLayer.isHidden = true
        dragLayer.fillColor = NSColor.clear.cgColor
        dragLayer.lineDashPattern = [4, 3]

        for item in trailLayers {
            item.isHidden = true
            item.contentsGravity = .resizeAspect
            item.shadowColor = NSColor.black.cgColor
            item.shadowOpacity = 0.45
            item.shadowRadius = 1.5
            layer?.addSublayer(item)
        }
        layer?.addSublayer(haloLayer)
        for item in clickLayers {
            item.isHidden = true
            item.fillColor = NSColor.clear.cgColor
            item.lineCap = .round
            item.shadowRadius = 4
            layer?.addSublayer(item)
        }
        layer?.addSublayer(dragLayer)
        styleOverlayLayer.isHidden = true
        styleOverlayLayer.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(styleOverlayLayer)
        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.shadowColor = NSColor.black.cgColor
        cursorLayer.shadowOpacity = 0.72
        cursorLayer.shadowRadius = 2.2
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(cursorLayer)

        buildAssets()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        cursor: AutoEditPlan.Cursor?,
        interaction: AutoEditPlan.Interaction?
    ) {
        self.cursor = cursor
        self.interaction = interaction
        if cursor?.isEnabled == false || cursor == nil {
            hideCursorVisuals()
        }
        if interaction?.showsClickPulse != true {
            clickLayers.forEach { $0.isHidden = true }
        }
    }

    func update(
        sourceTime: Double,
        cameraState requestedCameraState: CameraFrameState,
        sourcePixelWidth requestedSourcePixelWidth: CGFloat? = nil
    ) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let cameraState = clampedCameraState(requestedCameraState)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        updateClickLayers(at: sourceTime, cameraState: cameraState)
        guard let cursor,
              cursor.isEnabled != false,
              let position = EffectTimeline.cursorPosition(
                  at: sourceTime,
                  keyframes: cursor.keyframes,
                  smoothing: cursor.smoothing,
                  smoothingWindowMilliseconds: cursor.smoothingWindowMilliseconds
              ) else {
            hideCursorVisuals()
            return
        }

        let opacity = cursorOpacity(at: sourceTime, cursor: cursor)
        guard opacity > 0.001 else {
            hideCursorVisuals()
            return
        }
        let point = outputPoint(position, cameraState: cameraState)
        let asset = resolvedAsset(at: sourceTime, cursor: cursor)
        let sourcePixelWidth = max(
            requestedSourcePixelWidth?.isFinite == true
                ? requestedSourcePixelWidth ?? bounds.width
                : bounds.width,
            1
        )
        // Match AutoPreviewRenderer's source-pixel rule exactly so completing a
        // background render cannot make a customized cursor suddenly shrink or
        // look like the original system capture.
        let baseWidth = AutoPreviewRenderer.baseCursorWidth(
            sourcePixelWidth: sourcePixelWidth
        )
            / sourcePixelWidth * bounds.width
        let width = baseWidth * CGFloat(cursor.scale) * asset.relativeWidth
        let height = width * CGFloat(asset.image.height) / max(CGFloat(asset.image.width), 1)

        cursorLayer.isHidden = false
        cursorLayer.opacity = Float(opacity)
        cursorLayer.contents = asset.image
        cursorLayer.backgroundColor = nil
        cursorLayer.cornerRadius = 0
        cursorLayer.borderWidth = 0
        cursorLayer.frame = CGRect(
            x: point.x - width * asset.hotSpot.x,
            y: point.y - height * asset.hotSpot.y,
            width: width,
            height: height
        )
        if cursor.appearance == .minimalDot {
            cursorLayer.contents = nil
            cursorLayer.backgroundColor = color(
                hex: cursor.accentColorHex,
                fallback: .systemCyan
            ).cgColor
            cursorLayer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
            cursorLayer.borderWidth = max(width * 0.08, 1)
            cursorLayer.cornerRadius = min(width, height) / 2
        }

        updateStyleOverlay(
            cursor: cursor,
            at: point,
            cursorWidth: width,
            opacity: opacity
        )

        let isDragging = EffectTimeline.cursorKind(
            at: sourceTime,
            keyframes: cursor.keyframes
        ) == .dragged
        updateMotionLayers(
            at: sourceTime,
            cursor: cursor,
            currentPosition: position,
            currentPoint: point,
            currentAsset: asset,
            cursorSize: CGSize(width: width, height: height),
            opacity: opacity,
            cameraState: cameraState,
            isDragging: isDragging
        )
    }

    /// Mirrors AutoPreviewRenderer's procedural ring/glow overlays so picking
    /// a style is visible in the live preview without a re-render.
    private func updateStyleOverlay(
        cursor: AutoEditPlan.Cursor,
        at point: CGPoint,
        cursorWidth: CGFloat,
        opacity: Double
    ) {
        let accent = color(hex: cursor.accentColorHex, fallback: .systemCyan)
        switch cursor.appearance {
        case .ring:
            let radius = max(cursorWidth * 0.62, 6)
            styleOverlayLayer.isHidden = false
            styleOverlayLayer.opacity = Float(opacity)
            styleOverlayLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            styleOverlayLayer.fillColor = accent.withAlphaComponent(0.10).cgColor
            styleOverlayLayer.strokeColor = accent.withAlphaComponent(0.95).cgColor
            styleOverlayLayer.lineWidth = max(2, cursorWidth * 0.085)
            styleOverlayLayer.shadowColor = accent.cgColor
            styleOverlayLayer.shadowOpacity = 0.4
            styleOverlayLayer.shadowRadius = radius * 0.22
        case .glowDot:
            let radius = max(cursorWidth * 0.34, 5)
            styleOverlayLayer.isHidden = false
            styleOverlayLayer.opacity = Float(opacity)
            styleOverlayLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            styleOverlayLayer.fillColor = accent.withAlphaComponent(0.96).cgColor
            styleOverlayLayer.strokeColor = NSColor.clear.cgColor
            styleOverlayLayer.lineWidth = 0
            styleOverlayLayer.shadowColor = accent.cgColor
            styleOverlayLayer.shadowOpacity = 0.55
            styleOverlayLayer.shadowRadius = radius * 1.1
        case .recorded, .macOS, .highContrast, .minimalDot:
            styleOverlayLayer.isHidden = true
        }
    }

    private func updateMotionLayers(
        at sourceTime: Double,
        cursor: AutoEditPlan.Cursor,
        currentPosition: LensPoint,
        currentPoint: CGPoint,
        currentAsset: VideoEditorCursorAsset,
        cursorSize: CGSize,
        opacity: Double,
        cameraState: CameraFrameState,
        isDragging: Bool
    ) {
        let accent = color(hex: cursor.accentColorHex, fallback: .systemCyan)
        let strength = CGFloat(cursor.motionEffectStrength) * opacity
        haloLayer.isHidden = cursor.motionEffect == .none && !isDragging
        if !haloLayer.isHidden {
            let multiplier: CGFloat = switch cursor.motionEffect {
            case .spotlight: 3.0
            case .halo, .trail, .none: isDragging ? 1.35 : 0.95
            }
            let radius = max(cursorSize.width * multiplier, 12)
            haloLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: currentPoint.x - radius,
                    y: currentPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            haloLayer.fillColor = accent.withAlphaComponent(
                cursor.motionEffect == .spotlight
                    ? 0.13 * strength
                    : 0.20 * strength
            ).cgColor
            haloLayer.shadowColor = accent.cgColor
            haloLayer.shadowOpacity = Float(0.28 * strength)
            haloLayer.shadowRadius = radius * 0.35
        }

        dragLayer.isHidden = !isDragging
        if isDragging {
            let radius = max(cursorSize.width * 0.72, 10)
            dragLayer.path = CGPath(
                ellipseIn: CGRect(
                    x: currentPoint.x - radius,
                    y: currentPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            dragLayer.strokeColor = accent.withAlphaComponent(0.92).cgColor
            dragLayer.lineWidth = max(2, cursorSize.width * 0.075)
            dragLayer.shadowColor = accent.cgColor
            dragLayer.shadowOpacity = 0.55
            dragLayer.shadowRadius = 4
        }

        let showsTrail = cursor.motionEffect == .trail || isDragging
        let samples: [(Double, Float)] = isDragging
            ? [(0.035, 0.28), (0.075, 0.19), (0.12, 0.12), (0.17, 0.07)]
            : [(0.025, 0.25), (0.055, 0.17), (0.09, 0.10), (0.13, 0.05)]
        for (index, layer) in trailLayers.enumerated() {
            guard showsTrail,
                  let previous = EffectTimeline.cursorPosition(
                      at: max(sourceTime - samples[index].0, 0),
                      keyframes: cursor.keyframes,
                      smoothing: cursor.smoothing,
                      smoothingWindowMilliseconds: cursor.smoothingWindowMilliseconds
                  ),
                  hypot(
                      previous.x - currentPosition.x,
                      previous.y - currentPosition.y
                  ) > 0.0015 else {
                layer.isHidden = true
                continue
            }
            let previousPoint = outputPoint(previous, cameraState: cameraState)
            layer.isHidden = false
            layer.contents = currentAsset.image
            layer.opacity = samples[index].1 * Float(max(strength, isDragging ? 0.72 : 0))
            layer.frame = CGRect(
                x: previousPoint.x - cursorSize.width * currentAsset.hotSpot.x,
                y: previousPoint.y - cursorSize.height * currentAsset.hotSpot.y,
                width: cursorSize.width,
                height: cursorSize.height
            )
        }
    }

    private func updateClickLayers(
        at sourceTime: Double,
        cameraState: CameraFrameState
    ) {
        guard let interaction, interaction.showsClickPulse else {
            clickLayers.forEach { $0.isHidden = true }
            return
        }
        let active = interaction.clickPulses.reversed().compactMap { pulse
            -> (AutoEditPlan.ClickPulse, Double, Double)? in
            let duration = interaction.clickPulseDuration ?? pulse.duration
            let elapsed = sourceTime - pulse.time
            guard elapsed >= 0, elapsed <= duration else { return nil }
            return (pulse, elapsed, duration)
        }.prefix(clickLayers.count)
        let accent = color(hex: interaction.clickPulseColorHex, fallback: .systemOrange)

        for (index, layer) in clickLayers.enumerated() {
            guard index < active.count else {
                layer.isHidden = true
                continue
            }
            let item = active[active.index(active.startIndex, offsetBy: index)]
            let progress = min(max(item.1 / max(item.2, 0.05), 0), 1)
            let eased = progress * progress * (3 - 2 * progress)
            let opacity = pow(1 - progress, 0.68) * interaction.clickEffectStrength
            let point = outputPoint(item.0.position, cameraState: cameraState)
            let scale = CGFloat(interaction.clickPulseScale)
            let base = min(max(bounds.width * 0.018, 10), 22)
            let radius: CGFloat
            switch interaction.clickEffect {
            case .ripple:
                radius = base * scale * CGFloat(0.58 + 1.35 * eased)
                layer.fillColor = NSColor.clear.cgColor
                layer.strokeColor = accent.withAlphaComponent(opacity).cgColor
            case .pulse:
                let arc = sin(Double.pi * min(progress / 0.78, 1))
                radius = base * scale * CGFloat(0.72 + 0.62 * arc)
                layer.fillColor = accent.withAlphaComponent(0.18 * opacity).cgColor
                layer.strokeColor = accent.withAlphaComponent(0.86 * opacity).cgColor
            case .spotlight:
                radius = base * scale * CGFloat(1.75 + 0.75 * eased)
                layer.fillColor = accent.withAlphaComponent(0.14 * opacity).cgColor
                layer.strokeColor = accent.withAlphaComponent(0.46 * opacity).cgColor
            }
            layer.isHidden = false
            layer.path = CGPath(
                ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
            layer.lineWidth = max(2, base * 0.16)
            layer.shadowColor = accent.cgColor
            layer.shadowOpacity = Float(0.34 * opacity)
        }
    }

    private func outputPoint(
        _ source: LensPoint,
        cameraState: CameraFrameState
    ) -> CGPoint {
        let scale = max(cameraState.scale, 1)
        let half = 0.5 / scale
        return CGPoint(
            x: (source.x - (cameraState.center.x - half)) * scale * bounds.width,
            y: (source.y - (cameraState.center.y - half)) * scale * bounds.height
        )
    }

    private func clampedCameraState(_ state: CameraFrameState) -> CameraFrameState {
        let scale = max(state.scale.isFinite ? state.scale : 1, 1)
        let half = 0.5 / scale
        return CameraFrameState(
            scale: scale,
            center: LensPoint(
                x: min(max(state.center.x, half), 1 - half),
                y: min(max(state.center.y, half), 1 - half)
            )
        )
    }

    private func cursorOpacity(
        at sourceTime: Double,
        cursor: AutoEditPlan.Cursor
    ) -> Double {
        guard cursor.hidesWhenIdle,
              let activity = EffectTimeline.lastCursorActivity(
                  at: sourceTime,
                  keyframes: cursor.keyframes
              ) else { return 1 }
        let elapsed = max(sourceTime - activity - 1.35, 0)
        return 1 - min(elapsed / 0.35, 1)
    }

    private func resolvedAsset(
        at sourceTime: Double,
        cursor: AutoEditPlan.Cursor
    ) -> VideoEditorCursorAsset {
        switch cursor.appearance {
        case .macOS:
            return systemAssets[.arrow] ?? fallbackAsset()
        case .highContrast:
            return highContrastAsset ?? fallbackAsset()
        case .minimalDot:
            return minimalDotAsset ?? fallbackAsset()
        case .ring, .glowDot:
            // The live editor approximates the procedural final-render
            // overlays with the closest bitmap glyph.
            return minimalDotAsset ?? fallbackAsset()
        case .recorded:
            let shape = cursor.shapeKeyframes.last { $0.time <= sourceTime }?.shape
                ?? .arrow
            return systemAssets[shape] ?? systemAssets[.arrow] ?? fallbackAsset()
        }
    }

    private func hideCursorVisuals() {
        cursorLayer.isHidden = true
        haloLayer.isHidden = true
        dragLayer.isHidden = true
        styleOverlayLayer.isHidden = true
        trailLayers.forEach { $0.isHidden = true }
    }

    private func buildAssets() {
        let cursorMap: [(PointerCursorShape, NSCursor)] = [
            (.arrow, .arrow),
            (.pointingHand, .pointingHand),
            (.iBeam, .iBeam),
            (.verticalIBeam, .iBeamCursorForVerticalLayout),
            (.crosshair, .crosshair),
            (.openHand, .openHand),
            (.closedHand, .closedHand),
            (.horizontalResize, .columnResize),
            (.verticalResize, .rowResize),
            (.operationNotAllowed, .operationNotAllowed),
            (.dragCopy, .dragCopy),
            (.dragLink, .dragLink),
            (.contextualMenu, .contextualMenu),
            (.disappearingItem, .disappearingItem)
        ]
        let arrowWidth = max(NSCursor.arrow.image.size.width, 1)
        for (shape, value) in cursorMap {
            guard let image = cgImage(from: value.image) else { continue }
            let width = max(value.image.size.width, 1)
            let height = max(value.image.size.height, 1)
            systemAssets[shape] = VideoEditorCursorAsset(
                image: image,
                hotSpot: CGPoint(
                    x: min(max(value.hotSpot.x / width, 0), 1),
                    y: min(max(value.hotSpot.y / height, 0), 1)
                ),
                relativeWidth: width / arrowWidth
            )
        }
        if let image = highContrastCursorImage() {
            highContrastAsset = VideoEditorCursorAsset(
                image: image,
                hotSpot: CGPoint(x: 0.10, y: 4.0 / 48.0),
                relativeWidth: 1
            )
        }
        if let image = dotCursorImage() {
            minimalDotAsset = VideoEditorCursorAsset(
                image: image,
                hotSpot: CGPoint(x: 0.5, y: 0.5),
                relativeWidth: 0.72
            )
        }
    }

    private func fallbackAsset() -> VideoEditorCursorAsset {
        if let asset = highContrastAsset { return asset }
        if let asset = systemAssets[.arrow] { return asset }
        let image = highContrastCursorImage() ?? dotCursorImage()!
        return VideoEditorCursorAsset(
            image: image,
            hotSpot: CGPoint(x: 0.1, y: 4.0 / 48.0),
            relativeWidth: 1
        )
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func highContrastCursorImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 40,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 40 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 44))
        path.addLine(to: CGPoint(x: 4, y: 8))
        path.addLine(to: CGPoint(x: 13, y: 17))
        path.addLine(to: CGPoint(x: 20, y: 3))
        path.addLine(to: CGPoint(x: 26, y: 6))
        path.addLine(to: CGPoint(x: 19, y: 20))
        path.addLine(to: CGPoint(x: 33, y: 20))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.94).cgColor)
        context.setLineWidth(4)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return context.makeImage()
    }

    private func dotCursorImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 48,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 48 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 4, y: 4, width: 40, height: 40))
        return context.makeImage()
    }

    private func color(hex: String, fallback: NSColor) -> NSColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard value.count == 6, let integer = UInt32(value, radix: 16) else {
            return fallback
        }
        return NSColor(
            red: CGFloat((integer >> 16) & 0xFF) / 255,
            green: CGFloat((integer >> 8) & 0xFF) / 255,
            blue: CGFloat(integer & 0xFF) / 255,
            alpha: 1
        )
    }
}
