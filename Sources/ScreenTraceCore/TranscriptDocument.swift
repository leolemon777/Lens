import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let confidence: Double

    public init(
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        confidence: Double
    ) {
        let start = startSeconds.isFinite ? max(startSeconds, 0) : 0
        let end = endSeconds.isFinite ? max(endSeconds, start) : start
        self.startSeconds = start
        self.endSeconds = end
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
    }
}

public struct TranscriptDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public let engine: String
    public let generatedAt: Date
    public let localeIdentifier: String
    public let isOnDevice: Bool
    public let sourceRole: TraceAsset.Role
    public let fullText: String
    public let segments: [TranscriptSegment]

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        engine: String,
        generatedAt: Date = Date(),
        localeIdentifier: String,
        isOnDevice: Bool,
        sourceRole: TraceAsset.Role,
        fullText: String? = nil,
        segments: [TranscriptSegment]
    ) {
        let normalizedSegments = segments
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.startSeconds != $1.startSeconds {
                    return $0.startSeconds < $1.startSeconds
                }
                return $0.endSeconds < $1.endSeconds
            }
        self.schemaVersion = schemaVersion
        self.engine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        self.generatedAt = Date(
            timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down)
        )
        self.localeIdentifier = localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.isOnDevice = isOnDevice
        self.sourceRole = sourceRole
        let suppliedText = fullText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullText = suppliedText.flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedSegments.map(\.text).joined(separator: " ")
        self.segments = normalizedSegments
    }
}
