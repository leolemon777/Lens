import Foundation
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

final class LocalDiagnosticLogTests: XCTestCase {
    func testLogWritesJSONLinesAndReturnsRecentEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LocalDiagnosticLog(directory: directory, maximumBytes: 4_096)

        try await log.append(DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 10),
            code: "app.launched"
        ))
        try await log.append(DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 20),
            level: .error,
            code: "recording.failed",
            metadata: ["phase": "stop"]
        ))

        let events = await log.recentEvents(limit: 1)
        XCTAssertEqual(events.map(\.code), ["recording.failed"])
        let contents = try String(
            contentsOf: directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
    }

    func testLogRotatesActiveFileWithoutLosingLatestEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LocalDiagnosticLog(directory: directory, maximumBytes: 256)

        for index in 0..<4 {
            try await log.append(DiagnosticEvent(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                code: "diagnostic.event_\(index)",
                metadata: ["status": String(repeating: "x", count: 70)]
            ))
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("events.previous.jsonl").path
        ))
        let events = await log.recentEvents(limit: 20)
        XCTAssertEqual(events.last?.code, "diagnostic.event_3")
        XCTAssertLessThanOrEqual(events.count, 4)
    }

    func testSummaryContainsOnlySafeOperationalInformation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = LocalDiagnosticLog(directory: directory)
        try await log.append(DiagnosticEvent(
            code: "transcription.failed",
            metadata: ["errorDomain": "Speech.Error", "errorCode": "7"]
        ))

        let summary = await log.makeSummary(
            appVersion: "0.1",
            build: "1",
            systemVersion: "15.0",
            architecture: "arm64",
            permissions: ["screenCapture": "granted"]
        )

        XCTAssertTrue(summary.contains("transcription.failed"))
        XCTAssertTrue(summary.contains("screenCapture=granted"))
        XCTAssertFalse(summary.contains("/Users/"))
        XCTAssertFalse(summary.contains("secret transcript"))
    }
}
