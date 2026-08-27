import Foundation

public enum ConversationInboxStoreError: LocalizedError, Equatable {
    case emptyPNG

    public var errorDescription: String? {
        switch self {
        case .emptyPNG:
            return "截图数据为空，无法写入对话文件夹。"
        }
    }
}

public struct ConversationInboxSnapshot: Equatable, Sendable {
    public let directory: URL
    public let latestURL: URL
    public let archivedURL: URL

    public init(directory: URL, latestURL: URL, archivedURL: URL) {
        self.directory = directory
        self.latestURL = latestURL
        self.archivedURL = archivedURL
    }
}

/// A stable PNG drop folder for terminal / agent chats that cannot paste images.
///
/// Each save writes a timestamped archive and atomically replaces `latest.png`,
/// so you can always point an agent at the same path.
public struct ConversationInboxStore: Sendable {
    public static let directoryName = "Inbox"
    public static let latestFileName = "latest.png"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public static func directory(under rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    public static func defaultDirectory(
        rootDirectory: URL = LensProjectStore.defaultRootDirectory
    ) -> URL {
        directory(under: rootDirectory)
    }

    public static func resolvedDirectory(storedPath: String?) -> URL {
        let fallback = defaultDirectory()
        guard let storedPath, !storedPath.isEmpty else { return fallback }
        let url = URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return fallback
        }
        return url
    }

    public var latestURL: URL {
        directory.appendingPathComponent(Self.latestFileName)
    }

    @discardableResult
    public func save(pngData: Data, createdAt: Date = Date()) throws -> ConversationInboxSnapshot {
        guard !pngData.isEmpty else {
            throw ConversationInboxStoreError.emptyPNG
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let archivedURL = uniqueArchiveURL(createdAt: createdAt)
        try pngData.write(to: archivedURL, options: .atomic)
        try pngData.write(to: latestURL, options: .atomic)

        return ConversationInboxSnapshot(
            directory: directory,
            latestURL: latestURL,
            archivedURL: archivedURL
        )
    }

    private func uniqueArchiveURL(createdAt: Date) -> URL {
        let stamp = Self.archiveStamp(createdAt: createdAt)
        let baseName = "Lens-\(stamp)"
        var candidate = directory.appendingPathComponent("\(baseName).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix).png")
            suffix += 1
        }
        return candidate
    }

    private static func archiveStamp(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: createdAt)
    }
}
