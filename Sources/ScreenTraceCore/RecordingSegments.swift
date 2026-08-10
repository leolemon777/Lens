import Foundation

public struct RecordingSegment: Codable, Equatable, Sendable {
    public let index: Int
    /// Start time on the pause-free output timeline.
    public let timelineStartSeconds: Double
    /// Nil while a segment is actively being written or was interrupted.
    public var durationSeconds: Double?
    public let screenRelativePath: String
    public var microphoneRelativePath: String?
    public var cameraRelativePath: String?

    public init(
        index: Int,
        timelineStartSeconds: Double,
        durationSeconds: Double? = nil,
        screenRelativePath: String,
        microphoneRelativePath: String? = nil,
        cameraRelativePath: String? = nil
    ) {
        self.index = max(0, index)
        self.timelineStartSeconds = max(0, timelineStartSeconds)
        self.durationSeconds = durationSeconds.map { max(0, $0) }
        self.screenRelativePath = screenRelativePath
        self.microphoneRelativePath = microphoneRelativePath
        self.cameraRelativePath = cameraRelativePath
    }
}

public struct RecordingSegmentIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public var segments: [RecordingSegment]

    public init(
        schemaVersion: String = RecordingSegmentIndex.currentSchemaVersion,
        segments: [RecordingSegment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.segments = segments.sorted { $0.index < $1.index }
    }

    public var completedDurationSeconds: Double {
        segments.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
    }
}
