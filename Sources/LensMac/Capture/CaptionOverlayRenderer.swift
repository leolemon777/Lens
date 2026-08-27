import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import LensCore

final class CaptionOverlayRenderer: @unchecked Sendable {
    private final class RenderedCaption: NSObject {
        let image: CIImage
        let size: CGSize
        let cornerRadius: CGFloat

        init(image: CIImage, size: CGSize, cornerRadius: CGFloat) {
            self.image = image
            self.size = size
            self.cornerRadius = cornerRadius
        }
    }

    private struct Placement {
        let centerX: CGFloat
        let maximumWidth: CGFloat
    }

    private let cues: [CaptionCue]
    private let configuration: AutoEditPlan.Captions
    private let presenter: AutoEditPlan.PresenterCamera?
    private let cameraKeyframes: [AutoEditPlan.CameraKeyframe]
    private let timeline: VideoEditTimeline?
    private let cache = NSCache<NSString, RenderedCaption>()

    init(
        cues: [CaptionCue],
        configuration: AutoEditPlan.Captions,
        presenter: AutoEditPlan.PresenterCamera?,
        cameraKeyframes: [AutoEditPlan.CameraKeyframe] = [],
        timeline: VideoEditTimeline? = nil
    ) {
        self.cues = cues
        self.configuration = configuration
        self.presenter = presenter
        self.cameraKeyframes = cameraKeyframes
        self.timeline = timeline
        cache.countLimit = 180
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func apply(to requestedFrame: CIImage, at time: Double) -> CIImage {
        guard let cue = CaptionCuePlanner.activeCue(at: time, in: cues) else {
            return requestedFrame
        }
        let extent = requestedFrame.extent
        guard extent.width > 1, extent.height > 1 else { return requestedFrame }
        let frame = requestedFrame.cropped(to: extent)
        let placement = placement(in: extent, at: time)
        guard let rendered = renderedCaption(
            text: cue.text,
            outputSize: extent.size,
            maximumWidth: placement.maximumWidth
        ) else { return frame }

        let originX = min(max(
            placement.centerX - rendered.size.width / 2,
            extent.minX
        ), extent.maxX - rendered.size.width)
        let originY: CGFloat = switch configuration.position {
        case .top:
            extent.maxY
                - extent.height * configuration.verticalMargin
                - rendered.size.height
        case .center:
            extent.midY - rendered.size.height / 2
        case .bottom:
            extent.minY + extent.height * configuration.verticalMargin
        }
        let target = CGRect(
            origin: CGPoint(
                x: originX,
                y: min(max(originY, extent.minY), extent.maxY - rendered.size.height)
            ),
            size: rendered.size
        ).integral
        let positionedContent = rendered.image.transformed(by: CGAffineTransform(
            translationX: target.minX - rendered.image.extent.minX,
            y: target.minY - rendered.image.extent.minY
        ))

        var background = frame
        if configuration.style == .glass {
            let maskGenerator = CIFilter.roundedRectangleGenerator()
            maskGenerator.extent = target
            maskGenerator.radius = Float(rendered.cornerRadius)
            maskGenerator.color = .white
            let mask = (maskGenerator.outputImage
                ?? CIImage(color: .white).cropped(to: target))
                .cropped(to: extent)
            let clear = CIImage(color: .clear).cropped(to: extent)
            let blurRadius = min(extent.width, extent.height) * 0.018
            let blurred = frame
                .clampedToExtent()
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: blurRadius]
                )
                .cropped(to: extent)
            let clippedBlur = blurred.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: clear,
                    kCIInputMaskImageKey: mask
                ]
            ).cropped(to: extent)
            background = clippedBlur.composited(over: frame).cropped(to: extent)
        }
        return positionedContent
            .composited(over: background)
            .cropped(to: extent)
    }

    private func placement(in extent: CGRect, at outputTime: Double) -> Placement {
        let defaultPlacement = Placement(
            centerX: extent.midX,
            maximumWidth: extent.width * 0.76
        )
        guard let presenter, presenter.isEnabled else { return defaultPlacement }
        let sourceTime = timeline?.position(atOutputTime: outputTime)?.sourceTimeSeconds
            ?? outputTime
        let aspectRatio = Double(extent.width / max(extent.height, 1))
        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: sourceTime,
            layout: presenter,
            cameraKeyframes: cameraKeyframes,
            captions: configuration,
            captionAvoidanceAmount: CaptionCuePlanner.avoidanceAmount(
                at: outputTime,
                in: cues
            ),
            canvasAspectRatio: aspectRatio
        )
        let normalizedHeight = state.size * aspectRatio
            * (presenter.shape == .circle ? 1 : 9.0 / 16.0)
        let cameraTop = state.center.y - normalizedHeight / 2
        let cameraBottom = state.center.y + normalizedHeight / 2
        let captionBand: ClosedRange<Double> = switch configuration.position {
        case .top: 0.025...0.245
        case .center: 0.39...0.61
        case .bottom: 0.755...0.975
        }
        guard cameraBottom >= captionBand.lowerBound,
              cameraTop <= captionBand.upperBound else { return defaultPlacement }

        let outerGap = extent.width * 0.025
        let cameraWidth = extent.width * state.size
        let cameraLeft = extent.minX + extent.width * state.center.x - cameraWidth / 2
        let cameraRight = cameraLeft + cameraWidth
        let available: CGRect = if state.center.x <= 0.5 {
            CGRect(
                x: max(cameraRight + outerGap, extent.minX + outerGap),
                y: extent.minY,
                width: max(extent.maxX - outerGap - cameraRight - outerGap, 0),
                height: extent.height
            )
        } else {
            CGRect(
                x: extent.minX + outerGap,
                y: extent.minY,
                width: max(cameraLeft - outerGap - extent.minX - outerGap, 0),
                height: extent.height
            )
        }
        guard available.width > extent.width * 0.28 else { return defaultPlacement }
        return Placement(
            centerX: available.midX,
            maximumWidth: min(available.width * 0.94, extent.width * 0.76)
        )
    }

    private func renderedCaption(
        text: String,
        outputSize: CGSize,
        maximumWidth: CGFloat
    ) -> RenderedCaption? {
        let key = NSString(string: [
            text,
            String(Int(outputSize.width.rounded())),
            String(Int(outputSize.height.rounded())),
            String(Int(maximumWidth.rounded())),
            configuration.style.rawValue,
            String(format: "%.3f", configuration.fontScale)
        ].joined(separator: "|"))
        if let cached = cache.object(forKey: key) { return cached }
        guard let rendered = Self.drawCaption(
            text: text,
            outputSize: outputSize,
            maximumWidth: maximumWidth,
            configuration: configuration
        ) else { return nil }
        let cost = max(Int(rendered.size.width * rendered.size.height * 4), 1)
        cache.setObject(rendered, forKey: key, cost: cost)
        return rendered
    }

    private static func drawCaption(
        text: String,
        outputSize: CGSize,
        maximumWidth: CGFloat,
        configuration: AutoEditPlan.Captions
    ) -> RenderedCaption? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let baseFontSize = max(
            15,
            min(outputSize.width * 0.032, outputSize.height * 0.072)
        )
        let fontSize = baseFontSize * configuration.fontScale
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 1,
                green: 1,
                blue: 1,
                alpha: 0.98
            ),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let horizontalPadding = fontSize * 0.72
        let verticalPadding = fontSize * 0.46
        let maximumTextWidth = max(maximumWidth - horizontalPadding * 2, fontSize * 3)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let textWidth = min(max(ceil(suggested.width), fontSize), maximumTextWidth)
        let textHeight = max(ceil(suggested.height), fontSize * 1.12)
        let width = max(Int(ceil(textWidth + horizontalPadding * 2)), 1)
        let height = max(Int(ceil(textHeight + verticalPadding * 2)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = CGRect(
            x: 1,
            y: 1,
            width: CGFloat(width) - 2,
            height: CGFloat(height) - 2
        )
        let cornerRadius = min(CGFloat(height) * 0.32, fontSize * 0.78)
        let backgroundPath = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        switch configuration.style {
        case .glass:
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -fontSize * 0.10),
                blur: fontSize * 0.34,
                color: CGColor(gray: 0, alpha: 0.34)
            )
            context.addPath(backgroundPath)
            context.setFillColor(CGColor(gray: 0.035, alpha: 0.34))
            context.fillPath()
            context.restoreGState()
            context.addPath(backgroundPath)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.24))
            context.setLineWidth(max(1, fontSize * 0.035))
            context.strokePath()
        case .highContrast:
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -fontSize * 0.08),
                blur: fontSize * 0.24,
                color: CGColor(gray: 0, alpha: 0.5)
            )
            context.addPath(backgroundPath)
            context.setFillColor(CGColor(gray: 0.015, alpha: 0.91))
            context.fillPath()
            context.restoreGState()
        case .clean:
            break
        }

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -fontSize * 0.06),
            blur: configuration.style == .clean ? fontSize * 0.20 : fontSize * 0.10,
            color: CGColor(gray: 0, alpha: configuration.style == .clean ? 0.94 : 0.66)
        )
        let textRect = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: textHeight
        )
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()

        guard let image = context.makeImage() else { return nil }
        return RenderedCaption(
            image: CIImage(cgImage: image),
            size: CGSize(width: width, height: height),
            cornerRadius: cornerRadius
        )
    }
}
