import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingTranscriptionTaskCoordinatorTests: XCTestCase {
    private struct InjectedFailure: Error, Sendable {}

    private final class StateBox: @unchecked Sendable {
        var busyStates: [Bool] = []
        var attached = false
        var attachFailure = false
        var planWritten = false
        var planFailure = false
        var captionsEnabled = false
        var organizationStarted = false
        var renderCount = 0
        var completed = false
        var failureCode = ""
        var cancelledCount = 0
        var cleanupCount = 0
    }

    func testCoordinatorPersistsTranscriptEnablesFirstCaptionsAndContinuesPipeline() async throws {
        let entry = makeEntry()
        let state = StateBox()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let document = makeTranscript()
        let worker = RecordingTranscriptionWorker { request in
            XCTAssertEqual(request.entry, entry)
            return document
        }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: document
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: false) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertTrue(state.attached)
        XCTAssertTrue(state.planWritten)
        XCTAssertTrue(state.organizationStarted)
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertTrue(state.completed)
        XCTAssertEqual(state.busyStates, [true, false])
        XCTAssertEqual(state.cleanupCount, 1)
        XCTAssertFalse(registry.contains(
            packageURL: entry.packageURL,
            kind: .transcription
        ))
    }

    func testAutomaticFailurePublishesSafeFailureAndFallsBackToRawRender() async throws {
        let entry = makeEntry()
        let state = StateBox()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let worker = RecordingTranscriptionWorker { _ in
            throw InjectedFailure()
        }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: makeTranscript()
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: true) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertEqual(state.failureCode, "transcription.failed")
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertFalse(state.attached)
        XCTAssertEqual(state.busyStates, [true, false])
        XCTAssertEqual(state.cleanupCount, 1)
    }

    func testAutomaticPersistenceFailureStillFallsBackToRawRender() async throws {
        let entry = makeEntry()
        let state = StateBox()
        state.attachFailure = true
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let document = makeTranscript()
        let worker = RecordingTranscriptionWorker { _ in document }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: document
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: true) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertEqual(state.failureCode, "transcription.failed")
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertFalse(state.attached)
        XCTAssertFalse(state.organizationStarted)
        XCTAssertEqual(state.busyStates, [true, false])
        XCTAssertEqual(state.cleanupCount, 1)
        XCTAssertFalse(registry.contains(
            packageURL: entry.packageURL,
            kind: .transcription
        ))
    }

    func testCancellationPublishesCancelledStateAndFinalizesWithoutFallback() async throws {
        let entry = makeEntry()
        let state = StateBox()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let worker = RecordingTranscriptionWorker { _ in
            throw CancellationError()
        }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: makeTranscript()
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: true) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertEqual(state.cancelledCount, 1)
        XCTAssertEqual(state.failureCode, "")
        XCTAssertEqual(state.renderCount, 0)
        XCTAssertEqual(state.cleanupCount, 1)
        XCTAssertEqual(state.busyStates, [true, false])
    }

    func testEmptyTranscriptSkipsCaptionPlanAndStillHandsOffOrganization() async throws {
        let entry = makeEntry()
        let state = StateBox()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let document = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: []
        )
        let worker = RecordingTranscriptionWorker { _ in document }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: document
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: false) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertTrue(state.attached)
        XCTAssertTrue(state.organizationStarted)
        XCTAssertFalse(state.planWritten)
        XCTAssertEqual(state.renderCount, 0)
        XCTAssertEqual(state.cleanupCount, 1)
    }

    func testExistingTranscriptDoesNotRewritePlanAndRendersEnabledCaptions() async throws {
        let entry = makeEntry(transcriptText: "已有文字")
        let state = StateBox()
        state.captionsEnabled = true
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let document = makeTranscript()
        let worker = RecordingTranscriptionWorker { _ in document }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: document
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: false) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertTrue(state.attached)
        XCTAssertTrue(state.organizationStarted)
        XCTAssertFalse(state.planWritten)
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertEqual(state.cleanupCount, 1)
    }

    func testManualPlanLoadFailureStopsDownstreamHandoff() async throws {
        let entry = makeEntry()
        let state = StateBox()
        state.planFailure = true
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let finalizer = makeFinalizer(registry: registry, state: state)
        let presentation = makePresentation(state: state)
        let document = makeTranscript()
        let worker = RecordingTranscriptionWorker { _ in document }
        let coordinator = makeCoordinator(
            entry: entry,
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            state: state,
            worker: worker,
            document: document
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.start(entry: entry, automatic: false) {
                state.cleanupCount += 1
            }
        )
        await task.value

        XCTAssertEqual(state.failureCode, "transcription.failed")
        XCTAssertTrue(state.attached)
        XCTAssertFalse(state.organizationStarted)
        XCTAssertEqual(state.renderCount, 0)
        XCTAssertEqual(state.cleanupCount, 1)
    }

    private func makeCoordinator(
        entry: LensLibraryEntry,
        registry: RecordingContentTaskRegistry,
        execution: RecordingContentTaskExecution,
        finalizer: RecordingContentTaskFinalizer,
        presentation: RecordingContentTaskPresentation,
        state: StateBox,
        worker: RecordingTranscriptionWorker,
        document: TranscriptDocument
    ) -> RecordingTranscriptionTaskCoordinator {
        RecordingTranscriptionTaskCoordinator(
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            workerFactory: { worker },
            attachTranscript: { _, _ in
                if state.attachFailure {
                    throw InjectedFailure()
                }
                state.attached = true
                return SavedLens(
                    packageURL: entry.packageURL,
                    rawAssetURL: entry.primaryAssetURL,
                    manifest: entry.manifest
                )
            },
            loadPlan: { _ in
                if state.planFailure {
                    throw InjectedFailure()
                }
                var plan = AutoEditPlan()
                if state.captionsEnabled {
                    plan.captions = .init(isEnabled: true)
                }
                return plan
            },
            writePlan: { _, _ in
                state.planWritten = true
                return SavedLens(
                    packageURL: entry.packageURL,
                    rawAssetURL: entry.primaryAssetURL,
                    manifest: entry.manifest
                )
            },
            startOrganization: { _, received in
                XCTAssertEqual(received, document)
                state.organizationStarted = true
            },
            render: { _ in
                state.renderCount += 1
                return nil
            },
            loadManifest: { _ in entry.manifest },
            setTranscribing: { _, active in
                state.busyStates.append(active)
            }
        )
    }

    private func makeFinalizer(
        registry: RecordingContentTaskRegistry,
        state: StateBox
    ) -> RecordingContentTaskFinalizer {
        RecordingContentTaskFinalizer(
            recordMetrics: { _, _, _ in },
            finishRegistry: { packageURL, kind in
                registry.finish(packageURL: packageURL, kind: kind)
            },
            setTranscribing: { _, active in
                state.busyStates.append(active)
            },
            setOrganizing: { _, _ in },
            startMigration: {}
        )
    }

    private func makePresentation(
        state: StateBox
    ) -> RecordingContentTaskPresentation {
        RecordingContentTaskPresentation(
            reloadLibrary: {
                state.completed = true
            },
            showToast: { title, _, _ in
                if title == "转写已取消" {
                    state.cancelledCount += 1
                }
            },
            recordDiagnostic: { _, _, _ in },
            recordFailure: { code, _ in
                state.failureCode = code
            }
        )
    }

    private func makeEntry(transcriptText: String? = nil) -> LensLibraryEntry {
        let packageURL = URL(fileURLWithPath: "/tmp/transcription-coordinator.lens")
        let manifest = LensManifest(
            kind: .recording,
            title: "coordinator",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        return LensLibraryEntry(
            packageURL: packageURL,
            manifest: manifest,
            primaryAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            displayAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            ocrText: nil,
            transcriptText: transcriptText
        )
    }

    private func makeTranscript() -> TranscriptDocument {
        TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: [TranscriptSegment(
                startSeconds: 0,
                endSeconds: 1,
                text: "演示",
                confidence: 1
            )]
        )
    }
}
