import Foundation

public enum TraceKind: String, Codable, Sendable {
    case screenshot
    case recording
}

public enum TraceState: String, Codable, Sendable {
    case capturing
    case processing
    case ready
    case interrupted
    case failed
}

public struct TraceAsset: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case screenshot
        case screenVideo
        case screenVideoSegment
        case systemAudio
        case microphone
        case microphoneSegment
        case camera
        case cameraSegment
        case thumbnail
        case renderedVideo
        case renderedScreenshot
        case pointerEvents
        case clickEvents
        case keyboardEvents
        case windowEvents
        case recordingSegments
        case editPlan
        case screenshotEditPlan
        case scrollingCaptureFrame
        case scrollingCapturePlan
        case ocr
        case transcript
        case insights
        case recordingHealth
    }

    public let role: Role
    public let relativePath: String

    public init(role: Role, relativePath: String) {
        self.role = role
        self.relativePath = relativePath
    }
}

public struct TraceDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct TraceCaptureMetadata: Codable, Equatable, Sendable {
    public let mode: RecordingCaptureMode
    public let displayID: UInt32?
    public let windowID: UInt32?
    /// Absolute global capture bounds in logical points.
    public let globalBounds: TraceRect
    /// Display-local crop in logical points for region capture.
    public let sourceRect: TraceRect?
    public let windowTitle: String?
    public let applicationName: String?
    /// Legacy requested frame rate retained for schema 0.8 and earlier readers.
    public let framesPerSecond: Int?
    public let requestedFramesPerSecond: Int?
    public let measuredFramesPerSecond: Double?
    public let p95FrameIntervalMilliseconds: Double?
    public let droppedFrameCount: Int?

    public init(
        mode: RecordingCaptureMode,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        globalBounds: TraceRect,
        sourceRect: TraceRect? = nil,
        windowTitle: String? = nil,
        applicationName: String? = nil,
        framesPerSecond: Int? = nil,
        requestedFramesPerSecond: Int? = nil,
        measuredFramesPerSecond: Double? = nil,
        p95FrameIntervalMilliseconds: Double? = nil,
        droppedFrameCount: Int? = nil
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowID = windowID
        self.globalBounds = globalBounds
        self.sourceRect = sourceRect
        self.windowTitle = windowTitle
        self.applicationName = applicationName
        self.framesPerSecond = framesPerSecond.map { max($0, 1) }
        self.requestedFramesPerSecond = (requestedFramesPerSecond ?? framesPerSecond)
            .map { max($0, 1) }
        self.measuredFramesPerSecond = measuredFramesPerSecond.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.p95FrameIntervalMilliseconds = p95FrameIntervalMilliseconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.droppedFrameCount = droppedFrameCount.map { max($0, 0) }
    }

    public init(
        recordingSource source: RecordingCaptureSource,
        actualCaptureBounds: CGRect? = nil,
        actualSourceRect: CGRect? = nil,
        framesPerSecond: Int? = nil,
        requestedFramesPerSecond: Int? = nil,
        measuredFramesPerSecond: Double? = nil,
        p95FrameIntervalMilliseconds: Double? = nil,
        droppedFrameCount: Int? = nil
    ) {
        mode = source.mode
        displayID = source.displayID
        windowID = source.windowID
        globalBounds = TraceRect(actualCaptureBounds ?? source.captureBounds)
        sourceRect = (actualSourceRect ?? source.sourceRect).map(TraceRect.init)
        windowTitle = source.windowTitle
        applicationName = source.applicationName
        self.framesPerSecond = framesPerSecond.map { max($0, 1) }
        self.requestedFramesPerSecond = (requestedFramesPerSecond ?? framesPerSecond)
            .map { max($0, 1) }
        self.measuredFramesPerSecond = measuredFramesPerSecond.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.p95FrameIntervalMilliseconds = p95FrameIntervalMilliseconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        self.droppedFrameCount = droppedFrameCount.map { max($0, 0) }
    }

    public func updatingCapturePerformance(
        measuredFramesPerSecond: Double?,
        p95FrameIntervalMilliseconds: Double?,
        droppedFrameCount: Int?
    ) -> TraceCaptureMetadata {
        TraceCaptureMetadata(
            mode: mode,
            displayID: displayID,
            windowID: windowID,
            globalBounds: globalBounds,
            sourceRect: sourceRect,
            windowTitle: windowTitle,
            applicationName: applicationName,
            framesPerSecond: framesPerSecond,
            requestedFramesPerSecond: requestedFramesPerSecond ?? framesPerSecond,
            measuredFramesPerSecond: measuredFramesPerSecond,
            p95FrameIntervalMilliseconds: p95FrameIntervalMilliseconds,
            droppedFrameCount: droppedFrameCount
        )
    }

