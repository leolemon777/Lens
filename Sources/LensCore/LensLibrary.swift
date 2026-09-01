import Foundation

public struct LensLibraryEntry: Identifiable, Equatable, Sendable {
    public var id: UUID { manifest.id }

    public let packageURL: URL
    public let manifest: LensManifest
    public let primaryAssetURL: URL
    public let displayAssetURL: URL
    public let ocrText: String?
    public let transcriptText: String?
    public let insights: LensInsightsDocument?

    public init(
        packageURL: URL,
        manifest: LensManifest,
        primaryAssetURL: URL,
        displayAssetURL: URL,
        ocrText: String?,
        transcriptText: String? = nil,
        insights: LensInsightsDocument? = nil
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

public enum LensLibraryFilter: String, CaseIterable, Sendable {
    case all
    case screenshots
    case recordings
}

public enum LensLibrarySearch {
    /// Small, explainable aliases make common intent searches useful while
    /// keeping the whole index local. This is deliberately not presented as
    /// embedding-level semantic search; it is a deterministic bridge until a
    /// future on-device index can be introduced without changing this API.
    private static let intentAliases: [String: [String]] = [
        "截图": ["图片", "图像", "screen shot", "screenshot", "image"],
        "图片": ["截图", "图像", "screen shot", "screenshot", "image"],
        "图像": ["截图", "图片", "screen shot", "screenshot", "image"],
        "screenshot": ["截图", "图片", "图像", "screen shot", "image"],
        "screen": ["屏幕", "截图", "录屏", "screen shot", "screenshot"],
        "录屏": ["视频", "演示", "recording", "screen recording", "video"],
        "视频": ["录屏", "演示", "recording", "screen recording", "video"],
        "演示": ["录屏", "视频", "教程", "demo", "presentation"],
        "recording": ["录屏", "视频", "演示", "screen recording", "video"],
        "video": ["录屏", "视频", "演示", "recording", "screen recording"],
        "教程": ["步骤", "指南", "操作", "sop", "guide", "how to"],
        "步骤": ["教程", "指南", "操作", "sop", "guide", "how to"],
        "指南": ["教程", "步骤", "操作", "sop", "guide", "how to"],
        "guide": ["教程", "步骤", "指南", "操作", "sop", "how to"],
        "字幕": ["转写", "caption", "captions", "transcript"],
        "转写": ["字幕", "caption", "captions", "transcript"],
        "caption": ["字幕", "转写", "captions", "transcript"],
        "transcript": ["字幕", "转写", "caption", "captions"],
        "音频": ["声音", "麦克风", "旁白", "audio", "voice"],
        "声音": ["音频", "麦克风", "旁白", "audio", "voice"],
        "audio": ["音频", "声音", "麦克风", "旁白", "voice"],
        "隐私": ["敏感", "脱敏", "遮挡", "privacy", "redact"],
        "敏感": ["隐私", "脱敏", "遮挡", "privacy", "redact"],
        "redact": ["隐私", "敏感", "脱敏", "遮挡", "privacy"]
    ]
    private static let intentAliasKeys = intentAliases.keys.sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0 < $1
    }

    public static func filter(
        _ entries: [LensLibraryEntry],
        query: String,
        filter: LensLibraryFilter
    ) -> [LensLibraryEntry] {
        let normalizedQuery = normalize(query)
        let tokens = queryTokens(normalizedQuery)
        let queryGroups = tokens.map { token in
            [token] + (intentAliases[token] ?? []).map(normalize)
        }

        let matches = entries.enumerated().compactMap { index, entry -> SearchMatch? in
            let kindMatches = switch filter {
            case .all: true
            case .screenshots: entry.manifest.kind == .screenshot
            case .recordings: entry.manifest.kind == .recording
            }
            guard kindMatches else { return nil }
            guard queryGroups.allSatisfy({ group in
                group.contains { entry.searchableText.localizedStandardContains($0) }
            })
            else { return nil }
            return SearchMatch(
                entry: entry,
                originalIndex: index,
                score: score(
                    entry: entry,
                    query: normalizedQuery,
                    queryGroups: queryGroups
                )
            )
        }

        // Keep the library's existing newest-first order for an empty query.
        // Once the user searches, surface the most intentional matches first:
        // an exact title hit beats a tag/summary hit, which beats a long OCR
        // or transcript hit. The original index remains the stable tie-breaker.
        return matches
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.originalIndex < $1.originalIndex
            }
            .map(\.entry)
    }

