import Foundation
import XCTest
@testable import LensCore

final class LensStorageManagerTests: XCTestCase {
    func testInventorySeparatesSourcesDeliverablesDerivedAndTemporaryFiles() throws {
        let root = try makeDirectory(named: "LensStorageInventory")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root
            .appendingPathComponent("2026-09-04", isDirectory: true)
            .appendingPathComponent("Capture.lens", isDirectory: true)
        try createDirectories([
            package.appendingPathComponent("raw"),
            package.appendingPathComponent("previews"),
            package.appendingPathComponent("edits"),
            root.appendingPathComponent(".index")
        ])
        try write(Data([1, 2, 3]), to: package.appendingPathComponent("raw/screen.mp4"))
        try write(Data([4, 5]), to: package.appendingPathComponent("previews/auto.mp4"))
        try write(Data([6]), to: package.appendingPathComponent("edits/edit-plan.json"))
        try write(
            Data([7, 8]),
            to: package.appendingPathComponent("previews/.screen-effects-test.mp4")
        )
        try write(Data([9]), to: root.appendingPathComponent(".index/library-v1.json"))

        let inventory = try LensStorageManager(rootDirectory: root).inventory()

        XCTAssertEqual(inventory.packageCount, 1)
        XCTAssertEqual(inventory.bytesByCategory[.source], 3)
        XCTAssertEqual(inventory.bytesByCategory[.rendered], 2)
        XCTAssertEqual(inventory.bytesByCategory[.derived], 1)
        XCTAssertEqual(inventory.bytesByCategory[.temporary], 2)
        XCTAssertEqual(inventory.bytesByCategory[.index], 1)
        XCTAssertEqual(inventory.temporaryItems.map(\.relativePath), [
            "2026-09-04/Capture.lens/previews/.screen-effects-test.mp4"
        ])
    }

    func testCleanupRemovesOnlyKnownTemporaryFilesAndProtectsActivePackage() throws {
        let root = try makeDirectory(named: "LensStorageCleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Capture.lens", isDirectory: true)
        let temporary = package.appendingPathComponent(
            "previews/.auto-123.mp4"
        )
        let rendered = package.appendingPathComponent("previews/auto.mp4")
        try createDirectories([temporary.deletingLastPathComponent()])
        try write(Data([1, 2]), to: temporary)
        try write(Data([3, 4]), to: rendered)
        let manager = LensStorageManager(rootDirectory: root)

        let protected = try manager.cleanupTemporaryFiles(protecting: [package])
        XCTAssertEqual(protected.removedItems.count, 0)
        XCTAssertEqual(protected.skippedItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))