    public var effectiveRequestedFramesPerSecond: Int? {
        requestedFramesPerSecond ?? framesPerSecond
    }
}

public struct ScreenshotCaptureMetadata: Codable, Equatable, Sendable {
    public let mode: ScreenshotCaptureMode
    public let displayID: UInt32?
    public let windowIDs: [UInt32]
    /// Absolute global capture bounds in logical points.
    public let globalBounds: TraceRect
    /// Display-local crop in logical points for region capture.
    public let sourceRect: TraceRect?

    public init(
        mode: ScreenshotCaptureMode,
        displayID: UInt32? = nil,
        windowIDs: [UInt32] = [],
        globalBounds: CGRect,
        sourceRect: CGRect? = nil
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowIDs = Array(Set(windowIDs)).sorted()
        self.globalBounds = TraceRect(globalBounds.standardized)
        self.sourceRect = sourceRect.map { TraceRect($0.standardized) }
    }
}

public struct TraceManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.9"

    public var schemaVersion: String
    public let id: UUID
    public let kind: TraceKind
    public let createdAt: Date
    public var title: String
    public var state: TraceState
    public var durationSeconds: Double?
    public let dimensions: TraceDimensions?
    public var captureSource: TraceCaptureMetadata?
    public let screenshotCaptureSource: ScreenshotCaptureMetadata?
    public var assets: [TraceAsset]

    public init(
        schemaVersion: String = TraceManifest.currentSchemaVersion,
        id: UUID = UUID(),
        kind: TraceKind,
        createdAt: Date = Date(),
        title: String,
        state: TraceState = .ready,
        durationSeconds: Double? = nil,
        dimensions: TraceDimensions?,
        captureSource: TraceCaptureMetadata? = nil,
        screenshotCaptureSource: ScreenshotCaptureMetadata? = nil,
        assets: [TraceAsset]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.title = title
        self.state = state
        self.durationSeconds = durationSeconds
        self.dimensions = dimensions
        self.captureSource = captureSource
        self.screenshotCaptureSource = screenshotCaptureSource
        self.assets = assets
    }
}

private extension TraceRect {
    init(_ rect: CGRect) {
        self.init(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

public struct RecordingTraceSession: Equatable, Sendable {
    public let packageURL: URL
    public let videoURL: URL
    public let pointerEventsURL: URL
    public let clickEventsURL: URL
    public let keyboardEventsURL: URL
    public let windowEventsURL: URL
    public let segmentIndexURL: URL
    public let editPlanURL: URL
    public let microphoneURL: URL?
    public let cameraURL: URL?
    public let manifest: TraceManifest

    public init(
        packageURL: URL,
        videoURL: URL,
        pointerEventsURL: URL,
        clickEventsURL: URL,
        keyboardEventsURL: URL,
        windowEventsURL: URL,
        segmentIndexURL: URL,
        editPlanURL: URL,
        microphoneURL: URL? = nil,
        cameraURL: URL? = nil,
        manifest: TraceManifest
    ) {
        self.packageURL = packageURL
        self.videoURL = videoURL
        self.pointerEventsURL = pointerEventsURL
        self.clickEventsURL = clickEventsURL
        self.keyboardEventsURL = keyboardEventsURL
        self.windowEventsURL = windowEventsURL
        self.segmentIndexURL = segmentIndexURL
        self.editPlanURL = editPlanURL
        self.microphoneURL = microphoneURL
        self.cameraURL = cameraURL
        self.manifest = manifest
    }
}

public struct RecordingRecoveryCandidate: Equatable, Sendable {
    public let packageURL: URL
    public let videoURL: URL
    public let manifest: TraceManifest

    public init(packageURL: URL, videoURL: URL, manifest: TraceManifest) {
        self.packageURL = packageURL
        self.videoURL = videoURL
        self.manifest = manifest
    }
}

public struct SavedTrace: Equatable, Sendable {
    public let packageURL: URL
    public let rawAssetURL: URL
    public let manifest: TraceManifest

    public init(packageURL: URL, rawAssetURL: URL, manifest: TraceManifest) {
        self.packageURL = packageURL
        self.rawAssetURL = rawAssetURL
        self.manifest = manifest
    }
}
