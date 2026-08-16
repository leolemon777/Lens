import Foundation

public enum LocalTraceOrganizer {
    public static let engineIdentifier = "ScreenTraceLocalOrganizer/0.1"

    private struct TimedSourceText {
        let text: String
        let source: TraceInsightSource
        let startSeconds: Double?
        let endSeconds: Double?
    }

    private struct FindingKey: Hashable {
        let kind: TraceSensitiveDataKind
        let source: TraceInsightSource
        let redactedPreview: String
    }

    private struct FindingAggregate {
        var startSeconds: Double?
        var endSeconds: Double?
        var count: Int
    }

    public static func organize(
        manifest: TraceManifest,
        ocr: OCRDocument? = nil,
        transcript: TranscriptDocument? = nil,
        generatedAt: Date = Date(),
        tokenizer: TraceTokenizing = BigramTokenizer()
    ) -> TraceInsightsDocument {
        let rawTranscriptText = transcript.map {
            assembledTranscriptText(
                segments: $0.segments,
                localeIdentifier: $0.localeIdentifier
            )
        } ?? ""
        let transcriptText = privacyRedactedText(rawTranscriptText)
        let ocrText = privacyRedactedText(ocr?.fullText ?? "")
        let primaryText = !transcriptText.isEmpty ? transcriptText : ocrText
        let combinedText = [primaryText, ocrText == primaryText ? "" : ocrText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let sentenceList = sentences(in: primaryText)
        let summary = extractiveSummary(from: sentenceList, tokenizer: tokenizer)
        let keyPoints = salientSentences(sentenceList, tokenizer: tokenizer)
        let title = suggestedTitle(
            manifest: manifest,
            sentences: sentenceList,
            fallbackText: primaryText
        )
        let tags = suggestedTags(manifest: manifest, text: combinedText, tokenizer: tokenizer)
        let chapters = transcript.map {
            makeChapters(
                transcript: $0,
                durationSeconds: manifest.durationSeconds
            )
        } ?? []
        let sensitiveFindings = detectSensitiveData(
            manifest: manifest,
            ocr: ocr,
            transcript: transcript
        )

        return TraceInsightsDocument(
            engine: engineIdentifier,
            generatedAt: generatedAt,
            suggestedTitle: title,
            summary: summary,
            tags: tags,
            keyPoints: keyPoints,
            chapters: chapters,
            sensitiveFindings: sensitiveFindings
        )
    }

    private static func suggestedTitle(
        manifest: TraceManifest,
        sentences: [String],
        fallbackText: String
    ) -> String {
        let firstContent = sentences.first
            ?? normalizedWhitespace(fallbackText)
        var contentTitle = cleanTitle(firstContent)
        if contentTitle.isEmpty {
            contentTitle = cleanTitle(privacyRedactedText(
                manifest.captureSource?.windowTitle ?? ""
            ))
        }
        if contentTitle.isEmpty { return privacyRedactedText(manifest.title) }
        contentTitle = truncated(contentTitle, maximumCharacters: 32)
        let application = privacyRedactedText(
            manifest.captureSource?.applicationName ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !application.isEmpty,
              !contentTitle.localizedCaseInsensitiveContains(application) else {
            return contentTitle
        }
        return truncated("\(application) · \(contentTitle)", maximumCharacters: 46)
    }

    private struct RankedSentence {
        let index: Int
        let text: String
        let score: Double
    }

    /// Frequency-and-position ranking shared by the summary and the key points.
    /// Both read the same text, so letting the summary fall back to "the first
    /// two sentences" made it strictly weaker than the key points beside it.
    private static func rankedSentences(
        _ sentences: [String],
        minimumCharacters: Int,
        tokenizer: TraceTokenizing
    ) -> [RankedSentence] {
        let candidates = sentences.enumerated().compactMap { index, sentence -> (Int, String, [String])? in
            let sentence = normalizedWhitespace(sentence)
            guard sentence.count >= minimumCharacters else { return nil }
            return (index, sentence, semanticTokens(in: sentence, tokenizer: tokenizer))
        }
        guard !candidates.isEmpty else { return [] }
        var frequency: [String: Int] = [:]
        for candidate in candidates {
            for token in Set(candidate.2) { frequency[token, default: 0] += 1 }
        }
        return candidates.map { candidate in
            let tokenScore = candidate.2.reduce(0.0) {
                $0 + Double(frequency[$1, default: 0])
            } / Double(max(candidate.2.count, 1))
            let positionBonus = max(0, 0.8 - Double(candidate.0) * 0.08)
            return RankedSentence(
                index: candidate.0,
                text: candidate.1,
                score: tokenScore + positionBonus
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }
    }

    private static func extractiveSummary(
        from sentences: [String],
        tokenizer: TraceTokenizing
    ) -> String {
        guard !sentences.isEmpty else { return "" }
        let ranked = rankedSentences(sentences, minimumCharacters: 4, tokenizer: tokenizer)
            .prefix(2)
            .sorted { $0.index < $1.index }
        var selected: [String] = []
        var characterCount = 0
        for item in ranked {
            if !selected.isEmpty, characterCount + item.text.count > 220 { break }
            selected.append(item.text)
            characterCount += item.text.count
        }
        if selected.isEmpty {
            selected = [normalizedWhitespace(sentences[0])]
        }
        return truncated(selected.joined(separator: " "), maximumCharacters: 220)
    }

    private static func salientSentences(
        _ sentences: [String],
        tokenizer: TraceTokenizing
    ) -> [String] {
        rankedSentences(sentences, minimumCharacters: 6, tokenizer: tokenizer)
            .prefix(4)
            .sorted { $0.index < $1.index }
            .map { truncated($0.text, maximumCharacters: 140) }
    }

    private static func suggestedTags(
        manifest: TraceManifest,
        text: String,
        tokenizer: TraceTokenizing
    ) -> [String] {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var tags: [String] = []
        let application = privacyRedactedText(
            manifest.captureSource?.applicationName ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !application.isEmpty {
            tags.append(application)
        }

        let categories: [(String, [String])] = [
            ("开发", ["swift", "xcode", "github", "terminal", "api", "代码", "开发", "编程"]),
            ("设计", ["figma", "design", "ui", "ux", "设计", "交互", "视觉"]),
            ("会议", ["meeting", "agenda", "minutes", "会议", "讨论", "议程"]),
            ("产品", ["product", "roadmap", "launch", "产品", "需求", "规划", "发布"]),
            ("教程", ["tutorial", "guide", "demo", "教程", "演示", "步骤"]),
            ("文档", ["document", "notes", "report", "文档", "笔记", "报告"]),
            ("问题", ["error", "bug", "issue", "failed", "错误", "问题", "失败"])
        ]
        for category in categories where category.1.contains(where: normalized.contains) {
            tags.append(category.0)
        }

        var latinFrequency: [String: Int] = [:]
        for token in latinTokens(in: normalized) where !stopWords.contains(token) {
            guard token.count <= 24,
                  token.filter(\.isNumber).count <= 3,
                  !token.hasPrefix("sk-") else { continue }
            latinFrequency[token, default: 0] += 1
        }
        let priorityTokens = [
            "screentrace", "swift", "xcode", "github", "figma", "macos", "windows"
        ]
        for token in priorityTokens where latinFrequency[token] != nil {
            tags.append(displayTag(for: token))
        }
        for item in latinFrequency
            .filter({ !priorityTokens.contains($0.key) })
            .sorted(by: frequencyOrder)
            .prefix(4) {
            tags.append(displayTag(for: item.key))
        }

        var hanFrequency: [String: Int] = [:]
        for token in hanTokens(in: text, tokenizer: tokenizer) where !hanStopWords.contains(token) {
            hanFrequency[token, default: 0] += 1
        }
        let repeatedHan = hanFrequency
            .filter { $0.value >= 2 }
            .sorted(by: frequencyOrder)
        for item in repeatedHan.prefix(3) { tags.append(item.key) }

        if tags.count < 2 {
            tags.append(manifest.kind == .screenshot ? "截图" : "录屏")
        }
        return TraceInsightsDocument(
            engine: engineIdentifier,
            suggestedTitle: "",
            summary: "",
            tags: tags
        ).tags
    }

    private static func makeChapters(
        transcript: TranscriptDocument,
        durationSeconds: Double?
    ) -> [TraceChapter] {
        let segments = transcript.segments.filter { !$0.text.isEmpty }
        guard !segments.isEmpty else { return [] }
        var result: [TraceChapter] = []
        var current: [TranscriptSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = assembledTranscriptText(
                segments: current,
                localeIdentifier: transcript.localeIdentifier
            )
            let safeText = privacyRedactedText(text)
            result.append(TraceChapter(
                index: result.count,
                startSeconds: first.startSeconds,
                endSeconds: last.endSeconds,
                title: truncated(cleanTitle(safeText), maximumCharacters: 30),
                summary: truncated(normalizedWhitespace(safeText), maximumCharacters: 150)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for (index, segment) in segments.enumerated() {
            current.append(segment)
            guard let first = current.first else { continue }
            let elapsed = segment.endSeconds - first.startSeconds
            let nextGap = segments.indices.contains(index + 1)
                ? segments[index + 1].startSeconds - segment.endSeconds
                : 0
            let naturalBreak = endsSentence(segment.text) || nextGap >= 4
            if elapsed >= 90 || (elapsed >= 25 && naturalBreak) { flush() }
        }
        flush()

        if let duration = durationSeconds,
           duration.isFinite,
           let last = result.last,
           duration > last.endSeconds,
           duration - last.endSeconds <= 2 {
            result[result.count - 1] = TraceChapter(
                index: last.index,
                startSeconds: last.startSeconds,
                endSeconds: duration,
                title: last.title,
                summary: last.summary
            )
        }
        return result
    }

    private static func detectSensitiveData(
        manifest: TraceManifest,
        ocr: OCRDocument?,
        transcript: TranscriptDocument?
    ) -> [TraceSensitiveFinding] {
        var sources: [TimedSourceText] = [
            TimedSourceText(
                text: [
                    manifest.title,
                    manifest.captureSource?.windowTitle ?? "",
                    manifest.captureSource?.applicationName ?? ""
                ].joined(separator: "\n"),
                source: .metadata,
                startSeconds: nil,
                endSeconds: nil
            )
        ]
        if let ocr, !ocr.fullText.isEmpty {
            sources.append(TimedSourceText(
                text: ocr.fullText,
                source: .ocr,
                startSeconds: nil,
                endSeconds: nil
            ))
        }
        if let transcript {
            sources.append(contentsOf: transcript.segments.map {
                TimedSourceText(
                    text: $0.text,
                    source: .transcript,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds
                )
            })
        }

        var findings: [FindingKey: FindingAggregate] = [:]

        func record(
            kind: TraceSensitiveDataKind,
            value: String,
            source: TraceInsightSource,
            startSeconds: Double?,
            endSeconds: Double?
        ) {
            let preview = redacted(value, kind: kind)
            let key = FindingKey(
                kind: kind,
                source: source,
                redactedPreview: preview
            )
            if var aggregate = findings[key] {
                aggregate.count += 1
                findings[key] = aggregate
            } else {
                findings[key] = FindingAggregate(
                    startSeconds: startSeconds,
                    endSeconds: endSeconds,
                    count: 1
                )
            }
        }

        for source in sources where !source.text.isEmpty {
            for match in sensitiveMatches(in: source.text) {
                record(
                    kind: match.kind,
                    value: match.value,
                    source: source.source,
                    startSeconds: source.startSeconds,
                    endSeconds: source.endSeconds
                )
            }
        }

        if let transcript {
            let segments = transcript.segments
            for index in segments.indices.dropLast() {
                let first = segments[index]
                let second = segments[index + 1]
                let combined = first.text + second.text
                let boundary = (first.text as NSString).length
                for match in sensitiveMatches(in: combined) {
                    guard match.range.location < boundary,
                          NSMaxRange(match.range) > boundary else { continue }
                    let key = FindingKey(
                        kind: match.kind,
                        source: .transcript,
                        redactedPreview: redacted(match.value, kind: match.kind)
                    )
                    guard findings[key] == nil else { continue }
                    record(
                        kind: match.kind,
                        value: match.value,
                        source: .transcript,
                        startSeconds: first.startSeconds,
                        endSeconds: second.endSeconds
                    )
                }
            }
        }
        return findings.map { key, aggregate in
            TraceSensitiveFinding(
                kind: key.kind,
                source: key.source,
                startSeconds: aggregate.startSeconds,
                endSeconds: aggregate.endSeconds,
                redactedPreview: key.redactedPreview,
                occurrenceCount: aggregate.count
            )
        }.sorted {
            if $0.source.rawValue != $1.source.rawValue {
                return $0.source.rawValue < $1.source.rawValue
            }
            if ($0.startSeconds ?? -1) != ($1.startSeconds ?? -1) {
                return ($0.startSeconds ?? -1) < ($1.startSeconds ?? -1)
            }
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.redactedPreview < $1.redactedPreview
        }
    }

    private static func sensitiveMatches(
        in text: String
    ) -> [(kind: TraceSensitiveDataKind, value: String, range: NSRange)] {
        var occupied: [NSRange] = []
        var result: [(TraceSensitiveDataKind, String, NSRange)] = []

        func append(
            pattern: String,
            kind: TraceSensitiveDataKind,
            validation: ((String) -> Bool)? = nil
        ) {
            for match in regexMatches(pattern: pattern, text: text) {
                guard !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      validation?(match.value) != false else { continue }
                occupied.append(match.range)
                result.append((kind, match.value, match.range))
            }
        }

        append(
            pattern: #"(?i)\b(?:sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16})\b"#,
            kind: .credential
        )
        append(
            pattern: #"(?i)(?:api[_ -]?key|access[_ -]?token|secret|password|passwd|密码|口令)\s*[:=：]\s*[^\s,;，；]{6,}"#,
            kind: .credential
        )
        append(
            pattern: #"(?i)\b[A-Z0-9._%+-]+\s*@\s*[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            kind: .emailAddress
        )
        append(
            pattern: #"(?<!\d)\d{17}[\dXx](?!\d)"#,
            kind: .governmentIdentifier,
            validation: { passesIdentityCardChecksum($0) }
        )
        append(
            pattern: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#,
            kind: .paymentCard,
            validation: { value in
                let digits = value.filter(\.isNumber)
                return (13...19).contains(digits.count) && passesLuhn(digits)
            }
        )
        append(
            pattern: #"(?<!\d)(?:\+?\d[\d\s().-]{7,}\d)(?!\d)"#,
            kind: .phoneNumber,
            validation: { value in
                let digits = value.filter(\.isNumber)
                guard (10...15).contains(digits.count) else { return false }
                // A bare digit run is far more often a build number, an order id
                // or a concatenated timestamp than a phone number. Require either
                // an explicit international prefix, human separators, or a real
                // mainland mobile prefix before claiming it is a phone number.
                let hasInternationalPrefix = value.contains("+")
                let hasSeparators = value.contains(where: { " -().".contains($0) })
                let isMainlandMobile = digits.count == 11
                    && digits.first == "1"
                    && "3456789".contains(digits[digits.index(digits.startIndex, offsetBy: 1)])
                return hasInternationalPrefix || hasSeparators || isMainlandMobile
            }
        )
        return result
    }

    private static func privacyRedactedText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let matches = sensitiveMatches(in: text).sorted {
            $0.range.location > $1.range.location
        }
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches {
            mutable.replaceCharacters(
                in: match.range,
                with: redacted(match.value, kind: match.kind)
            )
        }
        return String(mutable)
    }

    private static func redacted(
        _ rawValue: String,
        kind: TraceSensitiveDataKind
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .emailAddress:
            let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "•••@redacted" }
            let local = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let domain = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(local.prefix(1))•••@\(domain)"
        case .phoneNumber, .paymentCard, .governmentIdentifier:
            let digits = value.filter { $0.isNumber || $0 == "X" || $0 == "x" }
            return "•••• \(digits.suffix(4))"
        case .credential:
            if let separator = value.firstIndex(where: { ":=：".contains($0) }) {
                let label = value[..<separator]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(label): ••••"
            }
            return "\(value.prefix(3))••••\(value.suffix(2))"
        }
    }

    private static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        let values = digits.compactMap(\.wholeNumberValue).reversed()
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 2) {
                sum += value
            } else {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum > 0 && sum.isMultiple(of: 10)
    }

    /// ISO 7064 MOD 11-2, the checksum carried by an 18-digit mainland identity
    /// card. Without it every eighteen-digit order number or timestamp run gets
    /// reported, and a panel full of false positives is one users stop reading.
    private static func passesIdentityCardChecksum(_ rawValue: String) -> Bool {
        let digits = Array(rawValue.uppercased())
        guard digits.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checkCharacters = Array("10X98765432")
        var sum = 0
        for (weight, character) in zip(weights, digits.prefix(17)) {
            guard let value = character.wholeNumberValue else { return false }
            sum += weight * value
        }
        return checkCharacters[sum % 11] == digits[17]
    }

    private static func sentences(in text: String) -> [String] {
        var current = ""
        var result: [String] = []
        let terminators = CharacterSet(charactersIn: ".!?。！？\n\r")
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let sentence = normalizedWhitespace(current)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let remainder = normalizedWhitespace(current)
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }

    private static func semanticTokens(
        in text: String,
        tokenizer: TraceTokenizing
    ) -> [String] {
        latinTokens(in: text.lowercased()) + hanTokens(in: text, tokenizer: tokenizer)
    }

    private static func latinTokens(in text: String) -> [String] {
        regexMatches(pattern: #"[A-Za-z][A-Za-z0-9+#-]{2,}"#, text: text)
            .map { $0.value.lowercased() }
    }

    private static func hanTokens(
        in text: String,
        tokenizer: TraceTokenizing
    ) -> [String] {
        tokenizer.words(in: text)
    }

    private static func regexMatches(
        pattern: String,
        text: String
    ) -> [(range: NSRange, value: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return (match.range, String(text[swiftRange]))
        }
    }

    private static func assembledTranscriptText(
        segments: [TranscriptSegment],
        localeIdentifier: String
    ) -> String {
        let language = localeIdentifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        let compact = language == "zh" || language == "ja"
        let punctuation = CharacterSet.punctuationCharacters
        return segments.reduce(into: "") { result, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let beginsWithPunctuation = text.unicodeScalars.first
                .map(punctuation.contains) == true
            if result.isEmpty || compact || beginsWithPunctuation {
                result += text
            } else {
                result += " " + text
            }
        }
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func cleanTitle(_ text: String) -> String {
        normalizedWhitespace(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".!?。！？,;，；:-—")
            ))
    }

    private static func truncated(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(max(maximumCharacters - 1, 1))) + "…"
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".?!。！？…".contains(last)
    }

    private static func frequencyOrder(
        _ lhs: (key: String, value: Int),
        _ rhs: (key: String, value: Int)
    ) -> Bool {
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
    }

    private static func displayTag(for token: String) -> String {
        switch token {
        case "github": "GitHub"
        case "figma": "Figma"
        case "swift": "Swift"
        case "xcode": "Xcode"
        case "screentrace": "ScreenTrace"
        case "macos": "macOS"
        case "windows": "Windows"
        default: token
        }
    }

    private static let stopWords: Set<String> = [
        "about", "after", "also", "and", "are", "because", "been", "before",
        "but", "can", "for", "from", "have", "into", "just", "more", "not",
        "our", "that", "the", "their", "then", "there", "this", "through",
        "using", "was", "were", "what", "when", "where", "which", "will", "with",
        "you", "your"
    ]

    private static let hanStopWords: Set<String> = [
        "一个", "一些", "不是", "不会", "为什", "主要", "也是", "了一",
        "什么", "今天", "他们", "你们", "其实", "可以", "因为", "就是",
        "我们", "所以", "然后", "现在", "这个", "这些", "这样", "那个"
    ]
}
