import Foundation

public struct CaptionSourceCue: Codable, Equatable, Sendable {
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var text: String

    public init(
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        text: String
    ) {
        let start = sourceStartSeconds.isFinite ? max(sourceStartSeconds, 0) : 0
        let end = sourceEndSeconds.isFinite ? max(sourceEndSeconds, start) : start
        self.sourceStartSeconds = start
        self.sourceEndSeconds = end
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CaptionCue: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        let start = startSeconds.isFinite ? max(startSeconds, 0) : 0
        let end = endSeconds.isFinite ? max(endSeconds, start) : start
        self.startSeconds = start
        self.endSeconds = end
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Character progress through the cue at `seconds`, clamped to the cue
    /// span. Word timings are interpolated linearly because transcripts only
    /// carry segment-level timestamps.
    public func spokenCharacterFraction(at seconds: Double) -> Double {
        guard endSeconds > startSeconds else { return 0 }
        let clamped = min(max(seconds, startSeconds), endSeconds)
        return (clamped - startSeconds) / (endSeconds - startSeconds)
    }

    /// Index into `CaptionWordSegmenter.words(in:)` for the word being spoken
    /// at `seconds`. Returns nil when the cue carries no words.
    public func spokenWordIndex(at seconds: Double) -> Int? {
        let words = CaptionWordSegmenter.words(in: text)
        guard !words.isEmpty else { return nil }
        let characters = Array(text)
        let progress = spokenCharacterFraction(at: seconds)
            * Double(characters.count)
        for (index, word) in words.enumerated() {
            let end = Double(word.offset + word.text.count)
            if progress < end || index == words.count - 1 {
                return index
            }
        }
        return nil
    }
}

/// Splits caption text into highlightable words: one CJK character per word
/// (matching how karaoke captions behave in Chinese) and whole latin words.
public enum CaptionWordSegmenter {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let offset: Int

        public init(text: String, offset: Int) {
            self.text = text
            self.offset = offset
        }
    }

    public static func words(in text: String) -> [Word] {
        let characters = Array(text)
        var result: [Word] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isCJKTextCharacter {
                result.append(Word(text: String(character), offset: index))
                index += 1
            } else if character.isLetter {
                var word = ""
                let offset = index
                while index < characters.count,
                      characters[index].isLetter,
                      characters[index].isCJKTextCharacter == false {
                    word.append(characters[index])
                    index += 1
                }
                result.append(Word(text: word, offset: offset))
            } else {
                index += 1
            }
        }
        return result
    }
}

extension Character {
    /// CJK ideographs and the CJK-adjacent symbol ranges, shared by the
    /// filler-word planner and the caption word segmenter.
    var isCJKTextCharacter: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2EFF, 0x3000...0x303F, 0x31C0...0x31EF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}

public enum CaptionCuePlanner {
    private struct TimedText {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
        let group: Int
    }

    /// Returns the source-time cues shown in the editor. Custom cues are kept,
    /// including empty (hidden) entries, so an edit can always be restored.
    public static func sourceCues(
        transcript: TranscriptDocument,
        configuration: AutoEditPlan.Captions
    ) -> [CaptionSourceCue] {
        if let customCues = configuration.customCues {
            return customCues.sorted {
                if $0.sourceStartSeconds != $1.sourceStartSeconds {
                    return $0.sourceStartSeconds < $1.sourceStartSeconds
                }
                return $0.sourceEndSeconds < $1.sourceEndSeconds
            }
        }
        let timed = transcript.segments.map {
            TimedText(
                startSeconds: $0.startSeconds,
                endSeconds: $0.endSeconds,
                text: $0.text,
                group: 0
            )
        }
        return grouped(
            timed,
            localeIdentifier: transcript.localeIdentifier,
            maximumCharacters: configuration.maxCharactersPerCue
        ).map {
            CaptionSourceCue(
                sourceStartSeconds: $0.startSeconds,
                sourceEndSeconds: $0.endSeconds,
                text: $0.text
            )
        }
    }

    /// Maps source-time speech into the edited output timeline before grouping.
    /// This keeps captions synchronized across trims, cuts, reordering and speed.
    public static func cues(
        transcript: TranscriptDocument,
        configuration: AutoEditPlan.Captions,
        timeline: VideoEditTimeline? = nil
    ) -> [CaptionCue] {
        guard configuration.isEnabled else { return [] }
        let sourceItems: [TimedText]
        let itemsAreAlreadyGrouped: Bool
        if let customCues = configuration.customCues {
            sourceItems = customCues.compactMap { cue in
                guard !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return TimedText(
                    startSeconds: cue.sourceStartSeconds,
                    endSeconds: cue.sourceEndSeconds,
                    text: cue.text,
                    group: 0
                )
            }
            itemsAreAlreadyGrouped = true
        } else {
            sourceItems = transcript.segments.map {
                TimedText(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: $0.text,
                    group: 0
                )
            }
            itemsAreAlreadyGrouped = false
        }

        let mapped = mapToOutputTimeline(sourceItems, timeline: timeline)
        if itemsAreAlreadyGrouped {
            return mapped.map {
                CaptionCue(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: $0.text
                )
            }
        }
        return grouped(
            mapped,
            localeIdentifier: transcript.localeIdentifier,
            maximumCharacters: configuration.maxCharactersPerCue
        )
    }

