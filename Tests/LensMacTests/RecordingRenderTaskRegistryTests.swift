import Foundation
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class RecordingRenderTaskRegistryTests: XCTestCase {
    func testNewGenerationCancelsOldWorkerAndOwnsPublication() async {
        let registry = RecordingRenderTaskRegistry()
        let package = URL(fileURLWithPath: "/tmp/render-registry.lens")
        let firstGeneration = UUID()
        let first = makeWaitingTask()
        registry.track(first, for: package, generation: firstGeneration)

        let secondGeneration = UUID()
        let second = makeWaitingTask()
        registry.track(second, for: package, generation: secondGeneration)

        XCTAssertFalse(registry.isCurrent(packageURL: package, generation: firstGeneration))
        XCTAssertTrue(registry.isCurrent(packageURL: package, generation: secondGeneration))
        _ = await first.value
        XCTAssertFalse(
            registry.finish(
                packageURL: package,
                generation: firstGeneration,
                task: first
            )
        )

        registry.cancel(for: package)
        _ = await second.value
        XCTAssertTrue(
            registry.finish(
                packageURL: package,
                generation: secondGeneration,
                task: second
            )
        )
        XCTAssertTrue(registry.activePackageURLs.isEmpty)
    }

    private func makeWaitingTask() -> Task<AutoEditPlan?, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return nil
            }
            return nil
        }
    }
}
