import Foundation

public enum ScreenshotAnnotationKind: String, Codable, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case arrow
    case freehand
    case highlight
    case step
    case text
    case blur
    case pixelate
}

public struct LensColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func withAlpha(_ alpha: Double) -> LensColor {
        LensColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let red = LensColor(red: 1, green: 0.23, blue: 0.19)
    public static let orange = LensColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = LensColor(red: 1, green: 0.80, blue: 0)
    public static let green = LensColor(red: 0.20, green: 0.78, blue: 0.35)
    public static let cyan = LensColor(red: 0.13, green: 0.78, blue: 0.88)
    public static let blue = LensColor(red: 0.10, green: 0.58, blue: 1)
    public static let purple = LensColor(red: 0.63, green: 0.36, blue: 0.94)
    public static let pink = LensColor(red: 1, green: 0.28, blue: 0.55)
    public static let white = LensColor(red: 1, green: 1, blue: 1)
    public static let black = LensColor(red: 0.04, green: 0.04, blue: 0.05)
}

public struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    /// Stroke width as a fraction of the image's shortest side.
    public var lineWidth: Double
    /// Font size as a fraction of the image's shortest side.
    public var fontSize: Double
    public var color: LensColor
    /// Optional end color for a top-leading to bottom-trailing annotation gradient.
    /// Missing in older project files and therefore backward compatible.
    public var gradientEndColor: LensColor?
    public var fillColor: LensColor?
    /// Normalized effect strength for blur and pixelation.
    public var intensity: Double

    public init(
        lineWidth: Double = 0.006,
        fontSize: Double = 0.045,
        color: LensColor = .red,
        gradientEndColor: LensColor? = nil,
        fillColor: LensColor? = nil,
        intensity: Double = 0.035
    ) {
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.color = color
        self.gradientEndColor = gradientEndColor
        self.fillColor = fillColor
        self.intensity = intensity
    }
}

public struct ScreenshotAnnotation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ScreenshotAnnotationKind
    /// Normalized bounds with a top-left origin.
    public var bounds: LensRect
    /// Normalized start and end points used by directional tools such as arrows.
    public var start: LensPoint?
    public var end: LensPoint?
    /// Normalized top-left-origin points used by freehand paths.
    public var points: [LensPoint]?
    public var text: String?
    public var style: ScreenshotAnnotationStyle

    public init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        bounds: LensRect,
        start: LensPoint? = nil,
        end: LensPoint? = nil,
        points: [LensPoint]? = nil,
        text: String? = nil,
        style: ScreenshotAnnotationStyle = ScreenshotAnnotationStyle()
    ) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.style = style
    }
}

public enum ScreenshotCanvasBackgroundKind: String, Codable, CaseIterable, Sendable {
    case solid
    case gradient
}

public enum ScreenshotCanvasAspectRatio: String, Codable, CaseIterable, Sendable {
    case automatic
    case square
    case landscape4x3
    case widescreen16x9
    case portrait9x16

    public var value: Double? {
        switch self {
        case .automatic: nil
        case .square: 1
        case .landscape4x3: 4.0 / 3.0
        case .widescreen16x9: 16.0 / 9.0
        case .portrait9x16: 9.0 / 16.0
        }
    }
}

public enum ScreenshotExportFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

public struct ScreenshotCanvasStyle: Codable, Equatable, Sendable {
    public var backgroundKind: ScreenshotCanvasBackgroundKind
    public var primaryColor: LensColor
    public var secondaryColor: LensColor
    /// Padding on every side as a fraction of the source image's shortest side.
    public var padding: Double
    /// Source-image corner radius as a fraction of its shortest side.
    public var cornerRadius: Double
    /// Shadow blur radius as a fraction of the source image's shortest side.
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var aspectRatio: ScreenshotCanvasAspectRatio

    public init(
        backgroundKind: ScreenshotCanvasBackgroundKind = .gradient,
        primaryColor: LensColor = LensColor(red: 0.20, green: 0.35, blue: 0.92),
        secondaryColor: LensColor = LensColor(red: 0.55, green: 0.22, blue: 0.88),
        padding: Double = 0.08,
        cornerRadius: Double = 0.025,
        shadowRadius: Double = 0.035,
        shadowOpacity: Double = 0.32,
        aspectRatio: ScreenshotCanvasAspectRatio = .automatic
    ) {
        self.backgroundKind = backgroundKind
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.aspectRatio = aspectRatio
    }

    public var normalized: ScreenshotCanvasStyle {
        ScreenshotCanvasStyle(
            backgroundKind: backgroundKind,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            padding: min(max(padding, 0.02), 0.30),
            cornerRadius: min(max(cornerRadius, 0), 0.12),
            shadowRadius: min(max(shadowRadius, 0), 0.12),
            shadowOpacity: min(max(shadowOpacity, 0), 0.80),
            aspectRatio: aspectRatio
        )
    }
}

public struct ScreenshotCanvasLayout: Equatable, Sendable {
    public let outputDimensions: LensDimensions
    /// Source image frame in output pixels, using a top-left origin.
    public let sourceFrame: LensRect

    public init(outputDimensions: LensDimensions, sourceFrame: LensRect) {
        self.outputDimensions = outputDimensions
        self.sourceFrame = sourceFrame
    }
}

public enum ScreenshotCanvasPlanner {
    public static func layout(
        sourceDimensions: LensDimensions,
        style: ScreenshotCanvasStyle?
    ) -> ScreenshotCanvasLayout {
        let sourceWidth = Double(max(sourceDimensions.width, 1))
        let sourceHeight = Double(max(sourceDimensions.height, 1))
        guard let style else {
            return ScreenshotCanvasLayout(
                outputDimensions: LensDimensions(
                    width: Int(sourceWidth),
                    height: Int(sourceHeight)
                ),
                sourceFrame: LensRect(
                    x: 0,
                    y: 0,
                    width: sourceWidth,
                    height: sourceHeight
                )
            )
        }

        let normalized = style.normalized
        let padding = min(sourceWidth, sourceHeight) * normalized.padding
        let minimumWidth = sourceWidth + padding * 2
        let minimumHeight = sourceHeight + padding * 2
        var outputWidth = minimumWidth
        var outputHeight = minimumHeight
        if let ratio = normalized.aspectRatio.value {
            if outputWidth / outputHeight < ratio {
                outputWidth = outputHeight * ratio
            } else {
                outputHeight = outputWidth / ratio
            }
        }
        let pixelWidth = max(Int(ceil(outputWidth)), 1)
        let pixelHeight = max(Int(ceil(outputHeight)), 1)
        return ScreenshotCanvasLayout(
            outputDimensions: LensDimensions(width: pixelWidth, height: pixelHeight),
            sourceFrame: LensRect(
                x: (Double(pixelWidth) - sourceWidth) / 2,
                y: (Double(pixelHeight) - sourceHeight) / 2,
                width: sourceWidth,
                height: sourceHeight
            )
        )
    }
}

public struct ScreenshotEditPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.3"

    public let schemaVersion: String
    public let sourceDimensions: LensDimensions
    public var annotations: [ScreenshotAnnotation]
    public var canvasStyle: ScreenshotCanvasStyle?

    public init(
        schemaVersion: String = ScreenshotEditPlan.currentSchemaVersion,
        sourceDimensions: LensDimensions,
        annotations: [ScreenshotAnnotation] = [],
        canvasStyle: ScreenshotCanvasStyle? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceDimensions = sourceDimensions
        self.annotations = annotations
        self.canvasStyle = canvasStyle
    }
}
