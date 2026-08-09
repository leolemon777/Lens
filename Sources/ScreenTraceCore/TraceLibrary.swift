import Foundation

public struct TraceLibraryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID { manifest.id }

    public let packageURL: URL
    public let manifest: TraceManifest
    public let primaryAssetURL: URL
    public let displayAssetURL: URL
    public let ocrText: String?

    public init(
        packageURL: URL,
        manifest: TraceManifest,
        primaryAssetURL: URL,
        displayAssetURL: URL,
        ocrText: String?
    ) {
        self.packageURL = packageURL
        self.manifest = manifest
        self.primaryAssetURL = primaryAssetURL
        self.displayAssetURL = displayAssetURL
        self.ocrText = ocrText
    }

    public var searchableText: String {
        [manifest.title, ocrText ?? ""]
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
