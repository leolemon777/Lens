import Foundation
import ScreenTraceCore

actor LocalDiagnosticLog {
    static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ScreenTrace/diagnostics", isDirectory: true)

    private let directory: URL
    private let activeURL: URL
    private let previousURL: URL
    private let maximumBytes: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directory: URL = LocalDiagnosticLog.defaultDirectory,
        maximumBytes: Int = 512 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        activeURL = directory.appendingPathComponent("events.jsonl")
        previousURL = directory.appendingPathComponent("events.previous.jsonl")
        self.maximumBytes = max(maximumBytes, 256)
        self.fileManager = fileManager

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func record(
        _ code: String,
        level: DiagnosticLevel = .info,
        metadata: [String: String] = [:]
    ) {
        try? append(DiagnosticEvent(level: level, code: code, metadata: metadata))
    }

    func append(_ event: DiagnosticEvent) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = try encoder.encode(event)
        line.append(0x0A)
        try rotateIfNeeded(adding: line.count)

        if !fileManager.fileExists(atPath: activeURL.path) {
            try line.write(to: activeURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: activeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func recentEvents(limit: Int = 30) -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        let events = readEvents(at: previousURL) + readEvents(at: activeURL)
        return Array(events.sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }

    func makeSummary(
        appVersion: String,
        build: String,
        systemVersion: String,
        architecture: String,
        permissions: [String: String],
        crashReports: [ScreenTraceCrashSummary] = [],
        eventLimit: Int = 20
    ) -> String {
        let events = recentEvents(limit: eventLimit)
        var lines = [
            "ScreenTrace 诊断摘要",
            "应用版本：\(appVersion) (\(build))",
            "系统：macOS \(systemVersion) / \(architecture)",
            "权限：" + permissions.keys.sorted().map {
                let value = permissions[$0] ?? "未知"
                return "\($0)=\(value)"
            }.joined(separator: ", "),
            "近期事件："
        ]
        if events.isEmpty {
            lines.append("- 无")
        } else {
            let formatter = ISO8601DateFormatter()
            for event in events {
                let metadata = event.metadata.keys.sorted().map {
                    let value = event.metadata[$0] ?? ""
                    return "\($0)=\(value)"
                }.joined(separator: ", ")
                let suffix = metadata.isEmpty ? "" : " [\(metadata)]"
                lines.append(
                    "- \(formatter.string(from: event.timestamp)) \(event.level.rawValue) \(event.code)\(suffix)"
                )
            }
        }
        lines.append("本机崩溃指纹：")
        if crashReports.isEmpty {
            lines.append("- 无")
        } else {
            let formatter = ISO8601DateFormatter()
            for report in crashReports {
                lines.append(
                    "- \(formatter.string(from: report.timestamp)) "
                        + "\(report.exceptionType)/\(report.signal) "
                        + "\(report.terminationNamespace):\(report.terminationCode) "
                        + "incident=\(report.incidentID.uuidString) "
                        + "version=\(report.appVersion)(\(report.build))"
                )
            }
        }
        lines.append("隐私：不包含截图、录屏、声音、转写正文、窗口标题或项目路径。")
        return lines.joined(separator: "\n")
    }

    private func rotateIfNeeded(adding byteCount: Int) throws {
        guard fileManager.fileExists(atPath: activeURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: activeURL.path)
        let currentBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentBytes + byteCount > maximumBytes else { return }
        if fileManager.fileExists(atPath: previousURL.path) {
            try fileManager.removeItem(at: previousURL)
        }
        try fileManager.moveItem(at: activeURL, to: previousURL)
    }

    private func readEvents(at url: URL) -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DiagnosticEvent.self, from: Data(line))
        }
    }
}
