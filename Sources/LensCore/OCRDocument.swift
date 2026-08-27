import Foundation

public struct LensRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRTextBlock: Codable, Equatable, Sendable {
    public let text: String
    public let confidence: Double
    /// Normalized 0...1 bounds with a top-left origin, independent of platform pixels.
    public let normalizedBounds: LensRect

    public init(text: String, confidence: Double, normalizedBounds: LensRect) {
        self.text = text
        self.confidence = confidence
        self.normalizedBounds = normalizedBounds
    }
}

public struct OCRDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public let engine: String
    public let recognizedAt: Date
    public let recognitionLanguages: [String]
    public let fullText: String
    public let blocks: [OCRTextBlock]

    public init(
        schemaVersion: String = OCRDocument.currentSchemaVersion,
        engine: String,
        recognizedAt: Date = Date(),
        recognitionLanguages: [String],
        fullText: String? = nil,
        blocks: [OCRTextBlock]
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.recognizedAt = Date(
            timeIntervalSince1970: recognizedAt.timeIntervalSince1970.rounded(.down)
        )
        self.recognitionLanguages = recognitionLanguages
        self.fullText = fullText ?? blocks.map(\.text).joined(separator: "\n")
        self.blocks = blocks
    }
}
