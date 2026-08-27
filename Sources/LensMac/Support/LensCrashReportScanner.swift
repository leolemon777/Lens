import Foundation

struct LensCrashSummary: Codable, Equatable, Sendable {
    let incidentID: UUID
    let timestamp: Date
    let appVersion: String
    let build: String
    let exceptionType: String
    let signal: String
    let terminationNamespace: String
    let terminationCode: Int
    let faultingThread: Int?
}

@MainActor
final class LensCrashReportScanner {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    private let directory: URL
    private let fileManager: FileManager
    private let maximumReportBytes: Int

    init(
        directory: URL = LensCrashReportScanner.defaultDirectory,
        fileManager: FileManager = .default,
        maximumReportBytes: Int = 10 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumReportBytes = max(maximumReportBytes, 1_024)
    }

    func recentReports(limit: Int = 5) -> [LensCrashSummary] {
        guard limit > 0,
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls.compactMap { url -> (Date, URL)? in
            guard url.lastPathComponent.hasPrefix("Lens-"),
                  url.pathExtension == "ips",
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (values.contentModificationDate ?? .distantPast, url)
        }
        .sorted { $0.0 > $1.0 }
        .prefix(limit)
        .compactMap { parse($0.1) }
        .sorted { $0.timestamp > $1.timestamp }
    }

    private func parse(_ url: URL) -> LensCrashSummary? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              byteCount > 0,
              byteCount <= maximumReportBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let lineBreak = data.firstIndex(of: 0x0A) else {
            return nil
        }

        let headerData = data[..<lineBreak]
        let bodyStart = data.index(after: lineBreak)
        let bodyData = data[bodyStart...]
        guard let header = jsonObject(Data(headerData)),
              let body = jsonObject(Data(bodyData)),
              header["bundleID"] as? String == "app.lens.mac",
              header["app_name"] as? String == "Lens",
              let incidentString = header["incident_id"] as? String,
              let incidentID = UUID(uuidString: incidentString),
              let timestampString = header["timestamp"] as? String,
              let timestamp = Self.crashDateFormatter.date(from: timestampString),
              let appVersion = safeIdentifier(header["app_version"] as? String),
              let build = safeIdentifier(header["build_version"] as? String),
              let exception = body["exception"] as? [String: Any],
              let exceptionType = safeIdentifier(exception["type"] as? String),
              let signal = safeIdentifier(exception["signal"] as? String),
              let termination = body["termination"] as? [String: Any],
              let terminationNamespace = safeIdentifier(termination["namespace"] as? String),
              let terminationCode = integer(termination["code"]) else {
            return nil
        }

        return LensCrashSummary(
            incidentID: incidentID,
            timestamp: timestamp,
            appVersion: appVersion,
            build: build,
            exceptionType: exceptionType,
            signal: signal,
            terminationNamespace: terminationNamespace,
            terminationCode: terminationCode,
            faultingThread: integer(body["faultingThread"])
        )
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func safeIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 80 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static let crashDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter
    }()
}
