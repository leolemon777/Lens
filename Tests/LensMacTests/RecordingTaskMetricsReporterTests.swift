import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingTaskMetricsReporterTests: XCTestCase {
    func testCompletedSnapshotProducesAllowlistedTimingMetadata() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/metrics-reporter.lens")
        let start = Date(timeIntervalSince1970: 100)
        let token = await coordinator.begin(
            packageURL: package,
            kind: .render,
            version: "v1",
            priority: .recordingFinalization,
            now: start
        )
        await coordinator.advance(token, to: .effects, now: start.addingTimeInterval(1))
        await coordinator.finish(
            token,
            outcome: .completed,
            now: start.addingTimeInterval(4)
        )

        var event: (String, DiagnosticLevel, [String: String])?
        let reporter = RecordingTaskMetricsReporter(
            loadSnapshot: { packageURL, kind, version in
                await coordinator.snapshot(
                    packageURL: packageURL,
                    kind: kind,
                    version: version
                )
            },
            recordDiagnostic: { code, level, metadata in
                event = (code, level, metadata)
            }
        )

        await reporter.record(
            packageURL: package,
            kind: .render,
            version: "v1"
        )

        XCTAssertEqual(event?.0, "task.render.completed")
        XCTAssertEqual(event?.1, .info)
        XCTAssertEqual(event?.2["phase"], "completed")
        XCTAssertEqual(event?.2["queueMilliseconds"], "1000")
        XCTAssertEqual(event?.2["executionMilliseconds"], "3000")
    }

    func testFailedSnapshotUsesWarningAndCancellationReason() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/metrics-reporter-failed.lens")
        let token = await coordinator.begin(
            packageURL: package,
            kind: .transcription,
            version: "v2",
            priority: .userInitiated,
            now: Date(timeIntervalSince1970: 200)
        )
        await coordinator.finish(
            token,
            outcome: .failed,
            now: Date(timeIntervalSince1970: 201)
        )

        var event: (String, DiagnosticLevel, [String: String])?
        let reporter = RecordingTaskMetricsReporter(
            loadSnapshot: { packageURL, kind, version in
                await coordinator.snapshot(
                    packageURL: packageURL,
                    kind: kind,
                    version: version
                )
            },
            recordDiagnostic: { code, level, metadata in
                event = (code, level, metadata)
            }
        )

        await reporter.record(
            packageURL: package,
            kind: .transcription,
            version: "v2"
        )

        XCTAssertEqual(event?.0, "task.transcription.failed")
        XCTAssertEqual(event?.1, .warning)
        XCTAssertEqual(event?.2["taskKind"], "transcription")
        XCTAssertNil(event?.2["cancellationReason"])
    }
}
