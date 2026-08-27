import Foundation

enum LensBuildChannel: String, Codable, CaseIterable, Sendable {
    case development
    case beta
    case release

    init(infoDictionaryValue: String?) {
        self = Self(rawValue: infoDictionaryValue?.lowercased() ?? "") ?? .development
    }

    var presentationTitle: String {
        switch self {
        case .development: "Development"
        case .beta: "Beta"
        case .release: "Release"
        }
    }
}

struct BuildIdentity: Codable, Equatable, Sendable {
    static let developmentValue = "development"
    static let unknownCommit = "unknown"

    let version: String
    let buildNumber: String
    let gitCommit: String
    let builtAt: Date?
    let channel: LensBuildChannel
    let bundleIdentifier: String
    let executableURL: URL?

    init(
        version: String,
        buildNumber: String,
        gitCommit: String = BuildIdentity.unknownCommit,
        builtAt: Date? = nil,
        channel: LensBuildChannel = .development,
        bundleIdentifier: String = "app.lens.mac",
        executableURL: URL? = nil
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.gitCommit = gitCommit
        self.builtAt = builtAt
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.executableURL = executableURL?.standardizedFileURL
    }

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? Self.developmentValue
        buildNumber = info["CFBundleVersion"] as? String ?? Self.developmentValue
        gitCommit = info["LensGitCommit"] as? String ?? Self.unknownCommit
        builtAt = Self.parseBuildDate(info["LensBuiltAt"] as? String)
        channel = LensBuildChannel(
            infoDictionaryValue: info["LensBuildChannel"] as? String
        )
        bundleIdentifier = bundle.bundleIdentifier
            ?? info["CFBundleIdentifier"] as? String
            ?? "app.lens.mac"
        executableURL = bundle.executableURL?.standardizedFileURL
    }

    static var current: BuildIdentity {
        BuildIdentity(bundle: .main)
    }

    var shortCommit: String {
        guard gitCommit != Self.unknownCommit else { return gitCommit }
        return String(gitCommit.prefix(12))
    }

    var displayVersion: String {
        "\(version) (\(buildNumber))"
    }

    var displayDetail: String {
        var parts = [channel.presentationTitle, "commit \(shortCommit)"]
        if let builtAt {
            parts.append(Self.displayDate(builtAt))
        }
        return parts.joined(separator: " · ")
    }

    var diagnosticMetadata: [String: String] {
        var metadata = [
            "appVersion": version,
            "build": buildNumber,
            "channel": channel.rawValue,
            "gitCommit": shortCommit
        ]
        if let builtAt {
            metadata["builtAt"] = Self.iso8601String(from: builtAt)
        }
        return metadata
    }

    func isSameBuild(as other: BuildIdentity) -> Bool {
        bundleIdentifier == other.bundleIdentifier
            && version == other.version
            && buildNumber == other.buildNumber
            && gitCommit == other.gitCommit
            && executableURL == other.executableURL
    }

    private static func parseBuildDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
