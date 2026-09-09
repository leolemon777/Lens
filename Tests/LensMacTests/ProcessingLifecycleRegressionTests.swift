import Foundation
import XCTest
@testable import LensMac

final class ProcessingLifecycleRegressionTests: XCTestCase {
    func testMixedAudioSidecarCleanupIsOutsidePreparationScope() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderPipeline.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("defer {\n            if let mixedAudioSidecarURL")
        )
        XCTAssertFalse(
            source.contains("if let mixedAudioSidecarURL, let audioPlan = plan.audio {\n                defer"),
            "The sidecar must remain available while the asynchronous renderer consumes it."
        )
    }

    func testRenderPublishesOnlyAfterVerificationThroughUniqueWorkingFile() throws {
        let execution = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderExecution.swift"
                ),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(execution.contains("previews/.auto-\\(request.generation.uuidString).mp4"))
        XCTAssertTrue(execution.contains("if pipelineResult.renderedEffectVerification.isVerified"))
        XCTAssertTrue(execution.contains("publishRenderedPreview("))
        XCTAssertTrue(execution.contains("updated = saved"))
        XCTAssertTrue(appDelegate.contains("recordingRenderTaskCoordinator.process(saved)"))
        let publishOffset = try XCTUnwrap(execution.range(of: "publishRenderedPreview("))
        let healthOffset = try XCTUnwrap(
            execution.range(of: "preview.health_report_write_failed")
        )
        XCTAssertGreaterThan(
            execution.distance(from: execution.startIndex, to: healthOffset.lowerBound),
            execution.distance(from: execution.startIndex, to: publishOffset.lowerBound),
            "health evidence must be persisted after a verified preview is published"
        )
    }

    func testRenderOutcomePresentationIsDelegatedToBoundary() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderPresentation.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("recordingRenderTaskCoordinator.process(saved)"))
        XCTAssertTrue(appDelegate.contains("makeRecordingRenderTaskCoordinator()"))
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderTaskCoordinator.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(coordinator.contains("presentation.present("))
        XCTAssertTrue(coordinator.contains("presentation.presentCancellation("))
        XCTAssertTrue(coordinator.contains("presentation.presentFailure("))
        XCTAssertTrue(coordinator.contains("pipelineResult.presenterWasRendered"))
        XCTAssertFalse(appDelegate.contains("private func performProcessRecording("))
        XCTAssertFalse(appDelegate.contains("private lazy var recordingRenderWorker"))
        XCTAssertFalse(appDelegate.contains("previewRenderer.lastPresenterCameraError"))
        XCTAssertTrue(appDelegate.contains("makeRecordingRenderPresentation()"))
        XCTAssertFalse(appDelegate.contains("let quickAccessConfirmation"))
        XCTAssertTrue(presentation.contains("updateQuickAccess("))
        XCTAssertTrue(presentation.contains("preview.completed"))
        XCTAssertTrue(presentation.contains("renderEncodePassCount"))
        XCTAssertTrue(presentation.contains("renderMilliseconds"))
        XCTAssertTrue(presentation.contains("preview.cancelled"))
        XCTAssertTrue(presentation.contains("preview.failed"))
        let pipeline = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderPipeline.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(pipeline.contains("presenterWasRendered"))
        XCTAssertTrue(pipeline.contains("lastRenderMetrics"))
        XCTAssertTrue(pipeline.contains("renderEncodePassCount"))
        XCTAssertTrue(pipeline.contains("renderElapsedMilliseconds"))
        XCTAssertTrue(pipeline.contains("renderPeakPhysicalFootprintBytes"))
    }

    func testContentTaskPresentationIsDelegatedToBoundary() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingContentTaskPresentation.swift"
                ),
            encoding: .utf8
        )
        let organizationCoordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingOrganizationTaskCoordinator.swift"
                ),
            encoding: .utf8
        )
        let transcriptionCoordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingTranscriptionTaskCoordinator.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("makeRecordingContentTaskPresentation()"))
        XCTAssertTrue(presentation.contains("transcriptionFailed"))
        XCTAssertTrue(presentation.contains("organizationFailed"))
        XCTAssertTrue(transcriptionCoordinator.contains("presentation.transcriptionCompleted("))
        XCTAssertTrue(organizationCoordinator.contains("presentation.organizationCompleted("))
    }

    func testTaskMetricsAreDelegatedToReporterBoundary() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let reporter = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingTaskMetricsReporter.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("recordingTaskMetricsReporter.record("))
        XCTAssertTrue(appDelegate.contains("makeRecordingTaskMetricsReporter()"))
        XCTAssertFalse(appDelegate.contains("private func recordTaskMetrics("))
        XCTAssertTrue(reporter.contains("queueMilliseconds"))
        XCTAssertTrue(reporter.contains("task.\\(kind.rawValue).\\(outcome.rawValue)"))
    }

    func testContentTaskCleanupIsDelegatedToFinalizerBoundary() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let finalizer = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingContentTaskFinalizer.swift"
                ),
            encoding: .utf8
        )
        let organizationCoordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingOrganizationTaskCoordinator.swift"
                ),
            encoding: .utf8
        )
        let transcriptionCoordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingTranscriptionTaskCoordinator.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("makeRecordingContentTaskFinalizer()"))
        XCTAssertTrue(finalizer.contains("startMigration()"))
        XCTAssertTrue(finalizer.contains("finishTranscription"))
        XCTAssertTrue(finalizer.contains("finishOrganization"))
        XCTAssertTrue(organizationCoordinator.contains("finalizer.finishOrganization("))
        XCTAssertTrue(transcriptionCoordinator.contains("finalizer.finishTranscription("))
    }

    func testOrganizationTaskLifecycleIsDelegatedToCoordinator() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingOrganizationTaskCoordinator.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("recordingOrganizationTaskCoordinator.begin("))
        XCTAssertTrue(appDelegate.contains("makeRecordingOrganizationTaskCoordinator()"))
        XCTAssertFalse(appDelegate.contains("recordingContentTaskExecution.run(\n                    packageURL: packageKey,\n                    kind: .organization"))
        XCTAssertTrue(coordinator.contains("finalizer.finishOrganization("))
        XCTAssertTrue(coordinator.contains("presentation.organizationCompleted("))
        XCTAssertTrue(coordinator.contains("presentation.organizationFailed("))
        XCTAssertTrue(coordinator.contains("attachInsights(insights, lens)"))
    }

    func testTranscriptionTaskLifecycleIsDelegatedToCoordinator() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingTranscriptionTaskCoordinator.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("recordingTranscriptionTaskCoordinator.start("))
        XCTAssertTrue(appDelegate.contains("makeRecordingTranscriptionTaskCoordinator()"))
        XCTAssertFalse(appDelegate.contains("recordingContentTaskExecution.run(\n                    packageURL: packageKey,\n                    kind: .transcription"))
        XCTAssertTrue(coordinator.contains("finalizer.finishTranscription("))
        XCTAssertTrue(coordinator.contains("presentation.transcriptionCompleted("))
        XCTAssertTrue(coordinator.contains("presentation.transcriptionFailed("))
        XCTAssertTrue(coordinator.contains("attachTranscript(document, saved)"))
        XCTAssertTrue(coordinator.contains("startOrganization(updatedLens, document)"))
    }

    func testAutomaticTranscriptionQueueIsDelegatedToBoundary() throws {
        let appDelegate = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let queue = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingContentTaskQueue.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegate.contains("RecordingContentTaskQueue()"))
        XCTAssertTrue(appDelegate.contains("pendingAutomaticTranscriptions.enqueue("))
        XCTAssertTrue(appDelegate.contains("pendingAutomaticTranscriptions.dequeue()"))
        XCTAssertTrue(appDelegate.contains("resumePendingAutomaticTranscriptions()"))
        XCTAssertTrue(appDelegate.contains("startNextPendingAutomaticTranscriptionIfIdle()"))
        XCTAssertTrue(queue.contains("contains(lensID:"))
        XCTAssertTrue(queue.contains("requeueFront"))
        XCTAssertTrue(queue.contains("maximumAttempts"))
        XCTAssertTrue(queue.contains("recoverableRecords"))
        XCTAssertTrue(queue.contains("discardExhaustedRecords"))
    }

    func testOrganizationWorkerPropagatesCancellationToDetachedReadTask() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingOrganizationWorker.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let work = Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("withTaskCancellationHandler(operation: {"))
        XCTAssertTrue(source.contains("work.cancel()"))
        XCTAssertTrue(source.contains("try Task.checkCancellation()"))
    }
}
