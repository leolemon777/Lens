import Foundation

public enum LensKind: String, Codable, Sendable {
    case screenshot
    case recording
}

public enum LensState: String, Codable, Sendable {
    case capturing
    case processing
    case ready
    case interrupted
    case failed
}

public struct LensAsset: Codable, Equatable, Sendable {
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

public enum LensManifestValidationError: LocalizedError, Equatable, Sendable {
    case invalidAssetPath(String)
    case assetPathEscapesPackage(String)
    case assetIsSymbolicLink(String)
    case invalidDimensions
    case invalidDuration
    case oversizedTitle

    public var errorDescription: String? {
        switch self {
        case let .invalidAssetPath(path):
            return "Lens 项目包含越界或非法资产路径：\(path)。"
        case let .assetPathEscapesPackage(path):
            return "Lens 项目资产路径跳出了项目包：\(path)。"
        case let .assetIsSymbolicLink(path):
            return "Lens 项目资产不能通过符号链接读取：\(path)。"
        case .invalidDimensions:
            return "Lens 项目尺寸超出可读取范围。"
        case .invalidDuration:
            return "Lens 项目时长无效。"
        case .oversizedTitle:
            return "Lens 项目标题过长。"
        }
    }
}

public struct LensDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct LensCaptureMetadata: Codable, Equatable, Sendable {
    public let mode: RecordingCaptureMode
    public let displayID: UInt32?
    public let windowID: UInt32?
    /// Absolute global capture bounds in logical points.
    public let globalBounds: LensRect
    /// Display-local crop in logical points for region capture.
    public let sourceRect: LensRect?
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
        globalBounds: LensRect,
        sourceRect: LensRect? = nil,
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
        globalBounds = LensRect(actualCaptureBounds ?? source.captureBounds)
        sourceRect = (actualSourceRect ?? source.sourceRect).map(LensRect.init)
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
    ) -> LensCaptureMetadata {
        LensCaptureMetadata(
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
    public let globalBounds: LensRect
    /// Display-local crop in logical points for region capture.
    public let sourceRect: LensRect?
    public let windowTitle: String?
    public let applicationName: String?

    public init(
        mode: ScreenshotCaptureMode,
        displayID: UInt32? = nil,
        windowIDs: [UInt32] = [],
        globalBounds: CGRect,
        sourceRect: CGRect? = nil,
        windowTitle: String? = nil,
        applicationName: String? = nil
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowIDs = Array(Set(windowIDs)).sorted()
        self.globalBounds = LensRect(globalBounds.standardized)
        self.sourceRect = sourceRect.map { LensRect($0.standardized) }
        let trimmedTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApplication = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        self.applicationName = (trimmedApplication?.isEmpty == false) ? trimmedApplication : nil
    }
}

public struct LensManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.9"

    public var schemaVersion: String
    public let id: UUID
    public let kind: LensKind
    public let createdAt: Date
    public var title: String
    public var state: LensState
    public var durationSeconds: Double?
    public let dimensions: LensDimensions?
    public var captureSource: LensCaptureMetadata?
    public let screenshotCaptureSource: ScreenshotCaptureMetadata?
    public var assets: [LensAsset]

    public init(
        schemaVersion: String = LensManifest.currentSchemaVersion,
        id: UUID = UUID(),
        kind: LensKind,
        createdAt: Date = Date(),
        title: String,
        state: LensState = .ready,
        durationSeconds: Double? = nil,
        dimensions: LensDimensions?,
        captureSource: LensCaptureMetadata? = nil,
        screenshotCaptureSource: ScreenshotCaptureMetadata? = nil,
        assets: [LensAsset]
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

    /// Validates fields that are later used to construct paths or allocate
    /// media buffers. Reading and writing use the same gate so an unsupported
    /// future project is rejected instead of being silently rewritten.
    public func validateForStorage() throws {
        if let dimensions,
           dimensions.width <= 0 || dimensions.height <= 0
            || dimensions.width > 100_000 || dimensions.height > 100_000 {
            throw LensManifestValidationError.invalidDimensions
        }
        if let durationSeconds,
           !durationSeconds.isFinite || durationSeconds < 0 || durationSeconds > 2_592_000 {
            throw LensManifestValidationError.invalidDuration
        }
        guard title.utf8.count <= 4_096 else {
            throw LensManifestValidationError.oversizedTitle
        }

        for asset in assets {
            let path = asset.relativePath
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let isRelativeSafe = !path.isEmpty
                && path.utf8.count <= 4_096
                && !path.hasPrefix("/")
                && !path.contains("\\")
                && !path.contains("\0")
                && !components.isEmpty
                && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            guard isRelativeSafe else {
                throw LensManifestValidationError.invalidAssetPath(path)
            }
        }
    }

    /// Validates the resolved location of every declared asset before a
    /// project is imported or an asset is read. Lexical checks alone do not
    /// catch a package child that is a symlink to a path outside the package.
    /// Missing optional assets remain valid so interrupted/capturing projects
    /// can still be opened and repaired.
    public func validateAssetPaths(in packageURL: URL) throws {
        try validateForStorage()

        let packageRoot = packageURL.standardizedFileURL
        let resolvedPackageRoot = packageRoot.resolvingSymlinksInPath()
        for asset in assets {
            let candidate = packageRoot.appendingPathComponent(asset.relativePath)
            var cursor = packageRoot
            for component in asset.relativePath.split(separator: "/") {
                cursor.appendPathComponent(String(component))
                if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    throw LensManifestValidationError.assetIsSymbolicLink(asset.relativePath)
                }
            }

            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            let rootPath = resolvedPackageRoot.path.hasSuffix("/")
                ? resolvedPackageRoot.path
                : resolvedPackageRoot.path + "/"
            guard resolvedCandidate.path == resolvedPackageRoot.path
                || resolvedCandidate.path.hasPrefix(rootPath) else {
                throw LensManifestValidationError.assetPathEscapesPackage(asset.relativePath)
            }
        }
    }
}

private extension LensRect {
    init(_ rect: CGRect) {
        self.init(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

public struct RecordingLensSession: Equatable, Sendable {
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
    public let manifest: LensManifest

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
        manifest: LensManifest
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
    public let manifest: LensManifest

    public init(packageURL: URL, videoURL: URL, manifest: LensManifest) {
        self.packageURL = packageURL
        self.videoURL = videoURL
        self.manifest = manifest
    }
}

public struct SavedLens: Equatable, Sendable {
    public let packageURL: URL
    public let rawAssetURL: URL
    public let manifest: LensManifest

    public init(packageURL: URL, rawAssetURL: URL, manifest: LensManifest) {
        self.packageURL = packageURL
        self.rawAssetURL = rawAssetURL
        self.manifest = manifest
    }
}
