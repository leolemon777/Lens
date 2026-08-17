import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ScreenTraceCore

enum ScreenshotAnnotationRendererError: LocalizedError {
    case sourceDimensionsMismatch
    case unableToRenderEffects
    case unableToCreateBitmap

    var errorDescription: String? {
        switch self {
        case .sourceDimensionsMismatch:
            "标注计划与原始截图尺寸不一致。"
        case .unableToRenderEffects:
            "无法渲染模糊或像素化效果。"
        case .unableToCreateBitmap:
            "无法创建标注后的截图。"
        }
    }
}

struct ScreenshotAnnotationRenderer: Sendable {
    // CIContext is designed for reuse and is thread-safe. Keeping one context
    // avoids rebuilding Core Image state for every Copy, Save, or Export.
    private static let sharedContext = CIContext(
        options: [.cacheIntermediates: false]
    )

    func render(source: CGImage, plan: ScreenshotEditPlan) throws -> CGImage {
        guard source.width == plan.sourceDimensions.width,
              source.height == plan.sourceDimensions.height else {
            throw ScreenshotAnnotationRendererError.sourceDimensionsMismatch
        }

        let effected = try renderRasterEffects(source: source, annotations: plan.annotations)
        let annotated = try renderVectorAnnotations(base: effected, annotations: plan.annotations)
        return try renderCanvas(base: annotated, plan: plan)
    }

    private func renderCanvas(base: CGImage, plan: ScreenshotEditPlan) throws -> CGImage {
        guard let rawStyle = plan.canvasStyle else { return base }
        let style = rawStyle.normalized
        let layout = ScreenshotCanvasPlanner.layout(
            sourceDimensions: plan.sourceDimensions,
            style: style
        )
        let width = layout.outputDimensions.width
        let height = layout.outputDimensions.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }

        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        switch style.backgroundKind {
        case .solid:
            context.setFillColor(cgColor(style.primaryColor))
            context.fill(canvasRect)
        case .gradient:
            let colors = [
                cgColor(style.primaryColor),
                cgColor(style.secondaryColor)
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: CGFloat(height)),
                    end: CGPoint(x: CGFloat(width), y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                context.setFillColor(cgColor(style.primaryColor))
                context.fill(canvasRect)
            }
        }

