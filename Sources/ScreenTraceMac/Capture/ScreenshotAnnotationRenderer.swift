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

struct ScreenshotAnnotationRenderer {
    func render(source: CGImage, plan: ScreenshotEditPlan) throws -> CGImage {
        guard source.width == plan.sourceDimensions.width,
              source.height == plan.sourceDimensions.height else {
            throw ScreenshotAnnotationRendererError.sourceDimensionsMismatch
        }

        let effected = try renderRasterEffects(source: source, annotations: plan.annotations)
        return try renderVectorAnnotations(base: effected, annotations: plan.annotations)
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

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(current, from: extent) else {
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
            switch annotation.kind {
            case .rectangle:
                if annotation.style.fillColor != nil { context.fill(rect) }
                context.stroke(rect)
            case .ellipse:
                if annotation.style.fillColor != nil { context.fillEllipse(in: rect) }
                context.strokeEllipse(in: rect)
            case .arrow:
                drawArrow(annotation, in: context, width: CGFloat(width), height: CGFloat(height), lineWidth: lineWidth)
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

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        lineWidth: CGFloat
    ) {
        let fallbackStart = TracePoint(x: annotation.bounds.x, y: annotation.bounds.y)
        let fallbackEnd = TracePoint(
            x: annotation.bounds.x + annotation.bounds.width,
            y: annotation.bounds.y + annotation.bounds.height
        )
        let start = topLeftPoint(annotation.start ?? fallbackStart, width: width, height: height)
        let end = topLeftPoint(annotation.end ?? fallbackEnd, width: width, height: height)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, lineWidth * 4.2)
        let spread = CGFloat.pi / 6.5
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        ))
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        ))
        context.strokePath()
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
