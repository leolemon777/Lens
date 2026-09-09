import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingContentTaskQueueTests: XCTestCase {
    func testQueueSuppressesDuplicateLensAndPreservesFIFO() {
        let queue = makeQueue()
        let first = makeEntry(id: UUID())
        let second = makeEntry(id: UUID())

        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(first))
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.dequeue()?.id, first.id)
        XCTAssertEqual(queue.dequeue()?.id, second.id)
        XCTAssertTrue(queue.isEmpty)
    }

    func testRequeueFrontSuppressesDuplicateAndRestoresPendingWork() {
        let queue = makeQueue()
        let first = makeEntry(id: UUID())
        let second = makeEntry(id: UUID())
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertTrue(queue.requeueFront(first))
        XCTAssertFalse(queue.requeueFront(first))

        XCTAssertEqual(queue.dequeue()?.id, first.id)
        XCTAssertEqual(queue.dequeue()?.id, second.id)
    }

    func testRunningCheckpointSurvivesReloadAndStopsAfterOneRecoveryRetry() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensQueueTests-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingContentTaskQueueStore(
            fileURL: directory.appendingPathComponent("queue.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = makeEntry(id: UUID())
        let queue = RecordingContentTaskQueue(store: store)
        XCTAssertTrue(queue.claim(entry))

        let reloaded = RecordingContentTaskQueue(store: store)
        XCTAssertEqual(reloaded.recoverableRecords.first?.attempts, 1)
        XCTAssertTrue(reloaded.restore(entry))
        XCTAssertEqual(reloaded.dequeue()?.id, entry.id)
        XCTAssertTrue(reloaded.claim(entry))
        XCTAssertFalse(reloaded.claim(entry))
        XCTAssertEqual(reloaded.discardExhaustedRecords(), 1)
        XCTAssertTrue(reloaded.recoverableRecords.isEmpty)
    }

    private func makeQueue() -> RecordingContentTaskQueue {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensQueueTests-\(UUID().uuidString).json")
        return RecordingContentTaskQueue(
            store: RecordingContentTaskQueueStore(fileURL: fileURL)
        )
    }

    private func makeEntry(id: UUID) -> LensLibraryEntry {
        let manifest = LensManifest(
            id: id,
            kind: .recording,
            title: "队列测试",
            dimensions: nil,
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        let package = URL(fileURLWithPath: "/tmp/\(id.uuidString).lens")
        return LensLibraryEntry(
            packageURL: package,
            manifest: manifest,
            primaryAssetURL: package.appendingPathComponent("raw/screen.mp4"),
            displayAssetURL: package.appendingPathComponent("raw/screen.mp4"),
            ocrText: nil
        )
    }
}
