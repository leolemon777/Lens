import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingOrganizationTaskCoordinatorTests: XCTestCase {
    private struct InjectedFailure: Error, Sendable {}
    private final class BusyStateBox: @unchecked Sendable {
        var values: [Bool] = []
    }

    func testCoordinatorRunsWorkerPersistsInsightsAndFinalizesBusyState() async throws {
        let lens = makeLens()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let busyStates = BusyStateBox()
        var attachedTitle = ""
        var completed = false
        let presentation = makePresentation(
            completed: { completed = true }
        )
        let finalizer = makeFinalizer(
            registry: registry,
            busyStates: busyStates
        )
        let worker = RecordingOrganizationWorker { request in
            XCTAssertEqual(request.lens, lens)
            return LensInsightsDocument(
                engine: "test",
                suggestedTitle: "整理后的标题",
                summary: "摘要",
                tags: []
            )
        }
        let coordinator = RecordingOrganizationTaskCoordinator(
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            workerFactory: { worker },
            attachInsights: { insights, _ in
                attachedTitle = insights.suggestedTitle
            },
            setOrganizing: { _, active in
                busyStates.values.append(active)
            }
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.begin(lens: lens, announcesResult: true)
        )
        await task.value

        XCTAssertEqual(attachedTitle, "整理后的标题")
        XCTAssertTrue(completed)
        XCTAssertEqual(busyStates.values, [true, false])
        XCTAssertFalse(registry.contains(
            packageURL: lens.packageURL,
            kind: .organization
        ))
    }

    func testCoordinatorRoutesWorkerFailureToPresentationAndStillFinalizes() async throws {
        let lens = makeLens()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let busyStates = BusyStateBox()
        var failureCode = ""
        let presentation = makePresentation(
            failure: { failureCode = $0 }
        )
        let finalizer = makeFinalizer(
            registry: registry,
            busyStates: busyStates
        )
        let worker = RecordingOrganizationWorker { _ in
            throw InjectedFailure()
        }
        let coordinator = RecordingOrganizationTaskCoordinator(
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            workerFactory: { worker },
            attachInsights: { _, _ in
                XCTFail("failed organization must not attach insights")
            },
            setOrganizing: { _, active in
                busyStates.values.append(active)
            }
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.begin(lens: lens, announcesResult: true)
        )
        await task.value

        XCTAssertEqual(failureCode, "organization.failed")
        XCTAssertEqual(busyStates.values, [true, false])
        XCTAssertFalse(registry.contains(
            packageURL: lens.packageURL,
            kind: .organization
        ))
    }

    func testCoordinatorRoutesPersistenceFailureToPresentationAndStillFinalizes() async throws {
        let lens = makeLens()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let busyStates = BusyStateBox()
        var failureCode = ""
        let presentation = makePresentation(
            failure: { failureCode = $0 }
        )
        let finalizer = makeFinalizer(
            registry: registry,
            busyStates: busyStates
        )
        let worker = RecordingOrganizationWorker { _ in
            LensInsightsDocument(
                engine: "test",
                suggestedTitle: "标题",
                summary: "摘要",
                tags: []
            )
        }
        let coordinator = RecordingOrganizationTaskCoordinator(
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            workerFactory: { worker },
            attachInsights: { _, _ in
                throw InjectedFailure()
            },
            setOrganizing: { _, active in
                busyStates.values.append(active)
            }
        )

        let task: Task<Void, Never> = try XCTUnwrap(
            coordinator.begin(lens: lens, announcesResult: true)
        )
        await task.value

        XCTAssertEqual(failureCode, "organization.failed")
        XCTAssertEqual(busyStates.values, [true, false])
        XCTAssertFalse(registry.contains(
            packageURL: lens.packageURL,
            kind: .organization
        ))
    }

    func testDuplicateOrganizationAdmissionDoesNotStartSecondWorker() async throws {
        let lens = makeLens()
        let registry = RecordingContentTaskRegistry()
        let execution = RecordingContentTaskExecution(
            coordinator: RecordingTaskCoordinator()
        )
        let busyStates = BusyStateBox()
        var duplicateNoticeShown = false
        var workerCalls = 0
        let presentation = makePresentation(
            duplicate: { duplicateNoticeShown = true }
        )
        let finalizer = makeFinalizer(
            registry: registry,
            busyStates: busyStates
        )
        let worker = RecordingOrganizationWorker { _ in
            workerCalls += 1
            return LensInsightsDocument(
                engine: "test",
                suggestedTitle: "标题",
                summary: "摘要",
                tags: []
            )
        }
        let coordinator = RecordingOrganizationTaskCoordinator(
            registry: registry,
            execution: execution,
            finalizer: finalizer,
            presentation: presentation,
            workerFactory: { worker },
            attachInsights: { _, _ in },
            setOrganizing: { _, active in
                busyStates.values.append(active)
            }
        )

        let first: Task<Void, Never> = try XCTUnwrap(
            coordinator.begin(lens: lens, announcesResult: true)
        )
        XCTAssertNil(coordinator.begin(lens: lens, announcesResult: true))
        await first.value

        XCTAssertTrue(duplicateNoticeShown)
        XCTAssertEqual(workerCalls, 1)
        XCTAssertEqual(busyStates.values, [true, false])
    }

    private func makeLens() -> SavedLens {
        let packageURL = URL(fileURLWithPath: "/tmp/organization-coordinator.lens")
        let manifest = LensManifest(
            kind: .recording,
            title: "coordinator",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: manifest
        )
    }

    private func makeFinalizer(
        registry: RecordingContentTaskRegistry,
        busyStates: BusyStateBox
    ) -> RecordingContentTaskFinalizer {
        RecordingContentTaskFinalizer(
            recordMetrics: { _, _, _ in },
            finishRegistry: { packageURL, kind in
                registry.finish(packageURL: packageURL, kind: kind)
            },
            setTranscribing: { _, _ in },
            setOrganizing: { _, active in
                busyStates.values.append(active)
            },
            startMigration: {}
        )
    }

    private func makePresentation(
        completed: @escaping @MainActor @Sendable () -> Void = {},
        failure: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        duplicate: @escaping @MainActor @Sendable () -> Void = {}
    ) -> RecordingContentTaskPresentation {
        RecordingContentTaskPresentation(
            reloadLibrary: completed,
            showToast: { title, _, _ in
                if title == "这条 Lens 正在整理" {
                    duplicate()
                }
            },
            recordDiagnostic: { _, _, _ in },
            recordFailure: { code, _ in
                failure(code)
            }
        )
    }
}
