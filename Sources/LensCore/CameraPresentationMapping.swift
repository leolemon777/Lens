import CoreGraphics

/// Shared mapping for camera-aware cursor, click, and overlay placement.
///
/// Screen-recording coordinates are source-normalized (origin top-left). Core
/// Image frames are bottom-left. Live overlays sit in AppKit view space. Every
/// renderer and overlay must use this type so a 9:16 / 1:1 contain-fit cannot
/// place the pointer on letterbox bars.
public enum CameraPresentationMapping {
    /// Aspect-fit `content` inside `bounds`. Degenerate sizes fall back to `bounds`.
    public static func aspectFitRect(for content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 1,
              content.height > 1,
              bounds.width > 1,
              bounds.height > 1 else {
            return bounds
        }
        let contentAspect = content.width / content.height
        let boundsAspect = bounds.width / bounds.height
        if contentAspect > boundsAspect {
            let height = bounds.width / contentAspect
            return CGRect(
                x: bounds.minX,
                y: bounds.minY + (bounds.height - height) / 2,
                width: bounds.width,
                height: height
            )
        }
        let width = bounds.height * contentAspect
        return CGRect(
            x: bounds.minX + (bounds.width - width) / 2,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    /// Maps a source-normalized point through a camera viewport in source pixel
    /// space, then contain-fits the scaled viewport into `deliveryExtent`.
    public static func ciOutputPoint(
        sourceNormalized: LensPoint,
        sourceExtent: CGRect,
        viewport: CGRect,
        scale: CGFloat,
        deliveryExtent: CGRect,
        contentSize: CGSize
    ) -> CGPoint {
        let screenPoint = CGPoint(
            x: sourceExtent.minX + sourceExtent.width * CGFloat(sourceNormalized.x),
            y: sourceExtent.minY + sourceExtent.height * (1 - CGFloat(sourceNormalized.y))
        )
        let letterbox = CGPoint(
            x: (deliveryExtent.width - contentSize.width) / 2,
            y: (deliveryExtent.height - contentSize.height) / 2
        )
        return CGPoint(
            x: (screenPoint.x - viewport.minX) * scale + letterbox.x,
            y: (screenPoint.y - viewport.minY) * scale + letterbox.y
        )
    }

    /// Source-pixel cursor size shared by final rendering and the live overlay.
    public static func baseCursorWidth(sourcePixelWidth: CGFloat) -> CGFloat {
        min(max(sourcePixelWidth * 0.021, 36), 104)
    }

    /// Cursor rectangle in the same output space as `outputPoint`.
    public static func cursorFrame(
        at outputPoint: CGPoint,
        sourcePixelWidth: CGFloat,
        userScale: Double,
        relativeWidth: CGFloat,
        imageSize: CGSize,
        hotSpot: CGPoint
    ) -> CGRect {
        let width = baseCursorWidth(sourcePixelWidth: max(sourcePixelWidth, 1))
            * CGFloat(userScale)
            * max(relativeWidth, 0.001)
        let height = width * max(imageSize.height, 1) / max(imageSize.width, 1)
        return CGRect(
            x: outputPoint.x - width * hotSpot.x,
            y: outputPoint.y - height * hotSpot.y,
            width: width,
            height: height
        )
    }

    /// Click-pulse diameter in output pixels, matching the renderer ring.
    public static func clickPulseDiameter(
        sourcePixelWidth: CGFloat,
        pulseScale: Double
    ) -> CGFloat {
        baseCursorWidth(sourcePixelWidth: max(sourcePixelWidth, 1)) * 1.85 * CGFloat(pulseScale)
    }
}
