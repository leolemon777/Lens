import Foundation
import XCTest
@testable import LensMac

@MainActor
final class LaunchHealthMonitorTests: XCTestCase {
    func testMarkerDetectsUncleanPreviousSessionAndNormalExitClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLaunchHealth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = LaunchHealthMonitor(directory: directory)
        XCTAssertFalse(first.beginSession(
            at: Date(timeIntervalSince1970: 10),
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            appVersion: "0.1.0",
            build: "1"
        ))

        let second = LaunchHealthMonitor(directory: directory)
        XCTAssertTrue(second.beginSession(
            at: Date(timeIntervalSince1970: 20),
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            appVersion: "0.1.0",
            build: "1"
        ))
        second.completeSession()

        let third = LaunchHealthMonitor(directory: directory)
        XCTAssertFalse(third.beginSession(
            appVersion: "0.1.0",
            build: "1"
        ))
    }

    func testCorruptMarkerStillSignalsUncleanExitAndIsSafelyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLaunchHealth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markerURL = directory.appendingPathComponent("session.active.json")
        try Data("private crash contents /Users/example/project".utf8)
            .write(to: markerURL, options: .atomic)

        let monitor = LaunchHealthMonitor(directory: directory)
        XCTAssertTrue(monitor.beginSession(appVersion: "0.1.0", build: "1"))

        let data = try Data(contentsOf: markerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let marker = try decoder.decode(LaunchSessionMarker.self, from: data)
        XCTAssertEqual(marker.appVersion, "0.1.0")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private crash contents"))
    }
}