        let sourceFrame = layout.sourceFrame
        let imageRect = CGRect(
            x: sourceFrame.x,
            y: Double(height) - sourceFrame.y - sourceFrame.height,
            width: sourceFrame.width,
            height: sourceFrame.height
        )
        let shortestSide = CGFloat(min(base.width, base.height))
        let cornerRadius = min(
            CGFloat(style.cornerRadius) * shortestSide,
            min(imageRect.width, imageRect.height) / 2
        )
        let imagePath = CGPath(
            roundedRect: imageRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        if style.shadowOpacity > 0, style.shadowRadius > 0 {
            try drawShadow(
                path: imagePath,
                canvasRect: canvasRect,
                shortestSide: shortestSide,
                style: style,
                colorSpace: colorSpace,
                into: context
            )
        }

        context.saveGState()
        context.addPath(imagePath)
        context.clip()
        context.interpolationQuality = .high
        context.draw(base, in: imageRect)
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }
        return output
    }

    private func drawShadow(
        path: CGPath,
        canvasRect: CGRect,
        shortestSide: CGFloat,
        style: ScreenshotCanvasStyle,
        colorSpace: CGColorSpace,
        into destination: CGContext
    ) throws {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let shadowContext = CGContext(
            data: nil,
            width: Int(canvasRect.width),
            height: Int(canvasRect.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }

        shadowContext.setShadow(
            offset: CGSize(width: 0, height: -shortestSide * 0.018),
            blur: CGFloat(style.shadowRadius) * shortestSide,
            color: CGColor(gray: 0, alpha: CGFloat(style.shadowOpacity))
        )
        shadowContext.addPath(path)
        shadowContext.setFillColor(CGColor(gray: 1, alpha: 1))
        shadowContext.fillPath()

        // Keep only the shadow. The temporary white shape must not fill transparent
        // gaps in a composed multi-window screenshot.
        shadowContext.setShadow(offset: .zero, blur: 0, color: nil)
        shadowContext.setBlendMode(.clear)
        shadowContext.addPath(path)
        shadowContext.fillPath()

        guard let shadowImage = shadowContext.makeImage() else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }
        destination.draw(shadowImage, in: canvasRect)
    }

    private func renderRasterEffects(
        source: CGImage,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        var current = CIImage(cgImage: source)
        let extent = current.extent
        let shortestSide = min(extent.width, extent.height)

        for annotation in annotations where annotation.kind == .blur || annotation.kind == .pixelate {
            let region = ciRect(
                from: annotation.bounds,
                width: extent.width,
                height: extent.height
            ).intersection(extent)
            guard !region.isNull, region.width >= 1, region.height >= 1 else { continue }

            let processed: CIImage
            switch annotation.kind {
            case .blur:
                let radius = max(3, annotation.style.intensity * shortestSide)
                processed = current
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: extent)
            case .pixelate:
                let scale = max(5, annotation.style.intensity * shortestSide)
                processed = current.applyingFilter(
                    "CIPixellate",
                    parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputCenterKey: CIVector(x: region.midX, y: region.midY)
                    ]
                )
            default:
                continue
            }

            current = processed
                .cropped(to: region)
                .composited(over: current)
                .cropped(to: extent)
        }

        guard let output = Self.sharedContext.createCGImage(current, from: extent) else {
            throw ScreenshotAnnotationRendererError.unableToRenderEffects
        }
        return output
    }

    private func renderVectorAnnotations(
        base: CGImage,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        let width = base.width
        let height = base.height
        let colorSpace = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }

        let pixelBounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(base, in: pixelBounds)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let shortestSide = CGFloat(min(width, height))
        for annotation in annotations {
            let lineWidth = max(2, CGFloat(annotation.style.lineWidth) * shortestSide)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(cgColor(annotation.style.color))
            if let fill = annotation.style.fillColor {
                context.setFillColor(cgColor(fill))
            }

            let rect = topLeftRect(
                from: annotation.bounds,
                width: CGFloat(width),
                height: CGFloat(height)
            )
            let gradientEnd = annotation.style.gradientEndColor
            switch annotation.kind {
            case .rectangle:
                let path = CGPath(rect: rect, transform: nil)
                if annotation.style.fillColor != nil {
                    if let gradientEnd {
                        drawGradient(
                            path: path,
                            start: annotation.style.color.withAlpha(annotation.style.fillColor?.alpha ?? 0.10),
                            end: gradientEnd.withAlpha(annotation.style.fillColor?.alpha ?? 0.10),
                            in: context,
                            bounds: rect
                        )
                    } else {
                        context.fill(rect)
                    }
                }
                if let gradientEnd {
                    drawGradient(
                        path: path,
                        start: annotation.style.color,
                        end: gradientEnd,
                        in: context,
                        bounds: rect,
                        strokeWidth: lineWidth
                    )
                } else {
                    context.stroke(rect)
                }
            case .ellipse:
                let path = CGPath(ellipseIn: rect, transform: nil)
                if annotation.style.fillColor != nil {
                    if let gradientEnd {
                        drawGradient(
                            path: path,
                            start: annotation.style.color.withAlpha(annotation.style.fillColor?.alpha ?? 0.10),
                            end: gradientEnd.withAlpha(annotation.style.fillColor?.alpha ?? 0.10),
                            in: context,
                            bounds: rect
                        )
                    } else {
                        context.fillEllipse(in: rect)
                    }
                }
                if let gradientEnd {
                    drawGradient(
                        path: path,
                        start: annotation.style.color,
                        end: gradientEnd,
                        in: context,
                        bounds: rect,
                        strokeWidth: lineWidth
                    )
                } else {
                    context.strokeEllipse(in: rect)
                }
            case .arrow:
                if let gradientEnd {
                    drawGradient(
                        path: arrowPath(annotation, width: CGFloat(width), height: CGFloat(height), lineWidth: lineWidth),
                        start: annotation.style.color,
                        end: gradientEnd,
                        in: context,
                        bounds: rect,
                        strokeWidth: lineWidth
                    )
                } else {
                    drawArrow(annotation, in: context, width: CGFloat(width), height: CGFloat(height), lineWidth: lineWidth)
                }
            case .freehand:
                if let gradientEnd, let path = freehandPath(
                    annotation,
                    width: CGFloat(width),
                    height: CGFloat(height)
                ) {
                    drawGradient(
                        path: path,
                        start: annotation.style.color,
                        end: gradientEnd,
                        in: context,
                        bounds: rect,
                        strokeWidth: lineWidth
                    )
                } else {
                    drawFreehand(
                        annotation,
                        in: context,
                        width: CGFloat(width),
                        height: CGFloat(height)
                    )
                }
            case .highlight:
                context.setFillColor(cgColor(
                    annotation.style.fillColor
                        ?? TraceColor(
                            red: annotation.style.color.red,
                            green: annotation.style.color.green,
                            blue: annotation.style.color.blue,
                            alpha: 0.28
                        )
                ))
                let path = CGPath(
                    roundedRect: rect,
                    cornerWidth: max(2, rect.height * 0.12),
                    cornerHeight: max(2, rect.height * 0.12),
                    transform: nil
                )
                if let gradientEnd {
                    let alpha = annotation.style.fillColor?.alpha ?? 0.28
                    drawGradient(
                        path: path,
                        start: annotation.style.color.withAlpha(alpha),
                        end: gradientEnd.withAlpha(alpha),
                        in: context,
                        bounds: rect
                    )
                } else {
                    context.addPath(path)
                    context.fillPath()
                }
            case .step:
                drawStep(annotation, in: context, rect: rect)
            case .text:
                drawText(annotation, in: context, rect: rect, shortestSide: shortestSide)
            case .blur, .pixelate:
                break
            }
        }
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw ScreenshotAnnotationRendererError.unableToCreateBitmap
        }
        return output
    }

    private func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat
    ) {
        guard let path = freehandPath(annotation, width: width, height: height) else { return }
        context.addPath(path)
        context.strokePath()
    }

    private func freehandPath(
        _ annotation: ScreenshotAnnotation,
        width: CGFloat,
        height: CGFloat
    ) -> CGPath? {
        guard let points = annotation.points, let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: topLeftPoint(first, width: width, height: height))
        for point in points.dropFirst() {
            path.addLine(to: topLeftPoint(point, width: width, height: height))
        }
        return path
    }

    private func drawStep(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        rect: CGRect
    ) {
        let diameter = min(rect.width, rect.height)
        guard diameter >= 2 else { return }
        let circle = CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.setFillColor(cgColor(annotation.style.color))
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.86))
        context.setLineWidth(max(1.5, diameter * 0.035))
        context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

        let label = annotation.text ?? "1"
        let fontSize = max(12, diameter * 0.50)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary)
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        context.saveGState()
        context.translateBy(
            x: circle.midX - bounds.midX,
            y: circle.midY + bounds.midY
        )
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        lineWidth: CGFloat
    ) {
        context.addPath(arrowPath(annotation, width: width, height: height, lineWidth: lineWidth))
        context.strokePath()
    }

    private func arrowPath(
        _ annotation: ScreenshotAnnotation,
        width: CGFloat,
        height: CGFloat,
        lineWidth: CGFloat
    ) -> CGPath {
        let fallbackStart = TracePoint(x: annotation.bounds.x, y: annotation.bounds.y)
        let fallbackEnd = TracePoint(
            x: annotation.bounds.x + annotation.bounds.width,
            y: annotation.bounds.y + annotation.bounds.height
        )
        let start = topLeftPoint(annotation.start ?? fallbackStart, width: width, height: height)
        let end = topLeftPoint(annotation.end ?? fallbackEnd, width: width, height: height)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, lineWidth * 4.2)
        let spread = CGFloat.pi / 6.5
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        ))
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        ))
        return path
    }

    private func drawGradient(
        path: CGPath,
        start: TraceColor,
        end: TraceColor,
        in context: CGContext,
        bounds: CGRect,
        strokeWidth: CGFloat? = nil
    ) {
        let colors = [cgColor(start), cgColor(end)] as CFArray
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            return
        }
        context.saveGState()
        context.addPath(path)
        if let strokeWidth {
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
        }
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.maxY),
            end: CGPoint(x: bounds.maxX, y: bounds.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private func drawText(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        rect: CGRect,
        shortestSide: CGFloat
    ) {
        guard let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let fontSize = max(12, CGFloat(annotation.style.fontSize) * shortestSide)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(annotation.style.color)
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let backgroundRect = CGRect(
            x: rect.minX - 7,
            y: rect.minY - 5,
            width: textWidth + 14,
            height: fontSize + 10
        )
        let background = annotation.style.fillColor
            ?? TraceColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.62)
        context.setFillColor(cgColor(background))
        context.addPath(CGPath(
            roundedRect: backgroundRect,
            cornerWidth: 7,
            cornerHeight: 7,
            transform: nil
        ))
        context.fillPath()

        // Core Text uses a bottom-left text coordinate system, so locally unflip it.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func topLeftRect(from rect: TraceRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * width,
            y: CGFloat(rect.y) * height,
            width: CGFloat(rect.width) * width,
            height: CGFloat(rect.height) * height
        ).standardized
    }

    private func ciRect(from rect: TraceRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * width,
            y: (1 - CGFloat(rect.y + rect.height)) * height,
            width: CGFloat(rect.width) * width,
            height: CGFloat(rect.height) * height
        ).standardized
    }

    private func topLeftPoint(_ point: TracePoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * width, y: CGFloat(point.y) * height)
    }

    private func cgColor(_ color: TraceColor) -> CGColor {
        CGColor(
            red: CGFloat(min(max(color.red, 0), 1)),
            green: CGFloat(min(max(color.green, 0), 1)),
            blue: CGFloat(min(max(color.blue, 0), 1)),
            alpha: CGFloat(min(max(color.alpha, 0), 1))
        )
    }
}