    public static func usesIntentExpansion(for query: String) -> Bool {
        let tokens = queryTokens(normalize(query))
        return tokens.contains { !(intentAliases[$0] ?? []).isEmpty }
    }

    private struct SearchMatch {
        let entry: LensLibraryEntry
        let originalIndex: Int
        let score: Int
    }

    private static func score(
        entry: LensLibraryEntry,
        query: String,
        queryGroups: [[String]]
    ) -> Int {
        guard !queryGroups.isEmpty else { return 0 }

        let title = normalize(entry.manifest.title)
        let ocr = normalize(entry.ocrText ?? "")
        let transcript = normalize(entry.transcriptText ?? "")
        let insights = entry.insights
        let tags = normalize(insights?.resolvedTags.joined(separator: " ") ?? "")
        let summary = normalize([
            insights?.resolvedSummary ?? "",
            insights?.keyPoints.joined(separator: " ") ?? "",
            insights?.chapters.map(\.title).joined(separator: " ") ?? ""
        ].joined(separator: " "))

        var result = 0
        if !query.isEmpty {
            if title == query { result += 120 }
            else if title.localizedStandardContains(query) { result += 72 }
            if tags.localizedStandardContains(query) { result += 42 }
        }
        for group in queryGroups {
            guard let term = group.first(where: { candidate in
                title.localizedStandardContains(candidate)
                    || tags.localizedStandardContains(candidate)
                    || summary.localizedStandardContains(candidate)
                    || ocr.localizedStandardContains(candidate)
                    || transcript.localizedStandardContains(candidate)
            }) else { continue }
            let isDirect = term == group[0]
            let titleExactWeight = isDirect ? 34 : 12
            let titleContainsWeight = isDirect ? 22 : 9
            let tagsWeight = isDirect ? 16 : 7
            let bodyWeight = isDirect ? 10 : 4
            if title == term { result += titleExactWeight }
            else if title.localizedStandardContains(term) { result += titleContainsWeight }
            if tags.localizedStandardContains(term) { result += tagsWeight }
            if summary.localizedStandardContains(term) { result += bodyWeight }
            if ocr.localizedStandardContains(term) { result += isDirect ? 7 : 3 }
            if transcript.localizedStandardContains(term) { result += isDirect ? 7 : 3 }
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()
    }

    /// Chinese users commonly enter intent phrases without spaces (for
    /// example, “视频教程”). Split only around known local intent terms and
    /// keep unknown runs intact; English phrases and ordinary unknown queries
    /// therefore retain their existing token semantics.
    private static func queryTokens(_ normalizedQuery: String) -> [String] {
        normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .flatMap { splitChineseIntentTerms(String($0)) }
    }

    private static func splitChineseIntentTerms(_ token: String) -> [String] {
        let characters = Array(token)
        guard characters.count > 1,
              characters.contains(where: isCJKCharacter),
              intentAliasKeys.contains(where: { token.contains($0) }) else {
            return [token]
        }

        var result: [String] = []
        var unknown = ""
        var index = 0
        while index < characters.count {
            let suffix = String(characters[index...])
            if let alias = intentAliasKeys.first(where: { suffix.hasPrefix($0) }) {
                if !unknown.isEmpty {
                    result.append(unknown)
                    unknown = ""
                }
                result.append(alias)
                index += Array(alias).count
            } else {
                unknown.append(characters[index])
                index += 1
            }
        }
        if !unknown.isEmpty { result.append(unknown) }
        return result.isEmpty ? [token] : result
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}
