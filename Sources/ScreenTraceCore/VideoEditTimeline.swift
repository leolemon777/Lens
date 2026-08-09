import Foundation

public struct VideoEditTransition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cut
        case crossDissolve
        case dipToBlack
    }

    public static let maximumDurationSeconds = 2.0

    public var kind: Kind
    public var durationSeconds: Double

    public init(
        kind: Kind = .crossDissolve,
        durationSeconds: Double = 0.35
    ) {
        self.kind = kind
        self.durationSeconds = kind == .cut ? 0 : min(
            max(durationSeconds.isFinite ? durationSeconds : 0.35, 0.05),
            Self.maximumDurationSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(Kind.self, forKey: .kind),
            durationSeconds: try container.decode(Double.self, forKey: .durationSeconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(durationSeconds, forKey: .durationSeconds)
    }
}

public struct VideoEditSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var playbackRate: Double
    public var isEnabled: Bool
    /// The transition from this segment to the next enabled segment.
    public var transitionToNext: VideoEditTransition?

    public init(
        id: UUID = UUID(),
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        playbackRate: Double = 1,
        isEnabled: Bool = true,
        transitionToNext: VideoEditTransition? = nil
    ) {
        self.id = id
        let start = sourceStartSeconds.isFinite ? max(sourceStartSeconds, 0) : 0
        let end = sourceEndSeconds.isFinite ? sourceEndSeconds : start
        self.sourceStartSeconds = start
        self.sourceEndSeconds = max(end, start)
        self.playbackRate = Self.safePlaybackRate(playbackRate)
        self.isEnabled = isEnabled
        self.transitionToNext = transitionToNext.map {
            VideoEditTransition(kind: $0.kind, durationSeconds: $0.durationSeconds)
        }
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

public struct VideoEditSegmentLayout: Equatable, Sendable {
    public let segmentID: UUID
    public let outputStartSeconds: Double
    public let outputEndSeconds: Double

    public init(
        segmentID: UUID,
        outputStartSeconds: Double,
        outputEndSeconds: Double
    ) {
        self.segmentID = segmentID
        self.outputStartSeconds = outputStartSeconds
        self.outputEndSeconds = max(outputEndSeconds, outputStartSeconds)
    }

    public var outputDurationSeconds: Double {
        max(outputEndSeconds - outputStartSeconds, 0)
    }
}

public struct VideoEditResolvedTransition: Equatable, Sendable {
    public let fromSegmentID: UUID
    public let toSegmentID: UUID
    public let kind: VideoEditTransition.Kind
    public let durationSeconds: Double
    public let outputStartSeconds: Double
    public let outputEndSeconds: Double

    public init(
        fromSegmentID: UUID,
        toSegmentID: UUID,
        kind: VideoEditTransition.Kind,
        durationSeconds: Double,
        outputStartSeconds: Double,
        outputEndSeconds: Double
    ) {
        self.fromSegmentID = fromSegmentID
        self.toSegmentID = toSegmentID
        self.kind = kind
        self.durationSeconds = max(durationSeconds, 0)
        self.outputStartSeconds = outputStartSeconds
        self.outputEndSeconds = max(outputEndSeconds, outputStartSeconds)
    }

    public func progress(atOutputTime seconds: Double) -> Double {
        guard durationSeconds > 0 else { return 1 }
        return min(max((seconds - outputStartSeconds) / durationSeconds, 0), 1)
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

    public var segmentLayouts: [VideoEditSegmentLayout] {
        resolvedLayout().layouts
    }

    public var resolvedTransitions: [VideoEditResolvedTransition] {
        resolvedLayout().transitions
    }

    public var hasActiveTransitions: Bool {
        !resolvedTransitions.isEmpty
    }

    public var outputDurationSeconds: Double {
        segmentLayouts.last?.outputEndSeconds ?? 0
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
                isEnabled: segment.isEnabled,
                transitionToNext: segment.transitionToNext
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
        let layout = resolvedLayout()
        let containing = layout.layouts.enumerated().filter { index, item in
            requested >= item.outputStartSeconds
                && (requested < item.outputEndSeconds || index == layout.layouts.count - 1)
        }
        guard !containing.isEmpty else { return nil }
        let chosen: (offset: Int, element: VideoEditSegmentLayout)
        if containing.count > 1,
           let transition = layout.transitions.first(where: {
               requested >= $0.outputStartSeconds && requested < $0.outputEndSeconds
           }),
           let incoming = containing.first(where: {
               $0.element.segmentID == transition.toSegmentID
           }),
           transition.progress(atOutputTime: requested) >= 0.5 {
            chosen = incoming
        } else {
            chosen = containing[0]
        }
        let segment = active[chosen.offset]
        let localOutput = min(
            max(requested - chosen.element.outputStartSeconds, 0),
            segment.outputDurationSeconds
        )
        return VideoEditTimelinePosition(
            segmentID: segment.id,
            sourceTimeSeconds: min(
                segment.sourceStartSeconds + localOutput * segment.playbackRate,
                segment.sourceEndSeconds
            )
        )
    }

    public func outputRanges(
        forSourceRange sourceRange: VideoEditTimeRange
    ) -> [VideoEditTimeRange] {
        var ranges: [VideoEditTimeRange] = []
        for (segment, layout) in zip(activeSegments, segmentLayouts) {
            let overlapStart = max(sourceRange.startSeconds, segment.sourceStartSeconds)
            let overlapEnd = min(sourceRange.endSeconds, segment.sourceEndSeconds)
            if overlapEnd > overlapStart {
                ranges.append(VideoEditTimeRange(
                    startSeconds: layout.outputStartSeconds
                        + (overlapStart - segment.sourceStartSeconds) / segment.playbackRate,
                    endSeconds: layout.outputStartSeconds
                        + (overlapEnd - segment.sourceStartSeconds) / segment.playbackRate
                ))
            }
        }
        return ranges
    }

    /// A source-time keyframe may appear more than once when clips are repeated
    /// or reordered, so callers receive every matching output position.
    public func outputTimes(forSourceTime seconds: Double) -> [Double] {
        guard seconds.isFinite else { return [] }
        let active = activeSegments
        let layouts = segmentLayouts
        var results: [Double] = []
        for (index, segment) in active.enumerated() {
            let includesEnd = index == active.count - 1 && seconds == segment.sourceEndSeconds
            if seconds >= segment.sourceStartSeconds,
               seconds < segment.sourceEndSeconds || includesEnd {
                results.append(layouts[index].outputStartSeconds
                    + (seconds - segment.sourceStartSeconds) / segment.playbackRate)
            }
        }
        return results
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
        segments[index].transitionToNext = nil
        let trailing = VideoEditSegment(
            sourceStartSeconds: splitTime,
            sourceEndSeconds: segment.sourceEndSeconds,
            playbackRate: segment.playbackRate,
            isEnabled: segment.isEnabled,
            transitionToNext: segment.transitionToNext
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

    public mutating func setTransition(
        _ transition: VideoEditTransition?,
        after segmentID: UUID
    ) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        guard activeSegments.last?.id != segmentID else {
            segments[index].transitionToNext = nil
            return
        }
        guard let transition, transition.kind != .cut else {
            segments[index].transitionToNext = nil
            return
        }
        segments[index].transitionToNext = VideoEditTransition(
            kind: transition.kind,
            durationSeconds: transition.durationSeconds
        )
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

    private func resolvedLayout() -> (
        layouts: [VideoEditSegmentLayout],
        transitions: [VideoEditResolvedTransition]
    ) {
        let active = activeSegments
        guard !active.isEmpty else { return ([], []) }
        var layouts: [VideoEditSegmentLayout] = []
        var transitions: [VideoEditResolvedTransition] = []
        var outputStart = 0.0

        for (index, segment) in active.enumerated() {
            let outputEnd = outputStart + segment.outputDurationSeconds
            layouts.append(VideoEditSegmentLayout(
                segmentID: segment.id,
                outputStartSeconds: outputStart,
                outputEndSeconds: outputEnd
            ))
            guard index < active.count - 1 else { continue }
            let next = active[index + 1]
            let requested = segment.transitionToNext
            let kind = requested?.kind ?? .cut
            let duration: Double
            if kind == .cut {
                duration = 0
            } else {
                duration = min(
                    requested?.durationSeconds ?? 0.35,
                    segment.outputDurationSeconds / 2,
                    next.outputDurationSeconds / 2,
                    VideoEditTransition.maximumDurationSeconds
                )
            }
            let effectiveDuration = duration >= Self.minimumSegmentDurationSeconds
                ? duration
                : 0
            if effectiveDuration > 0 {
                transitions.append(VideoEditResolvedTransition(
                    fromSegmentID: segment.id,
                    toSegmentID: next.id,
                    kind: kind,
                    durationSeconds: effectiveDuration,
                    outputStartSeconds: outputEnd - effectiveDuration,
                    outputEndSeconds: outputEnd
                ))
            }
            outputStart = outputEnd - effectiveDuration
        }
        return (layouts, transitions)
    }

    private static func safeDuration(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}
