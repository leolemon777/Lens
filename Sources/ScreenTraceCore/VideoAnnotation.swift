import Foundation

public struct VideoAnnotation: Codable, Equatable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case annotation
        case sourceStartSeconds
        case sourceEndSeconds
        case fadeDurationSeconds
    }

    public var annotation: ScreenshotAnnotation
    public var sourceStartSeconds: Double
    public var sourceEndSeconds: Double
    public var fadeDurationSeconds: Double

    public var id: UUID { annotation.id }

    public init(
        annotation: ScreenshotAnnotation,
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        fadeDurationSeconds: Double = 0.16
    ) {
        let start = max(sourceStartSeconds.isFinite ? sourceStartSeconds : 0, 0)
        let end = sourceEndSeconds.isFinite ? sourceEndSeconds : start
        self.annotation = annotation
        self.sourceStartSeconds = start
        self.sourceEndSeconds = max(end, start)
        self.fadeDurationSeconds = min(max(
            fadeDurationSeconds.isFinite ? fadeDurationSeconds : 0.16,
            0
        ), 1)
    }

    public var sourceDurationSeconds: Double {
        max(sourceEndSeconds - sourceStartSeconds, 0)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            annotation: try container.decode(ScreenshotAnnotation.self, forKey: .annotation),
            sourceStartSeconds: try container.decode(Double.self, forKey: .sourceStartSeconds),
            sourceEndSeconds: try container.decode(Double.self, forKey: .sourceEndSeconds),
            fadeDurationSeconds: try container.decodeIfPresent(
                Double.self,
                forKey: .fadeDurationSeconds
            ) ?? 0.16
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(annotation, forKey: .annotation)
        try container.encode(sourceStartSeconds, forKey: .sourceStartSeconds)
        try container.encode(sourceEndSeconds, forKey: .sourceEndSeconds)
        try container.encode(fadeDurationSeconds, forKey: .fadeDurationSeconds)
    }

    public func opacity(atSourceTime seconds: Double) -> Double {
        guard seconds.isFinite,
              seconds >= sourceStartSeconds,
              seconds < sourceEndSeconds else { return 0 }
        let fade = min(fadeDurationSeconds, sourceDurationSeconds / 2)
        guard fade > 0 else { return 1 }
        let fadeIn = min(max((seconds - sourceStartSeconds) / fade, 0), 1)
        let fadeOut = min(max((sourceEndSeconds - seconds) / fade, 0), 1)
        return Self.smoothStep(min(fadeIn, fadeOut))
    }

    public func normalized(sourceDurationSeconds duration: Double) -> Self? {
        let safeDuration = max(duration.isFinite ? duration : 0, 0)
        let requestedStart = sourceStartSeconds.isFinite ? sourceStartSeconds : 0
        let start = min(max(requestedStart, 0), safeDuration)
        let requestedEnd = sourceEndSeconds.isFinite ? sourceEndSeconds : start
        let end = min(max(requestedEnd, start), safeDuration)
        guard end - start >= VideoEditTimeline.minimumSegmentDurationSeconds else {
            return nil
        }
        return Self(
            annotation: annotation,
            sourceStartSeconds: start,
            sourceEndSeconds: end,
            fadeDurationSeconds: fadeDurationSeconds
        )
    }

    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}

public enum VideoAnnotationPlanner {
    public static func activeAnnotations(
        atSourceTime seconds: Double,
        annotations: [VideoAnnotation]
    ) -> [(annotation: ScreenshotAnnotation, opacity: Double)] {
        annotations.compactMap { item in
            let opacity = item.opacity(atSourceTime: seconds)
            return opacity > 0.000_1 ? (item.annotation, opacity) : nil
        }
    }

    public static func outputRanges(
        for annotation: VideoAnnotation,
        timeline: VideoEditTimeline?
    ) -> [VideoEditTimeRange] {
        let sourceRange = VideoEditTimeRange(
            startSeconds: annotation.sourceStartSeconds,
            endSeconds: annotation.sourceEndSeconds
        )
        return timeline?.outputRanges(forSourceRange: sourceRange) ?? [sourceRange]
    }

    public static func activeAnnotations(
        atOutputTime seconds: Double,
        annotations: [VideoAnnotation],
        timeline: VideoEditTimeline?
    ) -> [(annotation: ScreenshotAnnotation, opacity: Double)] {
        let contributions = timeline?.sourceContributions(atOutputTime: seconds)
            ?? [VideoEditTimelineSourceContribution(
                segmentID: UUID(),
                sourceTimeSeconds: seconds,
                weight: 1
            )]
        return annotations.compactMap { item in
            let opacity = min(contributions.reduce(0) { partial, contribution in
                partial + item.opacity(atSourceTime: contribution.sourceTimeSeconds)
                    * contribution.weight
            }, 1)
            return opacity > 0.000_1 ? (item.annotation, opacity) : nil
        }
    }
}
