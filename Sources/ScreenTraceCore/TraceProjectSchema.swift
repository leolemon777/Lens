import Foundation

public struct TraceSchemaVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int

    public init?(_ rawValue: String) {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]) else {
            return nil
        }
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: TraceSchemaVersion, rhs: TraceSchemaVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public enum TraceSchemaCompatibilityError: LocalizedError, Equatable, Sendable {
    case malformed(document: String, found: String)
    case unsupported(document: String, found: String, supported: String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(document, found):
            return "\(document) 的 schemaVersion 无效：\(found)。"
        case let .unsupported(document, found, supported):
            return "\(document) 的 schemaVersion \(found) 不受支持；当前可读取 \(supported)。"
        }
    }
}

public struct TraceSchemaDescriptor: Equatable, Sendable {
    public let identifier: String
    public let relativePath: String
    public let minimumReadableVersion: String
    public let currentVersion: String

    public init(
        identifier: String,
        relativePath: String,
        minimumReadableVersion: String,
        currentVersion: String
    ) {
        self.identifier = identifier
        self.relativePath = relativePath
        self.minimumReadableVersion = minimumReadableVersion
        self.currentVersion = currentVersion
    }

    public var readableRange: String {
        "\(minimumReadableVersion)...\(currentVersion)"
    }

    public func validate(_ version: String) throws {
        guard let candidate = TraceSchemaVersion(version) else {
            throw TraceSchemaCompatibilityError.malformed(
                document: identifier,
                found: version
            )
        }
        guard let minimum = TraceSchemaVersion(minimumReadableVersion),
              let current = TraceSchemaVersion(currentVersion),
              candidate >= minimum,
              candidate <= current else {
            throw TraceSchemaCompatibilityError.unsupported(
                document: identifier,
                found: version,
                supported: readableRange
            )
        }
    }
}

public enum TraceProjectSchema {
    public static let manifest = TraceSchemaDescriptor(
        identifier: "manifest.json",
        relativePath: "manifest.json",
        minimumReadableVersion: "0.1",
        currentVersion: TraceManifest.currentSchemaVersion
    )
    public static let autoEditPlan = TraceSchemaDescriptor(
        identifier: "edit-plan.json",
        relativePath: "edits/edit-plan.json",
        minimumReadableVersion: "0.1",
        currentVersion: AutoEditPlan.currentSchemaVersion
    )
    public static let screenshotEditPlan = TraceSchemaDescriptor(
        identifier: "screenshot-edit.json",
        relativePath: "edits/screenshot-edit.json",
        minimumReadableVersion: "0.2",
        currentVersion: ScreenshotEditPlan.currentSchemaVersion
    )
    public static let recordingSegments = TraceSchemaDescriptor(
        identifier: "segments.json",
        relativePath: "events/segments.json",
        minimumReadableVersion: "0.1",
        currentVersion: RecordingSegmentIndex.currentSchemaVersion
    )
    public static let scrollingCapture = TraceSchemaDescriptor(
        identifier: "scrolling-capture.json",
        relativePath: "events/scrolling-capture.json",
        minimumReadableVersion: "0.1",
        currentVersion: ScrollingCapturePlan.currentSchemaVersion
    )
    public static let ocr = TraceSchemaDescriptor(
        identifier: "ocr.json",
        relativePath: "analysis/ocr.json",
        minimumReadableVersion: "0.1",
        currentVersion: OCRDocument.currentSchemaVersion
    )
    public static let transcript = TraceSchemaDescriptor(
        identifier: "transcript.json",
        relativePath: "analysis/transcript.json",
        minimumReadableVersion: "0.1",
        currentVersion: TranscriptDocument.currentSchemaVersion
    )
    public static let insights = TraceSchemaDescriptor(
        identifier: "insights.json",
        relativePath: "analysis/insights.json",
        minimumReadableVersion: "0.1",
        currentVersion: TraceInsightsDocument.currentSchemaVersion
    )

    public static let portableDocuments = [
        manifest,
        autoEditPlan,
        screenshotEditPlan,
        recordingSegments,
        scrollingCapture,
        ocr,
        transcript,
        insights
    ]
}
