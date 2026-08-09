import Foundation

public struct ScrollingCaptureFrame: Codable, Equatable, Sendable {
    public let index: Int
    public let relativePath: String
    /// Top-left vertical placement in the reconstructed long image.
    public let verticalOffsetPixels: Int
    /// New rows contributed by this frame after overlap removal.
    public let appendedHeightPixels: Int
    /// Normalized mean pixel difference of the accepted overlap. Zero for the first frame.
    public let overlapDifference: Double

    public init(
        index: Int,
        relativePath: String,
        verticalOffsetPixels: Int,
        appendedHeightPixels: Int,
        overlapDifference: Double
    ) {
        self.index = max(index, 0)
        self.relativePath = relativePath
        self.verticalOffsetPixels = max(verticalOffsetPixels, 0)
        self.appendedHeightPixels = max(appendedHeightPixels, 0)
        self.overlapDifference = min(max(overlapDifference, 0), 1)
    }
}

public struct ScrollingCapturePlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public let displayID: UInt32
    /// Display-local selection in logical points, using a top-left origin.
    public let sourceRect: TraceRect
    public let viewportDimensions: TraceDimensions
    public let outputDimensions: TraceDimensions
    public let frames: [ScrollingCaptureFrame]

    public init(
        schemaVersion: String = ScrollingCapturePlan.currentSchemaVersion,
        displayID: UInt32,
        sourceRect: TraceRect,
        viewportDimensions: TraceDimensions,
        outputDimensions: TraceDimensions,
        frames: [ScrollingCaptureFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.viewportDimensions = viewportDimensions
        self.outputDimensions = outputDimensions
        self.frames = frames
    }
}
