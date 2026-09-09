import AppKit
import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingRenderTaskCoordinatorTests: XCTestCase {
    func testCancellationFinishesTaskAndStartsPendingMigration() async {
        let packageURL = URL(fileURLWithPath: "/tmp/render-coordinator-\(UUID().uuidString).lens")
        let saved = SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: LensManifest(
                kind: .recording,
                title: "coordinator",
                dimensions: LensDimensions(width: 1, height: 1),
                assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
            )
        )
        var didPresentCancellation = false
        var didRecordCancellation = false
        var migrationStarts = 0
        let presentation = RecordingRenderPresentation(
            reloadLibrary: {},
            deliveryImage: { _ in NSImage(size: NSSize(width: 1, height: 1)) },
            updateQuickAccess: { _, _, _, state in
                didPresentCancellation = state == .cancelled
            },
            showToast: { _, _, _ in },
            recordDiagnostic: { code, _, _ in
                didRecordCancellation = code == "preview.cancelled"
            }
        )
        let execution = RecordingRenderExecution { _ in
            throw CancellationError()
        }
        let metrics = RecordingTaskMetricsReporter(
            loadSnapshot: { _, _, _ in nil },
            recordDiagnostic: { _, _, _ in }
        )
        let taskCoordinator = RecordingTaskCoordinator()
        let registry = RecordingRenderTaskRegistry()
        let coordinator = RecordingRenderTaskCoordinator(
            taskCoordinator: taskCoordinator,
            registry: registry,
            execution: execution,
            presentation: presentation,
            metrics: metrics,
            startMigration: { migrationStarts += 1 }
        )

        let result = await coordinator.process(saved)

        XCTAssertNil(result)
        XCTAssertTrue(didPresentCancellation)
        XCTAssertTrue(didRecordCancellation)
        XCTAssertEqual(migrationStarts, 1)
        XCTAssertTrue(registry.activePackageURLs.isEmpty)
        let snapshots = await taskCoordinator.recentSnapshots()
        XCTAssertEqual(snapshots.last?.outcome, .cancelled)
        XCTAssertEqual(snapshots.last?.cancellationReason, .operationCancelled)
    }
}
