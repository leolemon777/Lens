import Foundation
import XCTest
@testable import LensMac

@MainActor
final class LensCrashReportScannerTests: XCTestCase {
    func testScannerExtractsOnlyAllowlistedCrashFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensCrashReports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("Lens-2026-08-09-120000.ips")
        let header = #"{"app_name":"Lens","timestamp":"2026-08-09 12:00:00.00 -0400","app_version":"0.1.0","build_version":"1","bundleID":"app.lens.mac","incident_id":"2C592755-38C7-4147-83C8-8C6C1AB50245"}"#
        let body = #"{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","private":"secret transcript"},"termination":{"namespace":"SIGNAL","code":5,"indicator":"/Users/example/private"},"faultingThread":5,"procPath":"/private/Lens","threads":[{"name":"secret window title"}]}"#
        try Data("\(header)\n\(body)".utf8).write(to: reportURL, options: .atomic)

        let reports = LensCrashReportScanner(directory: directory).recentReports()

        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.incidentID.uuidString, "2C592755-38C7-4147-83C8-8C6C1AB50245")
        XCTAssertEqual(report.exceptionType, "EXC_BREAKPOINT")
        XCTAssertEqual(report.signal, "SIGTRAP")
        XCTAssertEqual(report.terminationNamespace, "SIGNAL")
        XCTAssertEqual(report.terminationCode, 5)
        XCTAssertEqual(report.faultingThread, 5)
        XCTAssertFalse(String(describing: report).contains("/Users/"))
        XCTAssertFalse(String(describing: report).contains("secret transcript"))
    }

    func testScannerRejectsOtherBundlesSymlinksAndOversizedReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensCrashReports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let otherURL = directory.appendingPathComponent("Lens-other.ips")
        let header = #"{"app_name":"Lens","timestamp":"2026-08-09 12:00:00.00 -0400","app_version":"0.1","build_version":"1","bundleID":"example.other","incident_id":"2C592755-38C7-4147-83C8-8C6C1AB50245"}"#
        let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"namespace":"SIGNAL","code":11}}"#
        try Data("\(header)\n\(body)".utf8).write(to: otherURL, options: .atomic)
        let symlinkURL = directory.appendingPathComponent("Lens-link.ips")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: otherURL)

        let reports = LensCrashReportScanner(
            directory: directory,
            maximumReportBytes: 1_024
        ).recentReports(limit: 10)

        XCTAssertTrue(reports.isEmpty)
    }
}
