import Foundation

public enum ScreenshotAnnotationKind: String, Codable, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case arrow
    case text
    case blur
    case pixelate
}

public struct TraceColor: Codable, Equatable, Sendable {
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

    public static let red = TraceColor(red: 1, green: 0.23, blue: 0.19)
    public static let orange = TraceColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = TraceColor(red: 1, green: 0.80, blue: 0)
    public static let blue = TraceColor(red: 0.10, green: 0.58, blue: 1)
    public static let white = TraceColor(red: 1, green: 1, blue: 1)
    public static let black = TraceColor(red: 0.04, green: 0.04, blue: 0.05)
}

public struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    /// Stroke width as a fraction of the image's shortest side.
    public var lineWidth: Double
    /// Font size as a fraction of the image's shortest side.
    public var fontSize: Double
    public var color: TraceColor
    public var fillColor: TraceColor?
    /// Normalized effect strength for blur and pixelation.
    public var intensity: Double

    public init(
        lineWidth: Double = 0.006,
        fontSize: Double = 0.045,
        color: TraceColor = .red,
        fillColor: TraceColor? = nil,
        intensity: Double = 0.035
    ) {
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.color = color
        self.fillColor = fillColor
        self.intensity = intensity
    }
}

public struct ScreenshotAnnotation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ScreenshotAnnotationKind
    /// Normalized bounds with a top-left origin.
    public var bounds: TraceRect
    /// Normalized start and end points used by directional tools such as arrows.
    public var start: TracePoint?
    public var end: TracePoint?
    public var text: String?
    public var style: ScreenshotAnnotationStyle

    public init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        bounds: TraceRect,
        start: TracePoint? = nil,
        end: TracePoint? = nil,
        text: String? = nil,
        style: ScreenshotAnnotationStyle = ScreenshotAnnotationStyle()
    ) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.start = start
        self.end = end
        self.text = text
        self.style = style
    }
}

public struct ScreenshotEditPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public let sourceDimensions: TraceDimensions
    public var annotations: [ScreenshotAnnotation]

    public init(
        schemaVersion: String = ScreenshotEditPlan.currentSchemaVersion,
        sourceDimensions: TraceDimensions,
        annotations: [ScreenshotAnnotation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceDimensions = sourceDimensions
        self.annotations = annotations
    }
}
