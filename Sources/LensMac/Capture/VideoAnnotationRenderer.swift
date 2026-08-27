import CoreGraphics
import CoreImage
import CoreText
import Foundation
import LensCore

/// Applies source-time annotations without flattening or mutating the original media.
/// Vector overlays are cached per render size; only opacity and raster effects vary per frame.
final class VideoAnnotationRenderer: @unchecked Sendable {
    private struct OverlayKey: Hashable {
        let id: UUID
        let width: Int
        let height: Int
    }

    private let annotations: [VideoAnnotation]
    private let cacheLock = NSLock()
    private var vectorOverlayCache: [OverlayKey: CIImage] = [:]

    init(annotations: [VideoAnnotation]) {
        self.annotations = annotations
    }

    func apply(to source: CIImage, atSourceTime sourceTime: Double) -> CIImage {
        let active = VideoAnnotationPlanner.activeAnnotations(
            atSourceTime: sourceTime,
            annotations: annotations
        )
        return apply(active: active, to: source)
    }

    func apply(
        to source: CIImage,
        atOutputTime outputTime: Double,
        timeline: VideoEditTimeline?
    ) -> CIImage {
        let active = VideoAnnotationPlanner.activeAnnotations(
            atOutputTime: outputTime,
            annotations: annotations,
            timeline: timeline
        )
        return apply(active: active, to: source)
    }

    private func apply(
        active: [(annotation: ScreenshotAnnotation, opacity: Double)],
        to source: CIImage
    ) -> CIImage {
        guard !active.isEmpty else { return source }

        let extent = source.extent
        var result = source
        for item in active where item.annotation.kind == .blur
            || item.annotation.kind == .pixelate {
            result = applyRasterEffect(
                item.annotation,
                opacity: item.opacity,
                to: result,
                extent: extent
            )
        }
        for item in active where item.annotation.kind != .blur
            && item.annotation.kind != .pixelate {
            guard var overlay = vectorOverlay(
                for: item.annotation,
                width: max(Int(extent.width.rounded()), 1),
                height: max(Int(extent.height.rounded()), 1)
            ) else { continue }
            if extent.origin != .zero {
                overlay = overlay.transformed(by: CGAffineTransform(
                    translationX: extent.minX,
                    y: extent.minY
                ))
            }
            if item.opacity < 0.999_9 {
                overlay = overlay.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: item.opacity)
                ])
            }
            result = overlay.composited(over: result).cropped(to: extent)
        }
        return result
    }

    private func applyRasterEffect(
        _ annotation: ScreenshotAnnotation,
        opacity: Double,
        to source: CIImage,
        extent: CGRect
    ) -> CIImage {
        let region = ciRect(
            from: annotation.bounds,
            width: extent.width,
            height: extent.height
        ).offsetBy(dx: extent.minX, dy: extent.minY).intersection(extent)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return source }
        let shortestSide = min(extent.width, extent.height)
        let processed: CIImage
        switch annotation.kind {
        case .blur:
            processed = source
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(3, annotation.style.intensity * shortestSide)
                ])
                .cropped(to: region)
        case .pixelate:
            processed = source
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(5, annotation.style.intensity * shortestSide),
                    kCIInputCenterKey: CIVector(x: region.midX, y: region.midY)
                ])
                .cropped(to: region)
        default:
            return source
        }
        let faded = processed.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
        ])
        return faded.composited(over: source).cropped(to: extent)
    }

    private func vectorOverlay(
        for annotation: ScreenshotAnnotation,
        width: Int,
        height: Int
    ) -> CIImage? {
        let key = OverlayKey(id: annotation.id, width: width, height: height)
        cacheLock.lock()
        if let cached = vectorOverlayCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let image = makeVectorOverlay(
            annotation,
            width: width,
            height: height
        ) else { return nil }
        let overlay = CIImage(cgImage: image)
        cacheLock.lock()
        vectorOverlayCache[key] = overlay
        cacheLock.unlock()
        return overlay
    }

    private func makeVectorOverlay(
        _ annotation: ScreenshotAnnotation,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let shortestSide = CGFloat(min(width, height))
        let lineWidth = max(2, CGFloat(annotation.style.lineWidth) * shortestSide)
        context.setLineWidth(lineWidth)
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
            drawArrow(
                annotation,
                in: context,
                width: CGFloat(width),
                height: CGFloat(height),
                lineWidth: lineWidth
            )
        case .freehand:
            drawFreehand(
                annotation,
                in: context,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        case .highlight:
            context.setFillColor(cgColor(
                annotation.style.fillColor
                    ?? LensColor(
                        red: annotation.style.color.red,
                        green: annotation.style.color.green,
                        blue: annotation.style.color.blue,
                        alpha: 0.28
                    )
            ))
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: max(2, rect.height * 0.12),
                cornerHeight: max(2, rect.height * 0.12),
                transform: nil
            ))
            context.fillPath()
        case .step:
            drawStep(annotation, in: context, rect: rect)
        case .text:
            drawText(
                annotation,
                in: context,
                rect: rect,
                shortestSide: shortestSide
            )
        case .blur, .pixelate:
            return nil
        }
        return context.makeImage()
    }

    private func drawFreehand(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat
    ) {
        guard let points = annotation.points, let first = points.first else { return }
        context.move(to: topLeftPoint(first, width: width, height: height))
        for point in points.dropFirst() {
            context.addLine(to: topLeftPoint(point, width: width, height: height))
        }
        context.strokePath()
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

        let fontSize = max(12, diameter * 0.50)
        drawCoreText(
            annotation.text ?? "1",
            fontName: "Helvetica-Bold",
            fontSize: fontSize,
            color: CGColor(gray: 1, alpha: 1),
            in: context,
            origin: CGPoint(x: circle.midX, y: circle.midY),
            centersAtOrigin: true
        )
    }

    private func drawArrow(
        _ annotation: ScreenshotAnnotation,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        lineWidth: CGFloat
    ) {
        let fallbackStart = LensPoint(x: annotation.bounds.x, y: annotation.bounds.y)
        let fallbackEnd = LensPoint(
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
        context.setFillColor(cgColor(
            annotation.style.fillColor
                ?? LensColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.62)
        ))
        context.addPath(CGPath(
            roundedRect: backgroundRect,
            cornerWidth: 7,
            cornerHeight: 7,
            transform: nil
        ))
        context.fillPath()

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawCoreText(
        _ text: String,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor,
        in context: CGContext,
        origin: CGPoint,
        centersAtOrigin: Bool
    ) {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        context.saveGState()
        context.translateBy(
            x: centersAtOrigin ? origin.x - bounds.midX : origin.x,
            y: centersAtOrigin ? origin.y + bounds.midY : origin.y
        )
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func topLeftRect(from rect: LensRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * width,
            y: CGFloat(rect.y) * height,
            width: CGFloat(rect.width) * width,
            height: CGFloat(rect.height) * height
        ).standardized
    }

    private func ciRect(from rect: LensRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * width,
            y: (1 - CGFloat(rect.y + rect.height)) * height,
            width: CGFloat(rect.width) * width,
            height: CGFloat(rect.height) * height
        ).standardized
    }

    private func topLeftPoint(_ point: LensPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * width, y: CGFloat(point.y) * height)
    }

    private func cgColor(_ color: LensColor) -> CGColor {
        CGColor(
            red: CGFloat(min(max(color.red, 0), 1)),
            green: CGFloat(min(max(color.green, 0), 1)),
            blue: CGFloat(min(max(color.blue, 0), 1)),
            alpha: CGFloat(min(max(color.alpha, 0), 1))
        )
    }
}
