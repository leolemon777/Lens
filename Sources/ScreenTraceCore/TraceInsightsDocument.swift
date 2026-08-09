import Foundation

public enum TraceInsightSource: String, Codable, Sendable {
    case metadata
    case ocr
    case transcript
}

public enum TraceSensitiveDataKind: String, Codable, CaseIterable, Sendable {
    case emailAddress
    case phoneNumber
    case paymentCard
    case governmentIdentifier
    case credential
}

public struct TraceSensitiveFinding: Codable, Equatable, Sendable {
    public let kind: TraceSensitiveDataKind
    public let source: TraceInsightSource
    public let startSeconds: Double?
    public let endSeconds: Double?
    /// A masked hint only. The matched source value is deliberately not copied
    /// into the insights document.
    public let redactedPreview: String
    public let occurrenceCount: Int

    public init(
        kind: TraceSensitiveDataKind,
        source: TraceInsightSource,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        redactedPreview: String,
        occurrenceCount: Int = 1
    ) {
        let start = startSeconds.flatMap { $0.isFinite ? max($0, 0) : nil }
        let end = endSeconds.flatMap { value in
            value.isFinite ? max(value, start ?? 0) : nil
        }
        self.kind = kind
        self.source = source
        self.startSeconds = start
        self.endSeconds = end
        self.redactedPreview = redactedPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.occurrenceCount = max(occurrenceCount, 1)
    }
}

public struct TraceChapter: Codable, Equatable, Sendable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let title: String
    public let summary: String

    public init(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        title: String,
        summary: String
    ) {
        let start = startSeconds.isFinite ? max(startSeconds, 0) : 0
        let end = endSeconds.isFinite ? max(endSeconds, start) : start
        self.index = max(index, 0)
        self.startSeconds = start
        self.endSeconds = end
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TraceInsightsCustomization: Codable, Equatable, Sendable {
    public let title: String?
    public let summary: String?
    public let tags: [String]?

    public init(
        title: String? = nil,
        summary: String? = nil,
        tags: [String]? = nil
    ) {
        self.title = title.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.summary = summary.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.tags = tags.map(Self.uniqueTags)
    }

    private static func uniqueTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == 8 { break }
        }
        return result
    }
}

public struct TraceInsightsDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.2"

    public let schemaVersion: String
    public let engine: String
    public let generatedAt: Date
    public let suggestedTitle: String
    public let summary: String
    public let tags: [String]
    public let keyPoints: [String]
    public let chapters: [TraceChapter]
    public let sensitiveFindings: [TraceSensitiveFinding]
    /// Optional human corrections. Generated fields remain intact so local
    /// reorganization can be repeated without discarding a user's choices.
    public let customization: TraceInsightsCustomization?

    public init(
        schemaVersion: String = Self.currentSchemaVersion,
        engine: String,
        generatedAt: Date = Date(),
        suggestedTitle: String,
        summary: String,
        tags: [String],
        keyPoints: [String] = [],
        chapters: [TraceChapter] = [],
        sensitiveFindings: [TraceSensitiveFinding] = [],
        customization: TraceInsightsCustomization? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        self.generatedAt = Date(
            timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down)
        )
        self.suggestedTitle = suggestedTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Self.uniqueNonempty(tags, maximumCount: 8)
        self.keyPoints = Self.uniqueNonempty(keyPoints, maximumCount: 6)
        self.chapters = chapters.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.index < $1.index
        }
        self.sensitiveFindings = sensitiveFindings.filter {
            !$0.redactedPreview.isEmpty
        }
        self.customization = customization
    }

    public var resolvedTitle: String {
        customization?.title ?? suggestedTitle
    }

    public var resolvedSummary: String {
        customization?.summary ?? summary
    }

    public var resolvedTags: [String] {
        customization?.tags ?? tags
    }

    public func replacingCustomization(
        _ customization: TraceInsightsCustomization?
    ) -> TraceInsightsDocument {
        TraceInsightsDocument(
            engine: engine,
            generatedAt: generatedAt,
            suggestedTitle: suggestedTitle,
            summary: summary,
            tags: tags,
            keyPoints: keyPoints,
            chapters: chapters,
            sensitiveFindings: sensitiveFindings,
            customization: customization
        )
    }

    private static func uniqueNonempty(
        _ values: [String],
        maximumCount: Int
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == maximumCount { break }
        }
        return result
    }
}
