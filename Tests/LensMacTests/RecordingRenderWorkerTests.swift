import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingRenderWorkerTests: XCTestCase {
    func testWorkerForwardsTheStableRenderRequestAndResult() async throws {
        let manifest = LensManifest(
            kind: .recording,
            title: "worker",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        let saved = SavedLens(
            packageURL: URL(fileURLWithPath: "/tmp/worker.lens"),
            rawAssetURL: URL(fileURLWithPath: "/tmp/worker.lens/raw/screen.mp4"),
            manifest: manifest
        )
        let token = RecordingTaskToken(
            id: UUID(),
            packageURL: saved.packageURL,
            kind: .render,
            version: "v1"
        )
        let generation = UUID()
        var received: RecordingRenderWorkRequest?
        let worker = RecordingRenderWorker { request in
            received = request
            return AutoEditPlan()
        }

        let result = try await worker.run(
            RecordingRenderWorkRequest(
                saved: saved,
                generation: generation,
                taskToken: token
            )
        )

        XCTAssertEqual(received?.saved, saved)
        XCTAssertEqual(received?.generation, generation)
        XCTAssertEqual(received?.taskToken, token)
        XCTAssertNotNil(result)
    }

    func testWorkerPropagatesCancellationWithoutConvertingItToFailure() async {
        let worker = RecordingRenderWorker { _ in
            throw CancellationError()
        }

        do {
            _ = try await worker.run(
                RecordingRenderWorkRequest(
                    saved: SavedLens(
                        packageURL: URL(fileURLWithPath: "/tmp/cancel.lens"),
                        rawAssetURL: URL(fileURLWithPath: "/tmp/cancel.lens/raw/screen.mp4"),
                        manifest: LensManifest(
                            kind: .recording,
                            title: "cancel",
                            dimensions: LensDimensions(width: 1, height: 1),
                            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
                        )
                    ),
                    generation: UUID(),
                    taskToken: RecordingTaskToken(
                        id: UUID(),
                        packageURL: URL(fileURLWithPath: "/tmp/cancel.lens"),
                        kind: .render,
                        version: "v1"
                    )
                )
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the orchestration layer classifies cancellation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
