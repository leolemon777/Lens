import Foundation

/// Deterministic source-time subtitle edits shared by the macOS editor and
/// future platform front ends. Original transcript segments are never mutated.
public enum CaptionCueEditor {
    public static let minimumDurationSeconds = 0.08

    public static func normalized(
        _ cues: [CaptionSourceCue],
        sourceDurationSeconds: Double
    ) -> [CaptionSourceCue] {
        let duration = max(
            sourceDurationSeconds.isFinite ? sourceDurationSeconds : 0,
            0
        )
        guard duration >= minimumDurationSeconds else { return [] }
        return cues.compactMap { cue in
            var start = min(max(
                cue.sourceStartSeconds.isFinite ? cue.sourceStartSeconds : 0,
                0
            ), duration)
            var end = min(max(
                cue.sourceEndSeconds.isFinite ? cue.sourceEndSeconds : start,
                start
            ), duration)
            if end - start < minimumDurationSeconds {
                end = min(start + minimumDurationSeconds, duration)
                start = max(min(start, end - minimumDurationSeconds), 0)
            }
            guard end - start >= minimumDurationSeconds else { return nil }
            return CaptionSourceCue(
                sourceStartSeconds: start,
                sourceEndSeconds: end,
                text: cue.text
            )
        }.sorted(by: sourceOrder)
    }

    public static func retimed(
        _ cues: [CaptionSourceCue],
        at index: Int,
        sourceStartSeconds requestedStart: Double? = nil,
        sourceEndSeconds requestedEnd: Double? = nil,
        sourceDurationSeconds: Double
    ) -> [CaptionSourceCue]? {
        guard cues.indices.contains(index) else { return nil }
        let duration = max(
            sourceDurationSeconds.isFinite ? sourceDurationSeconds : 0,
            0
        )
        var result = cues
        let cue = result[index]
        let lowerBound = index > 0 ? result[index - 1].sourceEndSeconds : 0
        let upperBound = index + 1 < result.count
            ? result[index + 1].sourceStartSeconds
            : duration
        guard upperBound - lowerBound >= minimumDurationSeconds else { return nil }
        var start = cue.sourceStartSeconds
        var end = cue.sourceEndSeconds
        if let requestedStart, requestedStart.isFinite {
            start = min(max(requestedStart, lowerBound), end - minimumDurationSeconds)
        }
        if let requestedEnd, requestedEnd.isFinite {
            end = max(min(requestedEnd, upperBound), start + minimumDurationSeconds)
        }
        guard end <= duration + 0.000_001 else { return nil }
        result[index] = CaptionSourceCue(
            sourceStartSeconds: start,
            sourceEndSeconds: end,
            text: cue.text
        )
        return result
    }

    public static func split(
        _ cues: [CaptionSourceCue],
        at index: Int,
        sourceTimeSeconds: Double
    ) -> [CaptionSourceCue]? {
        guard cues.indices.contains(index), sourceTimeSeconds.isFinite else { return nil }
        let cue = cues[index]
        guard sourceTimeSeconds - cue.sourceStartSeconds >= minimumDurationSeconds,
              cue.sourceEndSeconds - sourceTimeSeconds >= minimumDurationSeconds else {
            return nil
        }
        let characters = Array(cue.text)
        guard characters.count >= 2 else { return nil }
        let ratio = (sourceTimeSeconds - cue.sourceStartSeconds)
            / max(cue.sourceEndSeconds - cue.sourceStartSeconds, minimumDurationSeconds)
        let target = min(max(Int((Double(characters.count) * ratio).rounded()), 1), characters.count - 1)
        let boundary = bestTextBoundary(in: characters, near: target)
        let leading = String(characters[..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = String(characters[boundary...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leading.isEmpty, !trailing.isEmpty else { return nil }

        var result = cues
        result.replaceSubrange(index...index, with: [
            CaptionSourceCue(
                sourceStartSeconds: cue.sourceStartSeconds,
                sourceEndSeconds: sourceTimeSeconds,
                text: leading
            ),
            CaptionSourceCue(
                sourceStartSeconds: sourceTimeSeconds,
                sourceEndSeconds: cue.sourceEndSeconds,
                text: trailing
            )
        ])
        return result
    }

    public static func mergedWithNext(
        _ cues: [CaptionSourceCue],
        at index: Int,
        localeIdentifier: String
    ) -> [CaptionSourceCue]? {
        guard cues.indices.contains(index), cues.indices.contains(index + 1) else { return nil }
        let first = cues[index]
        let second = cues[index + 1]
        let text = joinedText(
            first.text,
            second.text,
            localeIdentifier: localeIdentifier
        )
        guard !text.isEmpty else { return nil }
        var result = cues
        result.replaceSubrange(index...(index + 1), with: [CaptionSourceCue(
            sourceStartSeconds: min(first.sourceStartSeconds, second.sourceStartSeconds),
            sourceEndSeconds: max(first.sourceEndSeconds, second.sourceEndSeconds),
            text: text
        )])
        return result
    }

    private static func bestTextBoundary(
        in characters: [Character],
        near target: Int
    ) -> Int {
        let punctuation = CharacterSet.punctuationCharacters
        let whitespace = CharacterSet.whitespacesAndNewlines
        return (1..<characters.count).min { lhs, rhs in
            boundaryScore(
                lhs,
                characters: characters,
                target: target,
                punctuation: punctuation,
                whitespace: whitespace
            ) < boundaryScore(
                rhs,
                characters: characters,
                target: target,
                punctuation: punctuation,
                whitespace: whitespace
            )
        } ?? target
    }

    private static func boundaryScore(
        _ position: Int,
        characters: [Character],
        target: Int,
        punctuation: CharacterSet,
        whitespace: CharacterSet
    ) -> Int {
        let previous = characters[position - 1]
        let next = characters[position]
        let isNatural = previous.unicodeScalars.contains(where: {
            punctuation.contains($0) || whitespace.contains($0)
        }) || next.unicodeScalars.contains(where: whitespace.contains)
        return abs(position - target) * 3 + (isNatural ? 0 : 2)
    }

    private static func joinedText(
        _ leading: String,
        _ trailing: String,
        localeIdentifier: String
    ) -> String {
        let first = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        let language = localeIdentifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        let compact = language == "zh" || language == "ja"
        let beginsWithPunctuation = second.unicodeScalars.first
            .map(CharacterSet.punctuationCharacters.contains) == true
        return first + (compact || beginsWithPunctuation ? "" : " ") + second
    }

    private static func sourceOrder(_ lhs: CaptionSourceCue, _ rhs: CaptionSourceCue) -> Bool {
        if lhs.sourceStartSeconds != rhs.sourceStartSeconds {
            return lhs.sourceStartSeconds < rhs.sourceStartSeconds
        }
        return lhs.sourceEndSeconds < rhs.sourceEndSeconds
    }
}