    public static func activeCue(at seconds: Double, in cues: [CaptionCue]) -> CaptionCue? {
        guard seconds.isFinite, !cues.isEmpty else { return nil }
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].startSeconds <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let cue = cues[lower - 1]
        return seconds >= cue.startSeconds && seconds < cue.endSeconds ? cue : nil
    }

    /// Seek-safe lead-in and release used by overlays that need to move before
    /// a caption appears and settle after it disappears.
    public static func avoidanceAmount(
        at seconds: Double,
        in cues: [CaptionCue],
        transitionDuration: Double = 0.22
    ) -> Double {
        guard seconds.isFinite, !cues.isEmpty else { return 0 }
        let duration = max(transitionDuration.isFinite ? transitionDuration : 0.22, 0.01)
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].startSeconds <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        func amount(for cue: CaptionCue) -> Double {
            let lead = min(max(
                (seconds - (cue.startSeconds - duration)) / duration,
                0
            ), 1)
            let release = min(max(
                ((cue.endSeconds + duration) - seconds) / duration,
                0
            ), 1)
            return min(lead, release)
        }
        let previousAmount = lower > 0 ? amount(for: cues[lower - 1]) : 0
        let upcomingAmount = lower < cues.count ? amount(for: cues[lower]) : 0
        return max(previousAmount, upcomingAmount)
    }

    private static func mapToOutputTimeline(
        _ sourceItems: [TimedText],
        timeline: VideoEditTimeline?
    ) -> [TimedText] {
        let orderedItems = sourceItems
            .filter { !$0.text.isEmpty && $0.endSeconds >= $0.startSeconds }
            .sorted {
                if $0.startSeconds != $1.startSeconds {
                    return $0.startSeconds < $1.startSeconds
                }
                return $0.endSeconds < $1.endSeconds
            }
        guard let timeline else { return orderedItems }

        var outputCursor = 0.0
        var mapped: [TimedText] = []
        for (group, segment) in timeline.activeSegments.enumerated() {
            for item in orderedItems {
                let midpoint = item.startSeconds
                    + max(item.endSeconds - item.startSeconds, 0) / 2
                guard midpoint >= segment.sourceStartSeconds,
                      midpoint < segment.sourceEndSeconds else { continue }
                let overlapStart = max(item.startSeconds, segment.sourceStartSeconds)
                let overlapEnd = min(item.endSeconds, segment.sourceEndSeconds)
                guard overlapEnd >= overlapStart else { continue }
                let outputStart = outputCursor
                    + (overlapStart - segment.sourceStartSeconds) / segment.playbackRate
                let outputEnd = outputCursor
                    + (overlapEnd - segment.sourceStartSeconds) / segment.playbackRate
                let segmentOutputEnd = outputCursor + segment.outputDurationSeconds
                mapped.append(TimedText(
                    startSeconds: outputStart,
                    endSeconds: min(
                        max(outputEnd, outputStart + 0.08),
                        segmentOutputEnd
                    ),
                    text: item.text,
                    group: group
                ))
            }
            outputCursor += segment.outputDurationSeconds
        }
        return mapped.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.endSeconds < $1.endSeconds
        }
    }

    private static func grouped(
        _ items: [TimedText],
        localeIdentifier: String,
        maximumCharacters: Int
    ) -> [CaptionCue] {
        let maximumCharacters = min(max(maximumCharacters, 8), 64)
        let maximumDuration = 3.8
        let maximumGap = 0.65
        var cues: [CaptionCue] = []
        var current: [TimedText] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = assembledText(current.map(\.text), localeIdentifier: localeIdentifier)
            if !text.isEmpty {
                cues.append(CaptionCue(
                    startSeconds: first.startSeconds,
                    endSeconds: max(last.endSeconds, first.startSeconds + 0.08),
                    text: text
                ))
            }
            current.removeAll(keepingCapacity: true)
        }

        for item in items where !item.text.isEmpty {
            if let first = current.first, let last = current.last {
                let candidate = assembledText(
                    current.map(\.text) + [item.text],
                    localeIdentifier: localeIdentifier
                )
                let startsNewCue = item.group != last.group
                    || item.startSeconds - last.endSeconds > maximumGap
                    || item.endSeconds - first.startSeconds > maximumDuration
                    || candidate.count > maximumCharacters
                if startsNewCue { flush() }
            }
            current.append(item)
            if endsSentence(item.text) { flush() }
        }
        flush()
        return cues
    }

    private static func assembledText(
        _ parts: [String],
        localeIdentifier: String
    ) -> String {
        let language = localeIdentifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        let usesCompactSpacing = language == "zh" || language == "ja"
        let punctuation = CharacterSet.punctuationCharacters
        return parts.reduce(into: "") { result, rawPart in
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { return }
            let beginsWithPunctuation = part.unicodeScalars.first
                .map(punctuation.contains) == true
            let followsOpeningMark = result.last.map { "([{“‘《〈【".contains($0) } == true
            if result.isEmpty || usesCompactSpacing || beginsWithPunctuation || followsOpeningMark {
                result += part
            } else {
                result += " " + part
            }
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".?!。！？…".contains(last)
    }
}
