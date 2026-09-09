import Foundation
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class ActiveStoragePackagePolicyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/LensRoot")

    /// The cleanup pass matches temporary files against their own package, so
    /// an open editor has to appear under its real URL. A sentinel alone would
    /// defer a migration while leaving the editor's staging files deletable.
    func testOpenEditorsContributeTheirRealPackageURLs() {
        let editing = URL(fileURLWithPath: "/tmp/LensRoot/Recording.lens")
        let annotating = URL(fileURLWithPath: "/tmp/LensRoot/Shot.lens")

        let packages = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [],
            editingPackageURLs: [editing, annotating],
            hasUnnamedWrite: false
        )

        XCTAssertEqual(packages, [editing, annotating])
    }

    func testTaskAndEditorPackagesAreMergedAndStandardized() {
        let rendering = URL(fileURLWithPath: "/tmp/LensRoot/./Rendering.lens")
        let editing = URL(fileURLWithPath: "/tmp/LensRoot/Rendering.lens")

        let packages = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [rendering],
            editingPackageURLs: [editing],
            hasUnnamedWrite: false
        )

        XCTAssertEqual(packages, [editing.standardizedFileURL])
    }

    /// A capture that has not published a package yet, and a visible library
    /// window, still have to block a migration. They name no package, so the
    /// sentinel is the only thing that can make the set non-empty.
    func testUnnamedWriteContributesOnlyTheSentinel() {
        let packages = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [],
            editingPackageURLs: [nil, nil],
            hasUnnamedWrite: true
        )

        XCTAssertEqual(
            packages,
            [root.appendingPathComponent(
                ActiveStoragePackagePolicy.unnamedWriteSentinelName
            ).standardizedFileURL]
        )
    }

    func testIdleAppProtectsNothing() {
        let packages = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [],
            editingPackageURLs: [nil, nil],
            hasUnnamedWrite: false
        )

        XCTAssertTrue(packages.isEmpty)
    }

    /// Closes the loop the policy exists for: the set it produces has to make
    /// the real cleanup skip the staging files an open editor is still writing,
    /// while everything idle is still reclaimed.
    func testEditorStagingFilesSurviveTheRealCleanupPass() throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensActiveStorage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let editing = storageRoot.appendingPathComponent("Editing.lens", isDirectory: true)
        let idle = storageRoot.appendingPathComponent("Idle.lens", isDirectory: true)
        let editingStaging = editing
            .appendingPathComponent("previews/.auto-mixed-1.mp4")
        let idleStaging = idle
            .appendingPathComponent("previews/.audio-mix-1.caf")
        for url in [editingStaging, idleStaging] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0, 1]).write(to: url)
        }

        let protected = ActiveStoragePackagePolicy.resolve(
            rootDirectory: storageRoot,
            taskPackageURLs: [],
            editingPackageURLs: [editing],
            hasUnnamedWrite: false
        )
        let report = try LensStorageManager(rootDirectory: storageRoot)
            .cleanupTemporaryFiles(protecting: protected)

        XCTAssertEqual(report.skippedItems.count, 1)
        XCTAssertEqual(report.removedItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: editingStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: idleStaging.path))
    }
}

@MainActor
final class LensStorageMigrationQueueTests: XCTestCase {
    /// The migration gate only reads emptiness, so every busy state — named or
    /// not — has to keep deferring after the policy started naming packages.
    func testEitherANamedEditorOrAnUnnamedWriteDefersMigration() {
        let root = URL(fileURLWithPath: "/tmp/LensRoot")
        let destination = URL(fileURLWithPath: "/tmp/destination")

        let editing = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [],
            editingPackageURLs: [URL(fileURLWithPath: "/tmp/LensRoot/Recording.lens")],
            hasUnnamedWrite: false
        )
        XCTAssertFalse(
            LensStorageMigrationQueue().request(destination: destination, activePackages: editing)
        )

        let capturing = ActiveStoragePackagePolicy.resolve(
            rootDirectory: root,
            taskPackageURLs: [],
            editingPackageURLs: [nil],
            hasUnnamedWrite: true
        )
        XCTAssertFalse(
            LensStorageMigrationQueue().request(destination: destination, activePackages: capturing)
        )
    }

    func testBusyPackageWritingQueuesNewestDestinationAndStartsAfterFinish() {
        let queue = LensStorageMigrationQueue()
        let active = Set([URL(fileURLWithPath: "/tmp/active.lens")])
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")

        XCTAssertFalse(queue.request(destination: first, activePackages: active))
        XCTAssertEqual(queue.pendingDestination, first.standardizedFileURL)
        XCTAssertFalse(queue.request(destination: second, activePackages: active))
        XCTAssertEqual(queue.pendingDestination, second.standardizedFileURL)

        let next = queue.takeNextIfReady(activePackages: [])
        XCTAssertEqual(next, second.standardizedFileURL)
        XCTAssertTrue(queue.isRunning)
        queue.finish()
        XCTAssertFalse(queue.isRunning)
        XCTAssertNil(queue.pendingDestination)
    }

    func testRunningMigrationDoesNotStartAnotherCopy() {
        let queue = LensStorageMigrationQueue()
        let destination = URL(fileURLWithPath: "/tmp/first")
        XCTAssertTrue(queue.request(destination: destination, activePackages: []))

        let queued = URL(fileURLWithPath: "/tmp/second")
        XCTAssertFalse(queue.request(destination: queued, activePackages: []))
        XCTAssertNil(queue.takeNextIfReady(activePackages: []))
        queue.finish()
        XCTAssertEqual(queue.takeNextIfReady(activePackages: []), queued.standardizedFileURL)
    }
}
