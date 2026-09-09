import Foundation
import XCTest
@testable import LensMac

@MainActor
final class RecordingContentTaskFinalizerTests: XCTestCase {
    func testTranscriptionCleanupReleasesStateRunsHookAndStartsMigration() async {
        let log = CallLog()
        let finalizer = makeFinalizer(log: log)

        finalizer.finishTranscription(
            packageURL: URL(fileURLWithPath: "/tmp/finalizer.lens"),
            version: "v1",
            lensID: UUID()
        ) {
            log.values.append("after")
        }
        await Task.yield()

        XCTAssertEqual(
            log.values,
            ["finish-transcription", "transcribing-false", "after", "migration", "metrics-transcription"]
        )
    }

    func testOrganizationCleanupUsesOrganizationStateAndMetrics() async {
        let log = CallLog()
        let finalizer = makeFinalizer(log: log)

        finalizer.finishOrganization(
            packageURL: URL(fileURLWithPath: "/tmp/finalizer.lens"),
            version: "v2",
            lensID: UUID()
        )
        await Task.yield()

        XCTAssertEqual(
            log.values,
            ["finish-organization", "organizing-false", "migration", "metrics-organization"]
        )
    }

    private func makeFinalizer(log: CallLog) -> RecordingContentTaskFinalizer {
        RecordingContentTaskFinalizer(
            recordMetrics: { _, kind, _ in log.values.append("metrics-\(kind.rawValue)") },
            finishRegistry: { _, kind in
                log.values.append(
                    kind == .transcription
                        ? "finish-transcription"
                        : "finish-organization"
                )
            },
            setTranscribing: { _, active in
                log.values.append(active ? "transcribing-true" : "transcribing-false")
            },
            setOrganizing: { _, active in
                log.values.append(active ? "organizing-true" : "organizing-false")
            },
            startMigration: { log.values.append("migration") }
        )
    }

    private final class CallLog {
        var values: [String] = []
    }
}
