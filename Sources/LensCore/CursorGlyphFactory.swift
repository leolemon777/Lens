import CoreGraphics

/// Shared cursor bitmaps for live overlay and final render. Both pipelines
/// must draw the same pixels for a given appearance so a 9:16 preview cannot
/// diverge from the exported frame.
public enum CursorGlyphFactory {
    public enum Kind: String, CaseIterable, Sendable {
        case highContrast
        case minimalDot
        case magicWand
        case laser
        case pixelHand
        case highlighterPencil
        case crosshairHUD
        case rocket
    }

    public static func image(_ kind: Kind) -> CGImage? {
        switch kind {
        case .highContrast: highContrast()
        case .minimalDot: minimalDot()
        case .magicWand: magicWand()
        case .laser: laser()
        case .pixelHand: pixelHand()
        case .highlighterPencil: highlighterPencil()
        case .crosshairHUD: crosshairHUD()
        case .rocket: rocket()
        }
    }

    public static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func white(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(gray: 1, alpha: alpha)
    }

    private static func black(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(gray: 0, alpha: alpha)
    }

    private static func srgb(
        _ r: CGFloat,
        _ g: CGFloat,
        _ b: CGFloat,
        _ a: CGFloat = 1
    ) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func highContrast() -> CGImage? {
        guard let context = context(width: 40, height: 48) else { return nil }
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
        context.setFillColor(white())
        context.setStrokeColor(black(0.94))
        context.setLineWidth(4)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return context.makeImage()
    }

    private static func minimalDot() -> CGImage? {
        guard let context = context(width: 48, height: 48) else { return nil }
        context.setFillColor(white())
        context.fillEllipse(in: CGRect(x: 4, y: 4, width: 40, height: 40))
        return context.makeImage()
    }

    private static func magicWand() -> CGImage? {
        let size = 64
        guard let context = context(width: size, height: size) else { return nil }
        let staffPath = CGMutablePath()
        staffPath.move(to: CGPoint(x: 52, y: 12))
        staffPath.addLine(to: CGPoint(x: 24, y: 40))
        context.addPath(staffPath)
        context.setStrokeColor(srgb(0.18, 0.18, 0.22, 0.95))
        context.setLineWidth(5)
        context.setLineCap(.round)
        context.strokePath()

        context.addPath(staffPath)
        context.setStrokeColor(srgb(0.95, 0.85, 0.35))
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.strokePath()

        let cx: CGFloat = 18
        let cy: CGFloat = 46
        let starPath = CGMutablePath()
        let rOuter: CGFloat = 14
        let rInner: CGFloat = 3.5
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4.0
            let r = (i % 2 == 0) ? rOuter : rInner
            let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 {
                starPath.move(to: pt)
            } else {
                starPath.addLine(to: pt)
            }
        }
        starPath.closeSubpath()
        context.addPath(starPath)
        context.setFillColor(srgb(1.0, 0.92, 0.45))
        context.setStrokeColor(white())
        context.setLineWidth(1.5)
        context.drawPath(using: .fillStroke)