        let cleaned = try manager.cleanupTemporaryFiles()
        XCTAssertEqual(cleaned.removedBytes, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendered.path))
    }

    func testMigrationCopiesAndVerifiesTheWholeRootWithoutDeletingSource() throws {
        let parent = try makeDirectory(named: "LensStorageMigration")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        try createDirectories([
            source.appendingPathComponent("Capture.lens/raw"),
            source.appendingPathComponent(".index")
        ])
        try write(Data("raw".utf8), to: source.appendingPathComponent("Capture.lens/raw/screen.mp4"))
        try write(Data("index".utf8), to: source.appendingPathComponent(".index/library-v1.json"))

        let manager = LensStorageManager(rootDirectory: source)
        let plan = try manager.migrationPlan(to: destination)
        XCTAssertEqual(plan.packageCount, 1)
        let receipt = try manager.migrate(to: destination)

        XCTAssertEqual(receipt.verifiedFileCount, 2)
        XCTAssertNil(try manager.pendingMigration())
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Capture.lens/raw/screen.mp4")), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".index/library-v1.json")), Data("index".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Capture.lens/raw/screen.mp4").path))
    }

    func testInterruptedMigrationRetainsJournalAndCanResumeSameDestination() throws {
        let parent = try makeDirectory(named: "LensStorageMigrationResume")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        try write(
            Data("raw".utf8),
            to: source.appendingPathComponent("2026/Capture.lens/raw/screen.mp4")
        )
        try write(Data("index".utf8), to: source.appendingPathComponent(".index/library-v1.json"))

        let manager = LensStorageManager(rootDirectory: source)
        XCTAssertThrowsError(
            try manager.migrate(to: destination, interruptionAfterCopiedChildren: 1)
        ) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .simulatedInterruption)
        }
        let pending = try XCTUnwrap(try manager.pendingMigration())
        XCTAssertEqual(pending.plan.destinationPath, destination.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.stagingPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        // Recreate the service to model a process restart between the
        // interruption and the resume attempt. The journal, not in-memory
        // state, must be sufficient to continue the same destination.
        let resumedManager = LensStorageManager(rootDirectory: source)
        let receipt = try resumedManager.migrate(to: destination)
        XCTAssertEqual(receipt.destinationPath, destination.standardizedFileURL.path)
        XCTAssertNil(try resumedManager.pendingMigration())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("2026/Capture.lens/raw/screen.mp4")),
            Data("raw".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(".index/library-v1.json")),
            Data("index".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPublishedMigrationCrashWindowIsVerifiedAndJournalIsCleared() throws {
        let parent = try makeDirectory(named: "LensStoragePublishedRecovery")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        try write(
            Data("raw".utf8),
            to: source.appendingPathComponent("Capture.lens/raw/screen.mp4")
        )

        let manager = LensStorageManager(rootDirectory: source)
        let plan = try manager.migrationPlan(to: destination)
        _ = try manager.migrate(to: destination)

        // Model a process dying after publish and before journal cleanup.
        let staleJournal = parent.appendingPathComponent(".Source.lens-migration.json")
        let journal = LensStoragePendingMigration(
            plan: plan,
            stagingPath: parent.appendingPathComponent("missing-staging").path,
            phase: "publishing"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: staleJournal, options: .atomic)

        let recovered = try manager.recoverPublishedMigrationIfNeeded()

        XCTAssertEqual(recovered?.destinationPath, destination.standardizedFileURL.path)
        XCTAssertEqual(recovered?.verifiedFileCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleJournal.path))
        XCTAssertNil(try manager.pendingMigration())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPublishedMigrationMismatchRetainsJournalForManualReview() throws {
        let parent = try makeDirectory(named: "LensStoragePublishedMismatch")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        try write(
            Data("source".utf8),
            to: source.appendingPathComponent("Capture.lens/raw/screen.mp4")
        )

        let manager = LensStorageManager(rootDirectory: source)
        let plan = try manager.migrationPlan(to: destination)
        try write(
            Data("tampered".utf8),
            to: destination.appendingPathComponent("Capture.lens/raw/screen.mp4")
        )
        let staleJournal = parent.appendingPathComponent(".Source.lens-migration.json")
        let journal = LensStoragePendingMigration(
            plan: plan,
            stagingPath: parent.appendingPathComponent("missing-staging").path,
            phase: "publishing"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: staleJournal, options: .atomic)

        XCTAssertThrowsError(try manager.recoverPublishedMigrationIfNeeded()) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .verificationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleJournal.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Capture.lens/raw/screen.mp4")),
            Data("tampered".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCorruptedMigrationJournalFailsClosed() throws {
        let parent = try makeDirectory(named: "LensStorageCorruptedJournal")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let journal = parent.appendingPathComponent(".Source.lens-migration.json")
        try Data("not-json".utf8).write(to: journal, options: .atomic)

        let manager = LensStorageManager(rootDirectory: source)

        XCTAssertThrowsError(try manager.pendingMigration()) { error in
            XCTAssertEqual(
                error as? LensStorageManagerError,
                .migrationJournalCorrupted
            )
        }
        XCTAssertThrowsError(
            try manager.migrate(to: parent.appendingPathComponent("Destination"))
        ) { error in
            XCTAssertEqual(
                error as? LensStorageManagerError,
                .migrationJournalCorrupted
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testIncompleteMigrationJournalFailsClosedAndIsRetained() throws {
        let parent = try makeDirectory(named: "LensStorageIncompleteJournal")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        let journal = parent.appendingPathComponent(".Source.lens-migration.json")
        let plan = LensStorageMigrationPlan(
            sourcePath: source.path,
            destinationPath: destination.path,
            packageCount: 0,
            fileCount: 0,
            totalBytes: 0
        )
        let pending = LensStoragePendingMigration(
            plan: plan,
            stagingPath: parent.appendingPathComponent("missing-staging").path,
            phase: "copying"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: journal, options: .atomic)

        let manager = LensStorageManager(rootDirectory: source)
        XCTAssertThrowsError(try manager.pendingMigration()) { error in
            XCTAssertEqual(
                error as? LensStorageManagerError,
                .migrationJournalIncomplete
            )
        }
        XCTAssertThrowsError(try manager.migrate(to: destination)) { error in
            XCTAssertEqual(
                error as? LensStorageManagerError,
                .migrationJournalIncomplete
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMigrationRejectsDestinationInsideSourceOrAnExistingDirectory() throws {
        let root = try makeDirectory(named: "LensStorageMigrationGuard")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manager = LensStorageManager(rootDirectory: source)

        XCTAssertThrowsError(try manager.migrationPlan(
            to: source.appendingPathComponent("Nested", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .destinationInsideManagedRoot)
        }

        let existing = root.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertThrowsError(try manager.migrationPlan(to: existing)) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .destinationAlreadyExists)
        }
    }

    func testMigrationRejectsSymbolicLinksBeforeCopyingAnything() throws {
        let parent = try makeDirectory(named: "LensStorageMigrationSymlink")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )

        let manager = LensStorageManager(rootDirectory: source)
        XCTAssertThrowsError(try manager.migrationPlan(to: destination)) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .symbolicLinkNotAllowed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("linked.txt").path))
    }

    func testPreCancelledMigrationLeavesSourceAndDestinationUntouched() async throws {
        let source = try makeDirectory(named: "LensStorageMigrationCancelled")
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent("destination-(UUID().uuidString)")
        try write(
            Data("source".utf8),
            to: source.appendingPathComponent("project.lens/manifest.json")
        )

        let manager = LensStorageManager(rootDirectory: source)
        let task = Task {
            try manager.migrate(to: destination)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancelled migration")
        } catch is CancellationError {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: source.appendingPathComponent("project.lens/manifest.json").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMigrationReportsCopyVerifyPublishAndCompletionStages() throws {
        let parent = try makeDirectory(named: "LensStorageMigrationProgress")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        try write(
            Data("raw".utf8),
            to: source.appendingPathComponent("Capture.lens/raw/screen.mp4")
        )
        try write(
            Data("index".utf8),
            to: source.appendingPathComponent(".index/library-v1.json")
        )

        var progress: [LensStorageMigrationProgress] = []
        _ = try LensStorageManager(rootDirectory: source).migrate(
            to: destination,
            progress: { progress.append($0) }
        )

        XCTAssertEqual(progress.first?.phase, .copying)
        XCTAssertEqual(progress.first?.completedChildren, 0)
        XCTAssertEqual(progress.last?.phase, .completed)
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertTrue(progress.contains { $0.phase == .verifying })
        XCTAssertTrue(progress.contains { $0.phase == .publishing })
        XCTAssertEqual(progress.filter { $0.phase == .copying }.last?.completedChildren, 2)
    }

    func testVerificationMismatchRetainsSourceAndJournalForResume() throws {
        let parent = try makeDirectory(named: "LensStorageVerificationFailure")
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Source", isDirectory: true)
        let destination = parent.appendingPathComponent("Destination", isDirectory: true)
        let rawURL = source.appendingPathComponent("Capture.lens/raw/screen.mp4")
        try write(Data("before".utf8), to: rawURL)

        let manager = LensStorageManager(rootDirectory: source)
        var changedDuringVerification = false
        XCTAssertThrowsError(
            try manager.migrate(to: destination, progress: { progress in
                guard progress.phase == .verifying, !changedDuringVerification else { return }
                changedDuringVerification = true
                try? Data("after".utf8).write(to: rawURL, options: .atomic)
            })
        ) { error in
            XCTAssertEqual(error as? LensStorageManagerError, .verificationFailed)
        }

        XCTAssertTrue(changedDuringVerification)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let pending = try XCTUnwrap(try manager.pendingMigration())
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.stagingPath))
        XCTAssertEqual(try Data(contentsOf: rawURL), Data("after".utf8))

        let resumed = try manager.migrate(to: destination)
        XCTAssertEqual(resumed.verifiedFileCount, 1)
        XCTAssertNil(try manager.pendingMigration())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Capture.lens/raw/screen.mp4")),
            Data("after".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDirectories(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
