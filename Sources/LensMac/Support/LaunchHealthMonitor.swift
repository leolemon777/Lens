import Foundation

struct LaunchSessionMarker: Codable, Equatable {
    let sessionID: UUID
    let startedAt: Date
    let appVersion: String
    let build: String
}

@MainActor
final class LaunchHealthMonitor {
    private let directory: URL
    private let markerURL: URL
    private let fileManager: FileManager

    init(
        directory: URL = LocalDiagnosticLog.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        markerURL = directory.appendingPathComponent("session.active.json")
        self.fileManager = fileManager
    }

    /// Returns true when the previous process did not reach normal termination.
    @discardableResult
    func beginSession(
        at date: Date = Date(),
        sessionID: UUID = UUID(),
        appVersion: String,
        build: String
    ) -> Bool {
        let previousSessionWasUnclean = fileManager.fileExists(atPath: markerURL.path)
        let marker = LaunchSessionMarker(
            sessionID: sessionID,
            startedAt: date,
            appVersion: appVersion,
            build: build
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            // Diagnostics must never prevent the app from launching.
        }
        return previousSessionWasUnclean
    }

    func completeSession() {
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        try? fileManager.removeItem(at: markerURL)
    }
}
