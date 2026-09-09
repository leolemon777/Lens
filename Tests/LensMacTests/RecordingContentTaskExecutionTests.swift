import Foundation
import XCTest
@testable import LensMac

@MainActor
final class RecordingContentTaskExecutionTests: XCTestCase {
    func testExecutionAdvancesRequestedPhaseBeforeWorkerRuns() async throws {
        let coordinator = RecordingTaskCoordinator()
        let execution = RecordingContentTaskExecution(coordinator: coordinator)
        let packageURL = URL(fileURLWithPath: "/tmp/content-execution-phase.lens")
        var receivedToken: RecordingTaskToken?
        var phaseAtWorker: RecordingTaskPhase?

        let result: String = try await execution.run(
            packageURL: packageURL,
            kind: .transcription,
            version: "phase-v1",
            priority: .userInitiated,
            phase: .transcription
        ) { token in
            receivedToken = token
            phaseAtWorker = await coordinator.activeSnapshots().first?.phase
            return "done"
        }

        XCTAssertEqual(result, "done")
        XCTAssertEqual(receivedToken?.kind, .transcription)
        XCTAssertEqual(receivedToken?.version, "phase-v1")
        XCTAssertEqual(phaseAtWorker, .transcription)
        let snapshot = await coordinator.snapshot(
            packageURL: packageURL,
            kind: .transcription,
            version: "phase-v1"
        )
        XCTAssertEqual(snapshot?.outcome, .completed)
    }

    func testExecutionPropagatesWorkerFailureAndRecordsIt() async {
        struct InjectedFailure: Error, Sendable {}

        let coordinator = RecordingTaskCoordinator()
        let execution = RecordingContentTaskExecution(coordinator: coordinator)
        let packageURL = URL(fileURLWithPath: "/tmp/content-execution-failure.lens")

        do {
            let _: String = try await execution.run(
                packageURL: packageURL,
                kind: .organization,
                version: "failure-v1",
                priority: .background,
                phase: .organization
            ) { _ in
                throw InjectedFailure()
            }
            XCTFail("Expected the injected content-worker failure")
        } catch is InjectedFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let snapshot = await coordinator.snapshot(
            packageURL: packageURL,
            kind: .organization,
            version: "failure-v1"
        )
        XCTAssertEqual(snapshot?.outcome, .failed)
        XCTAssertEqual(snapshot?.phase, .failed)
        XCTAssertNil(snapshot?.cancellationReason)
    }
}
