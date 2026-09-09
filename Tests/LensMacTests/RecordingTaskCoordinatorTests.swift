import Foundation
import XCTest
@testable import LensMac

final class RecordingTaskCoordinatorTests: XCTestCase {
    func testBackgroundWorkDefersDuringRecordingButFinalizationDoesNot() {
        XCTAssertTrue(
            RecordingTaskSchedulingPolicy.shouldDefer(
                priority: .background,
                whileRecording: true
            )
        )
        XCTAssertFalse(
            RecordingTaskSchedulingPolicy.shouldDefer(
                priority: .recordingFinalization,
                whileRecording: true
            )
        )
        XCTAssertFalse(
            RecordingTaskSchedulingPolicy.shouldDefer(
                priority: .background,
                whileRecording: false
            )
        )
    }

    func testAdmissionPreventsDuplicatePendingTranscription() {
        XCTAssertEqual(
            RecordingTaskSchedulingPolicy.admission(
                priority: .background,
                whileRecording: true,
                isActive: true,
                isPending: false,
                activeCount: 1
            ),
            .alreadyQueued
        )
        XCTAssertEqual(
            RecordingTaskSchedulingPolicy.admission(
                priority: .background,
                whileRecording: true,
                isActive: false,
                isPending: false,
                activeCount: 0
            ),
            .deferredWhileRecording
        )
        XCTAssertEqual(
            RecordingTaskSchedulingPolicy.admission(
                priority: .userInitiated,
                whileRecording: false,
                isActive: false,
                isPending: false,
                activeCount: 1
            ),
            .atCapacity
        )
        XCTAssertEqual(
            RecordingTaskSchedulingPolicy.admission(
                priority: .recordingFinalization,
                whileRecording: true,
                isActive: false,
                isPending: false,
                activeCount: 0
            ),
            .start
        )
    }

    func testSameVersionRequestsCoalesceAndNewVersionCancelsOldWork() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/coordinator.lens")
        let firstDate = Date(timeIntervalSince1970: 100)
        let first = await coordinator.begin(
            packageURL: package,
            kind: .transcription,
            version: "manifest-1",
            priority: .background,
            now: firstDate
        )
        let duplicate = await coordinator.begin(
            packageURL: package,
            kind: .transcription,
            version: "manifest-1",
            priority: .background,
            now: firstDate.addingTimeInterval(1)
        )
        XCTAssertEqual(first, duplicate)

        await coordinator.advance(
            first,
            to: .transcription,
            now: firstDate.addingTimeInterval(2)
        )
        let replacement = await coordinator.begin(
            packageURL: package,
            kind: .transcription,
            version: "manifest-2",
            priority: .userInitiated,
            now: firstDate.addingTimeInterval(3)
        )
        XCTAssertNotEqual(first, replacement)

        let history = await coordinator.recentSnapshots()
        let cancelled = try XCTUnwrap(history.first(where: { $0.token == first }))
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.cancellationReason, .superseded)
        XCTAssertEqual(try XCTUnwrap(cancelled.queueDurationMilliseconds), 2_000, accuracy: 0.001)
    }

    func testPhaseMetricsRecordQueueAndExecutionDurations() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/metrics.lens")
        let start = Date(timeIntervalSince1970: 500)
        let token = await coordinator.begin(
            packageURL: package,
            kind: .render,
            version: "plan-1",
            priority: .recordingFinalization,
            now: start
        )
        await coordinator.advance(token, to: .effects, now: start.addingTimeInterval(1.5))
        await coordinator.advance(token, to: .verification, now: start.addingTimeInterval(4))
        await coordinator.finish(
            token,
            outcome: .completed,
            now: start.addingTimeInterval(6)
        )

        let snapshots = await coordinator.recentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.outcome, .completed)
        XCTAssertEqual(try XCTUnwrap(snapshot.queueDurationMilliseconds), 1_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.executionDurationMilliseconds), 4_500, accuracy: 0.001)
        let lookedUp = await coordinator.snapshot(
            packageURL: package,
            kind: .render,
            version: "plan-1"
        )
        XCTAssertEqual(lookedUp, snapshot)
    }

    func testRunRecordsCompletedWorkerAndReturnsValue() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/run-completed.lens")
        let value = try await coordinator.run(
            packageURL: package,
            kind: .organization,
            version: "v1",
            priority: .background
        ) { token in
            await coordinator.advance(token, to: .organization)
            return "organized"
        }

        XCTAssertEqual(value, "organized")
        let snapshots = await coordinator.recentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(snapshot.outcome, .completed)
        XCTAssertEqual(snapshot.phase, .completed)
    }

    func testRunClassifiesInjectedFailureAndCancellation() async throws {
        enum InjectedFailure: Error { case fault }
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/run-faults.lens")

        do {
            _ = try await coordinator.run(
                packageURL: package,
                kind: .render,
                version: "fault",
                priority: .userInitiated
            ) { token in
                await coordinator.advance(token, to: .effects)
                throw InjectedFailure.fault
            } as String
            XCTFail("expected injected failure")
        } catch is InjectedFailure {
            // expected
        }

        do {
            _ = try await coordinator.run(
                packageURL: package,
                kind: .render,
                version: "cancelled",
                priority: .userInitiated
            ) { _ in
                throw CancellationError()
            } as String
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let history = await coordinator.recentSnapshots()
        XCTAssertEqual(history.map(\.outcome), [.failed, .cancelled])
        XCTAssertEqual(history.map(\.phase), [.failed, .cancelled])
        XCTAssertEqual(history.last?.cancellationReason, .operationCancelled)
    }

    func testExplicitPackageCancellationRecordsUserRequestedReason() async throws {
        let coordinator = RecordingTaskCoordinator()
        let package = URL(fileURLWithPath: "/tmp/user-cancel.lens")
        _ = await coordinator.begin(
            packageURL: package,
            kind: .render,
            version: "v1",
            priority: .userInitiated
        )

        await coordinator.cancel(packageURL: package)

        let snapshots = await coordinator.recentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(snapshot.outcome, .cancelled)
        XCTAssertEqual(snapshot.cancellationReason, .userRequested)
    }

    func testRunDoesNotExecuteDuplicateVersionOperation() async throws {
        actor Counter {
            var value = 0

            func increment() { value += 1 }
            func read() -> Int { value }
        }

        let coordinator = RecordingTaskCoordinator()
        let counter = Counter()
        let package = URL(fileURLWithPath: "/tmp/run-duplicate.lens")
        let first = Task {
            try await coordinator.run(
                packageURL: package,
                kind: .organization,
                version: "same",
                priority: .background
            ) { _ in
                await counter.increment()
                try await Task.sleep(nanoseconds: 50_000_000)
                return "first"
            }
        }

        for _ in 0..<100 where await counter.read() == 0 {
            await Task.yield()
        }

        do {
            _ = try await coordinator.run(
                packageURL: package,
                kind: .organization,
                version: "same",
                priority: .background
            ) { _ in
                await counter.increment()
                return "duplicate"
            } as String
            XCTFail("expected duplicate work to be rejected")
        } catch is CancellationError {
            // expected: the first worker owns this package/version
        }

        let result = try await first.value
        let count = await counter.read()
        XCTAssertEqual(result, "first")
        XCTAssertEqual(count, 1)
    }
}
