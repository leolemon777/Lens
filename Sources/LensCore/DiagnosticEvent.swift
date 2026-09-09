import Foundation

public enum DiagnosticLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case timestamp
        case level
        case code
        case metadata
    }

    public static let allowedMetadataKeys: Set<String> = [
        "appVersion",
        "averageMilliseconds",
        "build",
        "captureMode",
        "cancellationReason",
        "count",
        "durationMilliseconds",
        "errorCode",
        "errorDomain",
        "executionMilliseconds",
        "eventCaptureMode",
        "eventStatus",
        "frameRate",
        "intent",
        "maximumMilliseconds",
        "measuredFrameRate",
        "phase",
        "queueMilliseconds",
        "renderEncodePassCount",
        "renderMilliseconds",
        "renderPeakPhysicalFootprintBytes",
        "status",
        "storageLevel",
        "taskKind",
        "taskOutcome",
        "totalMilliseconds",
        "videoStatus"
    ]

    public let timestamp: Date
    public let level: DiagnosticLevel
    public let code: String
    public let metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        level: DiagnosticLevel = .info,
        code: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.code = Self.sanitizeIdentifier(code, fallback: "diagnostic.invalid_code")
        self.metadata = metadata.reduce(into: [:]) { result, pair in
            guard Self.allowedMetadataKeys.contains(pair.key),
                  let value = Self.sanitizeMetadataValue(pair.value) else {
                return
            }
            result[pair.key] = value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            level: try container.decode(DiagnosticLevel.self, forKey: .level),
            code: try container.decode(String.self, forKey: .code),
            metadata: try container.decodeIfPresent(
                [String: String].self,
                forKey: .metadata
            ) ?? [:]
        )
    }

    public static func errorMetadata(_ error: Error) -> [String: String] {
        let error = error as NSError
        return [
            "errorDomain": sanitizeIdentifier(error.domain, fallback: "unknown"),
            "errorCode": String(error.code)
        ]
    }

    private static func sanitizeIdentifier(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(value.unicodeScalars.prefix(80).map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        })
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func sanitizeMetadataValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }
}