        context.setFillColor(white(0.9))
        context.fillEllipse(in: CGRect(x: 31, y: 45, width: 6, height: 6))
        return context.makeImage()
    }

    private static func laser() -> CGImage? {
        guard let context = context(width: 48, height: 48) else { return nil }
        let center = CGPoint(x: 24, y: 24)
        context.setFillColor(srgb(1.0, 0.15, 0.20, 0.35))
        context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
        context.setFillColor(srgb(1.0, 0.10, 0.15, 0.85))
        context.fillEllipse(in: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
        context.setFillColor(white())
        context.fillEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        return context.makeImage()
    }

    private static func pixelHand() -> CGImage? {
        guard let context = context(width: 48, height: 48) else { return nil }
        let block: CGFloat = 3
        let grid: [[Int]] = [
            [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 2, 2, 1, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 2, 2, 1, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 2, 2, 1, 0, 0, 0, 0, 0],
            [0, 0, 0, 1, 2, 2, 1, 0, 1, 1, 0, 0],
            [0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 0],
            [0, 1, 2, 2, 1, 2, 2, 1, 2, 2, 1, 0],
            [1, 2, 2, 2, 1, 2, 2, 2, 2, 2, 1, 0],
            [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
            [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
            [0, 0, 1, 2, 2, 2, 2, 2, 2, 1, 0, 0],
            [0, 0, 0, 1, 2, 2, 2, 2, 1, 0, 0, 0],
            [0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0]
        ]
        let originX = 3
        let originY = 2
        for (rowIndex, row) in grid.reversed().enumerated() {
            for (colIndex, val) in row.enumerated() {
                guard val != 0 else { continue }
                let rect = CGRect(
                    x: CGFloat(colIndex + originX) * block,
                    y: CGFloat(rowIndex + originY) * block,
                    width: block,
                    height: block
                )
                context.setFillColor(val == 1 ? black() : white())
                context.fill(rect)
            }
        }
        return context.makeImage()
    }

    private static func highlighterPencil() -> CGImage? {
        guard let context = context(width: 56, height: 56) else { return nil }
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: 18, y: 38))
        bodyPath.addLine(to: CGPoint(x: 44, y: 12))
        context.addPath(bodyPath)
        context.setStrokeColor(srgb(1.0, 0.88, 0.20))
        context.setLineWidth(8)
        context.setLineCap(.square)
        context.strokePath()

        let woodPath = CGMutablePath()
        woodPath.move(to: CGPoint(x: 14, y: 42))
        woodPath.addLine(to: CGPoint(x: 18, y: 38))
        context.addPath(woodPath)
        context.setStrokeColor(srgb(0.85, 0.70, 0.50))
        context.setLineWidth(6)
        context.strokePath()

        let tipPath = CGMutablePath()
        tipPath.move(to: CGPoint(x: 10, y: 46))
        tipPath.addLine(to: CGPoint(x: 14, y: 42))
        context.addPath(tipPath)
        context.setStrokeColor(srgb(0.15, 0.15, 0.18))
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.strokePath()

        context.setFillColor(srgb(1.0, 0.95, 0.2, 0.55))
        context.fillEllipse(in: CGRect(x: 6, y: 42, width: 8, height: 8))
        return context.makeImage()
    }

    private static func crosshairHUD() -> CGImage? {
        guard let context = context(width: 48, height: 48) else { return nil }
        let center = CGPoint(x: 24, y: 24)
        context.setStrokeColor(srgb(0.20, 0.85, 1.0, 0.95))
        context.setLineWidth(1.8)
        context.strokeEllipse(in: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))

        let tickDist: CGFloat = 16
        let tickGap: CGFloat = 7
        let lines: [(CGPoint, CGPoint)] = [
            (CGPoint(x: center.x - tickDist, y: center.y), CGPoint(x: center.x - tickGap, y: center.y)),
            (CGPoint(x: center.x + tickGap, y: center.y), CGPoint(x: center.x + tickDist, y: center.y)),
            (CGPoint(x: center.x, y: center.y - tickDist), CGPoint(x: center.x, y: center.y - tickGap)),
            (CGPoint(x: center.x, y: center.y + tickGap), CGPoint(x: center.x, y: center.y + tickDist))
        ]
        context.setLineWidth(2)
        context.setLineCap(.round)
        for (p1, p2) in lines {
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
        context.setFillColor(white())
        context.fillEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        return context.makeImage()
    }

    private static func rocket() -> CGImage? {
        guard let context = context(width: 56, height: 56) else { return nil }
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: 14, y: 42))
        bodyPath.addQuadCurve(to: CGPoint(x: 35, y: 26), control: CGPoint(x: 28, y: 40))
        bodyPath.addLine(to: CGPoint(x: 26, y: 17))
        bodyPath.addQuadCurve(to: CGPoint(x: 14, y: 42), control: CGPoint(x: 16, y: 28))
        bodyPath.closeSubpath()
        context.addPath(bodyPath)
        context.setFillColor(white())
        context.setStrokeColor(srgb(0.15, 0.18, 0.24, 0.95))
        context.setLineWidth(2)
        context.drawPath(using: .fillStroke)

        context.setFillColor(srgb(0.35, 0.75, 1.0))
        context.fillEllipse(in: CGRect(x: 20, y: 28, width: 6, height: 6))

        let flamePath = CGMutablePath()
        flamePath.move(to: CGPoint(x: 28, y: 23))
        flamePath.addLine(to: CGPoint(x: 44, y: 8))
        flamePath.addLine(to: CGPoint(x: 33, y: 18))
        flamePath.closeSubpath()
        context.addPath(flamePath)
        context.setFillColor(srgb(1.0, 0.32, 0.25))
        context.fillPath()
        return context.makeImage()
    }
}
