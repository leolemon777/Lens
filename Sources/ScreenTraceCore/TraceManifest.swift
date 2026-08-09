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
        case systemAudio
        case microphone
        case camera
        case thumbnail
        case renderedVideo
        case pointerEvents
        case clickEvents
        case keyboardEvents
        case windowEvents
        case editPlan
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

public struct TraceManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"

    public let schemaVersion: String
    public let id: UUID
    public let kind: TraceKind
    public let createdAt: Date
    public var title: String
    public var state: TraceState
    public var durationSeconds: Double?
    public let dimensions: TraceDimensions?
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
        self.assets = assets
    }
}

public struct RecordingTraceSession: Equatable, Sendable {
    public let packageURL: URL
    public let videoURL: URL
    public let pointerEventsURL: URL
    public let clickEventsURL: URL
    public let editPlanURL: URL
    public let manifest: TraceManifest

    public init(
        packageURL: URL,
        videoURL: URL,
        pointerEventsURL: URL,
        clickEventsURL: URL,
        editPlanURL: URL,
        manifest: TraceManifest
    ) {
        self.packageURL = packageURL
        self.videoURL = videoURL
        self.pointerEventsURL = pointerEventsURL
        self.clickEventsURL = clickEventsURL
        self.editPlanURL = editPlanURL
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
