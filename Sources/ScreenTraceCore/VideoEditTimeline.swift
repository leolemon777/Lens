import Foundation

public struct VideoEditSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var playbackRate: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        playbackRate: Double = 1,
        isEnabled: Bool = true
    ) {
        self.id = id
        let start = sourceStartSeconds.isFinite ? max(sourceStartSeconds, 0) : 0
        let end = sourceEndSeconds.isFinite ? sourceEndSeconds : start
        self.sourceStartSeconds = start
        self.sourceEndSeconds = max(end, start)
        self.playbackRate = Self.safePlaybackRate(playbackRate)
        self.isEnabled = isEnabled
    }

    public var sourceDurationSeconds: Double {
        max(sourceEndSeconds - sourceStartSeconds, 0)
    }

    public var outputDurationSeconds: Double {
        guard isEnabled else { return 0 }
        return sourceDurationSeconds / Self.safePlaybackRate(playbackRate)
    }

    static func safePlaybackRate(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 1, 0.25), 4)
    }
}

public struct VideoEditTimelinePosition: Equatable, Sendable {
    public let segmentID: UUID
    public let sourceTimeSeconds: Double

    public init(segmentID: UUID, sourceTimeSeconds: Double) {
        self.segmentID = segmentID
        self.sourceTimeSeconds = sourceTimeSeconds
    }
}

public struct VideoEditTimeRange: Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = max(endSeconds, startSeconds)
    }
}

public struct VideoEditTimeline: Codable, Equatable, Sendable {
    public static let minimumSegmentDurationSeconds = 0.05

    public var sourceDurationSeconds: Double
    public var segments: [VideoEditSegment]

    public init(
        sourceDurationSeconds: Double,
        segments: [VideoEditSegment]? = nil
    ) {
        let duration = Self.safeDuration(sourceDurationSeconds)
        self.sourceDurationSeconds = duration
        if let segments {
            self.segments = segments
        } else if duration >= Self.minimumSegmentDurationSeconds {
            self.segments = [VideoEditSegment(
                sourceStartSeconds: 0,
                sourceEndSeconds: duration
            )]
        } else {
            self.segments = []
        }
        self = normalized(sourceDurationSeconds: duration)
    }

    public var activeSegments: [VideoEditSegment] {
        segments.filter(\.isEnabled)
    }

    public var outputDurationSeconds: Double {
        activeSegments.reduce(0) { $0 + $1.outputDurationSeconds }
    }

    public func normalized(sourceDurationSeconds requestedDuration: Double? = nil) -> Self {
        let duration = Self.safeDuration(requestedDuration ?? sourceDurationSeconds)
        var seenIDs = Set<UUID>()
        let normalizedSegments = segments.compactMap { segment -> VideoEditSegment? in
            guard seenIDs.insert(segment.id).inserted else { return nil }
            let start = min(max(segment.sourceStartSeconds.isFinite
                ? segment.sourceStartSeconds
                : 0, 0), duration)
            let end = min(max(segment.sourceEndSeconds.isFinite
                ? segment.sourceEndSeconds
                : start, start), duration)
            guard end - start >= Self.minimumSegmentDurationSeconds else { return nil }
            return VideoEditSegment(
                id: segment.id,
                sourceStartSeconds: start,
                sourceEndSeconds: end,
                playbackRate: segment.playbackRate,
                isEnabled: segment.isEnabled
            )
        }
        let fallback: [VideoEditSegment]
        if normalizedSegments.contains(where: \.isEnabled)
            || duration < Self.minimumSegmentDurationSeconds {
            fallback = normalizedSegments
        } else {
            fallback = [VideoEditSegment(
                sourceStartSeconds: 0,
                sourceEndSeconds: duration
            )]
        }
        return Self(
            uncheckedSourceDurationSeconds: duration,
            segments: fallback
        )
    }

    public func position(atOutputTime seconds: Double) -> VideoEditTimelinePosition? {
        let active = activeSegments
        guard !active.isEmpty else { return nil }
        let requested = min(max(seconds.isFinite ? seconds : 0, 0), outputDurationSeconds)
        var outputCursor = 0.0
        for (index, segment) in active.enumerated() {
            let end = outputCursor + segment.outputDurationSeconds
            if requested < end || index == active.count - 1 {
                let localOutput = min(max(requested - outputCursor, 0), segment.outputDurationSeconds)
                return VideoEditTimelinePosition(
                    segmentID: segment.id,
                    sourceTimeSeconds: min(
                        segment.sourceStartSeconds + localOutput * segment.playbackRate,
                        segment.sourceEndSeconds
                    )
                )
            }
            outputCursor = end
        }
        return nil
    }

    public func outputRanges(
        forSourceRange sourceRange: VideoEditTimeRange
    ) -> [VideoEditTimeRange] {
        var outputCursor = 0.0
        var ranges: [VideoEditTimeRange] = []
        for segment in activeSegments {
            let overlapStart = max(sourceRange.startSeconds, segment.sourceStartSeconds)
            let overlapEnd = min(sourceRange.endSeconds, segment.sourceEndSeconds)
            if overlapEnd > overlapStart {
                ranges.append(VideoEditTimeRange(
                    startSeconds: outputCursor
                        + (overlapStart - segment.sourceStartSeconds) / segment.playbackRate,
                    endSeconds: outputCursor
                        + (overlapEnd - segment.sourceStartSeconds) / segment.playbackRate
                ))
            }
            outputCursor += segment.outputDurationSeconds
        }
        return ranges
    }

    @discardableResult
    public mutating func split(segmentID: UUID, atSourceTime sourceTime: Double) -> UUID? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        let segment = segments[index]
        let splitTime = min(max(sourceTime, segment.sourceStartSeconds), segment.sourceEndSeconds)
        guard splitTime - segment.sourceStartSeconds >= Self.minimumSegmentDurationSeconds,
              segment.sourceEndSeconds - splitTime >= Self.minimumSegmentDurationSeconds else {
            return nil
        }
        segments[index].sourceEndSeconds = splitTime
        let trailing = VideoEditSegment(
            sourceStartSeconds: splitTime,
            sourceEndSeconds: segment.sourceEndSeconds,
            playbackRate: segment.playbackRate,
            isEnabled: segment.isEnabled
        )
        segments.insert(trailing, at: index + 1)
        return trailing.id
    }

    public mutating func setEnabled(_ isEnabled: Bool, for segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        if !isEnabled,
           segments.filter(\.isEnabled).count <= 1,
           segments[index].isEnabled {
            return
        }
        segments[index].isEnabled = isEnabled
    }

    public mutating func setPlaybackRate(_ rate: Double, for segmentID: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].playbackRate = VideoEditSegment.safePlaybackRate(rate)
    }

    public mutating func trimStart(of segmentID: UUID, to sourceTime: Double) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let latestStart = segments[index].sourceEndSeconds
            - Self.minimumSegmentDurationSeconds
        segments[index].sourceStartSeconds = min(
            max(sourceTime, 0),
            latestStart
        )
    }

    public mutating func trimEnd(of segmentID: UUID, to sourceTime: Double) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let earliestEnd = segments[index].sourceStartSeconds
            + Self.minimumSegmentDurationSeconds
        segments[index].sourceEndSeconds = max(
            min(sourceTime, sourceDurationSeconds),
            earliestEnd
        )
    }

    private init(
        uncheckedSourceDurationSeconds: Double,
        segments: [VideoEditSegment]
    ) {
        sourceDurationSeconds = uncheckedSourceDurationSeconds
        self.segments = segments
    }

    private static func safeDuration(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}
