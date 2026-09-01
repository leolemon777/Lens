import Foundation

/// A single reviewable narration-cleanup proposal. Suggestions never modify
/// media on their own: accepting one removes its source range from the edit
/// timeline, and rejecting one only records the dismissal.
public struct NarrationTrimSuggestion: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A pause between two speech spans, keeping padding on both edges.
        case silence
        /// A transcribed filler particle such as "嗯" or "um".
        case fillerWord
        /// Dead air recorded before the first spoken word.
        case openingBuffer
        /// Dead air recorded after the last spoken word.
        case closingBuffer
    }

    public enum Status: String, Codable, CaseIterable, Sendable {
        case pending
        case accepted
        case rejected
    }

    public let id: UUID
    public let kind: Kind
    public let startSeconds: Double
    public let endSeconds: Double
    /// For filler words this carries the recognized particle text.
    public let label: String?
    public var status: Status

    public init(
        id: UUID = UUID(),
        kind: Kind,
        startSeconds: Double,
        endSeconds: Double,
        label: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.kind = kind
        let start = startSeconds.isFinite ? max(startSeconds, 0) : 0
        self.startSeconds = start
        self.endSeconds = endSeconds.isFinite ? max(endSeconds, start) : start
        self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.status = status
    }

    public var durationSeconds: Double {
        endSeconds - startSeconds
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Converts narration activity spans plus an optional transcript into
/// silence, filler-word, and buffer trim suggestions.
public struct NarrationTrimPlanner: Sendable {
    public struct Span: Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double

        public init(startSeconds: Double, endSeconds: Double) {
            let start = startSeconds.isFinite ? max(startSeconds, 0) : 0
            self.startSeconds = start
            self.endSeconds = endSeconds.isFinite ? max(endSeconds, start) : start
        }
    }

    public struct Configuration: Equatable, Sendable {
        /// An interior pause must be at least this long (after padding) to be
        /// worth suggesting.
        public var minimumSilenceSeconds: Double
        /// Breathing room kept on both edges of a removed pause so cuts do
        /// not clip speech onsets.
        public var silencePaddingSeconds: Double
        public var minimumOpeningBufferSeconds: Double
        /// Speech keeps this much lead-in before the first word.
        public var openingBufferLeadSeconds: Double
        public var minimumClosingBufferSeconds: Double
        /// Speech keeps this much tail after the last word.
        public var closingBufferTailKeepSeconds: Double
        public var minimumSilenceTrimSeconds: Double
        public var minimumFillerTrimSeconds: Double
        public var fillerPaddingSeconds: Double
        public var maximumSuggestionCount: Int
        /// Chinese entries match per character ("嗯"); Latin entries match
        /// whole lowercased words ("um").
        public var fillerLexicon: Set<String>

        public init(
            minimumSilenceSeconds: Double = 0.6,
            silencePaddingSeconds: Double = 0.18,
            minimumOpeningBufferSeconds: Double = 0.8,
            openingBufferLeadSeconds: Double = 0.35,
            minimumClosingBufferSeconds: Double = 1.2,
            closingBufferTailKeepSeconds: Double = 0.6,
            minimumSilenceTrimSeconds: Double = 0.3,
            minimumFillerTrimSeconds: Double = 0.12,
            fillerPaddingSeconds: Double = 0.06,
            maximumSuggestionCount: Int = 400,
            fillerLexicon: Set<String> = NarrationTrimPlanner.defaultFillerLexicon
        ) {
            self.minimumSilenceSeconds = max(minimumSilenceSeconds, 0)
            self.silencePaddingSeconds = max(silencePaddingSeconds, 0)
            self.minimumOpeningBufferSeconds = max(minimumOpeningBufferSeconds, 0)
            self.openingBufferLeadSeconds = max(openingBufferLeadSeconds, 0)
            self.minimumClosingBufferSeconds = max(minimumClosingBufferSeconds, 0)
            self.closingBufferTailKeepSeconds = max(closingBufferTailKeepSeconds, 0)
            self.minimumSilenceTrimSeconds = max(minimumSilenceTrimSeconds, 0)
            self.minimumFillerTrimSeconds = max(minimumFillerTrimSeconds, 0)
            self.fillerPaddingSeconds = max(fillerPaddingSeconds, 0)
            self.maximumSuggestionCount = max(maximumSuggestionCount, 1)
            self.fillerLexicon = fillerLexicon
        }
    }

    /// Conservative v1 lexicon: standalone particles only. Discourse markers
    /// like "然后"/"like" stay out because removing them mid-sentence reads
    /// as a jump rather than a cleanup.
    public static let defaultFillerLexicon: Set<String> = [
        "嗯", "啊", "呃", "哦", "唉", "哎", "欸", "唔", "呣",
        "um", "uh", "umm", "uhh", "erm", "hmm", "mmm", "er"
    ]

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func suggestions(
        narrationRanges: [Span],
        transcript: TranscriptDocument?,
        durationSeconds: Double
    ) -> [NarrationTrimSuggestion] {
        let duration = durationSeconds.isFinite ? max(durationSeconds, 0) : 0
        let spans = Self.merged(narrationRanges, limitedTo: duration)
        guard !spans.isEmpty else { return [] }

        var results: [NarrationTrimSuggestion] = []
        let configuration = self.configuration

        let speechStart = spans.first?.startSeconds ?? 0
        let openingEnd = speechStart - configuration.openingBufferLeadSeconds
        if openingEnd >= configuration.minimumOpeningBufferSeconds {
            results.append(NarrationTrimSuggestion(
                kind: .openingBuffer,
                startSeconds: 0,
                endSeconds: openingEnd
            ))
        }

        let speechEnd = spans.last?.endSeconds ?? duration
        let closingStart = speechEnd + configuration.closingBufferTailKeepSeconds
        if duration - closingStart >= configuration.minimumClosingBufferSeconds {
            results.append(NarrationTrimSuggestion(
                kind: .closingBuffer,
                startSeconds: closingStart,
                endSeconds: duration
            ))
        }

        for (previous, next) in zip(spans, spans.dropFirst()) {
            let candidateStart = previous.endSeconds + configuration.silencePaddingSeconds
            let candidateEnd = next.startSeconds - configuration.silencePaddingSeconds
            guard candidateEnd - candidateStart >= configuration.minimumSilenceSeconds,
                  candidateEnd - candidateStart >= configuration.minimumSilenceTrimSeconds
            else { continue }
            results.append(NarrationTrimSuggestion(
                kind: .silence,
                startSeconds: candidateStart,
                endSeconds: candidateEnd
            ))
        }

        results.append(contentsOf: fillerSuggestions(
            transcript: transcript,
            durationSeconds: duration,
            avoiding: results
        ))

        var accepted = results.sorted { $0.startSeconds < $1.startSeconds }
        if accepted.count > configuration.maximumSuggestionCount {
            accepted = Array(
                accepted
                    .sorted { $0.durationSeconds > $1.durationSeconds }
                    .prefix(configuration.maximumSuggestionCount)
            ).sorted { $0.startSeconds < $1.startSeconds }
        }
        return accepted
    }

    private func fillerSuggestions(
        transcript: TranscriptDocument?,
        durationSeconds: Double,
        avoiding protected: [NarrationTrimSuggestion]
    ) -> [NarrationTrimSuggestion] {
        guard configuration.fillerLexicon.isEmpty == false,
              let transcript else { return [] }
        var results: [NarrationTrimSuggestion] = []
        for segment in transcript.segments {
            let characters = Array(segment.text)
            let total = max(characters.count, 1)
            for token in Self.tokens(in: characters) {
                guard configuration.fillerLexicon.contains(token.text) else { continue }
                let start = segment.startSeconds
                    + Double(token.offset) / Double(total)
                        * (segment.endSeconds - segment.startSeconds)
                let end = segment.startSeconds
                    + Double(token.offset + token.text.count) / Double(total)
                        * (segment.endSeconds - segment.startSeconds)
                let span = NarrationTrimSuggestion(
                    kind: .fillerWord,
                    startSeconds: max(0, start - configuration.fillerPaddingSeconds),
                    endSeconds: min(
                        durationSeconds,
                        end + configuration.fillerPaddingSeconds
                    ),
                    label: token.text
                )
                guard span.durationSeconds >= configuration.minimumFillerTrimSeconds,
                      !protected.contains(where: {
                          $0.startSeconds < span.endSeconds
                              && span.startSeconds < $0.endSeconds
                      }) else { continue }
                results.append(span)
            }
        }
        return results
    }

    /// A token is one CJK character or a maximal run of latin letters, so the
    /// same lexicon serves zh particles and English fillers.
    private static func tokens(in characters: [Character]) -> [(text: String, offset: Int)] {
        var tokens: [(String, Int)] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isCJKTextCharacter {
                tokens.append((String(character), index))
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
                tokens.append((word.lowercased(), offset))
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func merged(_ spans: [Span], limitedTo duration: Double) -> [Span] {
        var clipped: [Span] = []
        for span in spans {
            let candidate = Span(
                startSeconds: span.startSeconds,
                endSeconds: min(span.endSeconds, duration)
            )
            if candidate.endSeconds > candidate.startSeconds {
                clipped.append(candidate)
            }
        }
        clipped.sort { lhs, rhs in
            lhs.startSeconds == rhs.startSeconds
                ? lhs.endSeconds < rhs.endSeconds
                : lhs.startSeconds < rhs.startSeconds
        }
        guard var current = clipped.first else { return [] }
        var merged: [Span] = []
        for span in clipped.dropFirst() {
            if span.startSeconds <= current.endSeconds {
                current = Span(
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, span.endSeconds)
                )
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }
}
