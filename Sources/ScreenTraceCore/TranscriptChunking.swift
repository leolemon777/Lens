import Foundation

public struct TranscriptChunk: Codable, Equatable, Sendable {
    public let index: Int
    public let sourceStartSeconds: Double
    public let sourceEndSeconds: Double
    public let acceptedStartSeconds: Double
    public let acceptedEndSeconds: Double

    public init(
        index: Int,
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        acceptedStartSeconds: Double,
        acceptedEndSeconds: Double
    ) {
        let sourceStart = sourceStartSeconds.isFinite ? max(sourceStartSeconds, 0) : 0
        let sourceEnd = sourceEndSeconds.isFinite
            ? max(sourceEndSeconds, sourceStart)
            : sourceStart
        self.index = max(index, 0)
        self.sourceStartSeconds = sourceStart
        self.sourceEndSeconds = sourceEnd
        self.acceptedStartSeconds = min(
            max(acceptedStartSeconds.isFinite ? acceptedStartSeconds : sourceStart, sourceStart),
            sourceEnd
        )
        self.acceptedEndSeconds = min(
            max(acceptedEndSeconds.isFinite ? acceptedEndSeconds : sourceEnd, sourceStart),
            sourceEnd
        )
    }

    public var sourceDurationSeconds: Double {
        max(sourceEndSeconds - sourceStartSeconds, 0)
    }
}

public enum TranscriptChunkPlanner {
    public static func plan(
        durationSeconds: Double,
        maximumChunkDurationSeconds: Double = 50,
        overlapSeconds: Double = 1
    ) -> [TranscriptChunk] {
        let duration = durationSeconds.isFinite ? max(durationSeconds, 0) : 0
        guard duration >= VideoEditTimeline.minimumSegmentDurationSeconds else { return [] }
        let maximum = min(max(
            maximumChunkDurationSeconds.isFinite ? maximumChunkDurationSeconds : 50,
            5
        ), 60)
        let requestedOverlap = overlapSeconds.isFinite ? overlapSeconds : 1
        let overlap = min(max(requestedOverlap, 0), maximum * 0.25)
        var chunks: [TranscriptChunk] = []
        var sourceStart = 0.0

        while sourceStart < duration {
            let sourceEnd = min(sourceStart + maximum, duration)
            let isFirst = chunks.isEmpty
            let isLast = sourceEnd >= duration - 0.000_001
            chunks.append(TranscriptChunk(
                index: chunks.count,
                sourceStartSeconds: sourceStart,
                sourceEndSeconds: sourceEnd,
                acceptedStartSeconds: isFirst ? sourceStart : sourceStart + overlap / 2,
                acceptedEndSeconds: isLast ? sourceEnd : sourceEnd - overlap / 2
            ))
            if isLast { break }
            let nextStart = sourceEnd - overlap
            sourceStart = nextStart > sourceStart + 0.000_001 ? nextStart : sourceEnd
        }
        return chunks
    }
}

public struct TranscriptChunkDocument: Equatable, Sendable {
    public let chunk: TranscriptChunk
    public let document: TranscriptDocument

    public init(chunk: TranscriptChunk, document: TranscriptDocument) {
        self.chunk = chunk
        self.document = document
    }
}

public enum TranscriptChunkMerger {
    public static func merge(
        _ chunkDocuments: [TranscriptChunkDocument],
        engine: String,
        generatedAt: Date = Date(),
        localeIdentifier: String,
        isOnDevice: Bool,
        sourceRole: TraceAsset.Role
    ) -> TranscriptDocument {
        let ordered = chunkDocuments.sorted { $0.chunk.index < $1.chunk.index }
        var mergedSegments: [TranscriptSegment] = []
        for (documentIndex, item) in ordered.enumerated() {
            let includesUpperBoundary = documentIndex == ordered.count - 1
            for segment in item.document.segments {
                let start = item.chunk.sourceStartSeconds + segment.startSeconds
                let end = min(
                    item.chunk.sourceStartSeconds + segment.endSeconds,
                    item.chunk.sourceEndSeconds
                )
                let midpoint = start + max(end - start, 0) / 2
                let isAfterLowerBoundary = midpoint >= item.chunk.acceptedStartSeconds
                let isBeforeUpperBoundary = includesUpperBoundary
                    ? midpoint <= item.chunk.acceptedEndSeconds
                    : midpoint < item.chunk.acceptedEndSeconds
                guard isAfterLowerBoundary, isBeforeUpperBoundary else { continue }
                mergedSegments.append(TranscriptSegment(
                    startSeconds: start,
                    endSeconds: end,
                    text: segment.text,
                    confidence: segment.confidence
                ))
            }
        }
        mergedSegments.sort {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.endSeconds < $1.endSeconds
        }
        return TranscriptDocument(
            engine: engine,
            generatedAt: generatedAt,
            localeIdentifier: localeIdentifier,
            isOnDevice: isOnDevice,
            sourceRole: sourceRole,
            fullText: assembledText(
                segments: mergedSegments,
                localeIdentifier: localeIdentifier
            ),
            segments: mergedSegments
        )
    }

    private static func assembledText(
        segments: [TranscriptSegment],
        localeIdentifier: String
    ) -> String {
        let language = localeIdentifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        let compactLanguage = language == "zh" || language == "ja"
        let punctuation = CharacterSet.punctuationCharacters
        return segments.reduce(into: "") { result, segment in
            guard !segment.text.isEmpty else { return }
            let beginsWithPunctuation = segment.text.unicodeScalars.first
                .map(punctuation.contains) == true
            if result.isEmpty || compactLanguage || beginsWithPunctuation {
                result += segment.text
            } else {
                result += " " + segment.text
            }
        }
    }
}
