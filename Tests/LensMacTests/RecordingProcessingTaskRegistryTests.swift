import Foundation
import XCTest
@testable import LensMac

@MainActor
final class RecordingProcessingTaskRegistryTests: XCTestCase {
    func testReplacementCancelsPreviousTaskAndKeepsLatestOwner() async {
        let registry = RecordingProcessingTaskRegistry()
        let package = URL(fileURLWithPath: "/tmp/registry.lens")

        let first = makeWaitingTask()
        registry.track(first, for: package)
        XCTAssertEqual(registry.activePackageURLs, [package.standardizedFileURL])

        let second = makeWaitingTask()
        registry.track(second, for: package)
        await first.value
        XCTAssertEqual(registry.activePackageURLs, [package.standardizedFileURL])

        registry.cancel(for: package)
        await second.value
        await Task.yield()
        XCTAssertTrue(registry.activePackageURLs.isEmpty)
    }

    func testCancelAllReleasesEveryTrackedPackage() async {
        let registry = RecordingProcessingTaskRegistry()
        let firstPackage = URL(fileURLWithPath: "/tmp/registry-a.lens")
        let secondPackage = URL(fileURLWithPath: "/tmp/registry-b.lens")
        let first = makeWaitingTask()
        let second = makeWaitingTask()

        registry.track(first, for: firstPackage)
        registry.track(second, for: secondPackage)
        registry.cancelAll()
        await first.value
        await second.value
        XCTAssertTrue(registry.activePackageURLs.isEmpty)
    }

    private func makeWaitingTask() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
        }
    }
}
