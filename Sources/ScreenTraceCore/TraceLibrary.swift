import Foundation

public struct TraceLibraryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID { manifest.id }

    public let packageURL: URL
    public let manifest: TraceManifest
    public let primaryAssetURL: URL
    public let displayAssetURL: URL
    public let ocrText: String?
    public let transcriptText: String?
    public let insights: TraceInsightsDocument?

    public init(
        packageURL: URL,
        manifest: TraceManifest,
        primaryAssetURL: URL,
        displayAssetURL: URL,
        ocrText: String?,
        transcriptText: String? = nil,
        insights: TraceInsightsDocument? = nil
    ) {
        self.packageURL = packageURL
        self.manifest = manifest
        self.primaryAssetURL = primaryAssetURL
        self.displayAssetURL = displayAssetURL
        self.ocrText = ocrText
        self.transcriptText = transcriptText
        self.insights = insights
    }

    public var searchableText: String {
        var values: [String] = [
            manifest.title,
            ocrText ?? "",
            transcriptText ?? ""
        ]
        if let insights {
            values.append(contentsOf: [
                insights.suggestedTitle,
                insights.summary,
                insights.tags.joined(separator: " "),
                insights.resolvedTitle,
                insights.resolvedSummary,
                insights.resolvedTags.joined(separator: " "),
                insights.keyPoints.joined(separator: " "),
                insights.chapters.map(\.title).joined(separator: " ")
            ])
        }
        return values
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum TraceLibraryFilter: String, CaseIterable, Sendable {
    case all
    case screenshots
    case recordings
}

public enum TraceLibrarySearch {
    public static func filter(
        _ entries: [TraceLibraryEntry],
        query: String,
        filter: TraceLibraryFilter
    ) -> [TraceLibraryEntry] {
        let tokens = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return entries.filter { entry in
            let kindMatches = switch filter {
            case .all: true
            case .screenshots: entry.manifest.kind == .screenshot
            case .recordings: entry.manifest.kind == .recording
            }
            guard kindMatches else { return false }
            return tokens.allSatisfy { entry.searchableText.localizedStandardContains($0) }
        }
    }
}
