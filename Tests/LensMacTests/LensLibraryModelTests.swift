import Foundation
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class LensLibraryModelTests: XCTestCase {
    func testRecoveryScanPublishesProgressAndSkipsUnchangedPackages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryRecoveryScan", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = LensProjectStore(rootDirectory: root)
        let first = try store.beginRecording(
            width: 1_280,
            height: 720,
            includesSystemAudio: false,
            id: UUID()
        )
        let second = try store.beginRecording(
            width: 1_280,
            height: 720,
            includesSystemAudio: false,
            id: UUID()
        )
        try Data([1]).write(to: first.videoURL)
        try Data([1]).write(to: second.videoURL)

        let gate = RecoveryScanGate()
        let model = LensLibraryModel(
            store: store,
            recoveryDurationProvider: { _ in await gate.wait() }
        )
        model.reload()
        await model.waitForReload()

        var progress: LensLibraryRecoveryScanProgress?
        for _ in 0..<100 {
            if let current = model.recoveryScanProgress {
                progress = current
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(progress?.completed, 0)
        XCTAssertEqual(progress?.total, 2)

        await gate.releaseAll()
        await model.waitForRecoveryScan()
        XCTAssertNil(model.recoveryScanProgress)
        let scannedCount = await gate.callCount
        XCTAssertGreaterThan(scannedCount, 0)

        model.reload()
        await model.waitForReload()
        await Task.yield()
        XCTAssertNil(model.recoveryScanProgress)
        let rescannedCount = await gate.callCount
        XCTAssertEqual(rescannedCount, scannedCount)
    }

    func testCountsSearchAndTypeFilterStayInSync() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryModelTests", isDirectory: true)
        let screenshot = makeEntry(
            root: root,
            kind: .screenshot,
            title: "设计评审",
            ocrText: "Lens roadmap checklist"
        )
        let recording = makeEntry(
            root: root,
            kind: .recording,
            title: "产品演示录屏",
            ocrText: nil
        )
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [screenshot, recording]
        )

        XCTAssertEqual(model.screenshotCount, 1)
        XCTAssertEqual(model.recordingCount, 1)

        model.query = "roadmap checklist"
        await model.waitForFiltering()
        XCTAssertEqual(model.visibleEntries.map(\.id), [screenshot.id])

        model.query = ""
        model.filter = .recordings
        await model.waitForFiltering()
        XCTAssertEqual(model.visibleEntries.map(\.id), [recording.id])

        model.setTranscribing(true, id: recording.id)
        XCTAssertTrue(model.isTranscribing(recording.id))
        model.setTranscriptionProgress(
            LensLibraryTranscriptionProgress(completed: 1, total: 3),
            id: recording.id
        )
        XCTAssertEqual(model.transcriptionProgress(for: recording.id)?.fractionCompleted, 1.0 / 3.0)
        model.setTranscribing(false, id: recording.id)
        XCTAssertFalse(model.isTranscribing(recording.id))
        XCTAssertNil(model.transcriptionProgress(for: recording.id))

        XCTAssertTrue(model.canDelete(screenshot))
        model.removeEntries(withIDs: [screenshot.id])
        XCTAssertEqual(model.entries.map(\.id), [recording.id])
        XCTAssertEqual(model.screenshotCount, 0)
    }

    func testTranscriptionProgressCannotLeakToAnInactiveEntry() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryTranscriptionProgress", isDirectory: true)
        let entry = makeEntry(root: root, kind: .recording, title: "转写", ocrText: nil)
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [entry]
        )

        model.setTranscriptionProgress(
            LensLibraryTranscriptionProgress(completed: 1, total: 2),
            id: entry.id
        )
        XCTAssertNil(model.transcriptionProgress(for: entry.id))
        model.setTranscribing(true, id: entry.id)
        model.setTranscriptionProgress(
            LensLibraryTranscriptionProgress(completed: 1, total: 2),
            id: entry.id
        )
        model.removeEntries(withIDs: [entry.id])
        XCTAssertNil(model.transcriptionProgress(for: entry.id))
    }

    func testAStaleFilterResultCannotReplaceANewerQuery() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryFilteringRace", isDirectory: true)
        let first = makeEntry(
            root: root,
            kind: .screenshot,
            title: "Roadmap",
            ocrText: nil
        )
        let second = makeEntry(
            root: root,
            kind: .recording,
            title: "演示",
            ocrText: nil
        )
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [first, second]
        )

        model.query = "roadmap"
        model.query = "演示"
        await model.waitForFiltering()

        XCTAssertEqual(model.visibleEntries.map(\.id), [second.id])
        XCTAssertFalse(model.isFiltering)
    }

    func testActiveAndProcessingEntriesAreProtectedFromDeletion() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryDeletePolicy", isDirectory: true)
        var processing = makeEntry(root: root, kind: .recording, title: "处理中", ocrText: nil)
        processing = LensLibraryEntry(
            packageURL: processing.packageURL,
            manifest: LensManifest(
                id: processing.id,
                kind: .recording,
                title: "处理中",
                state: .processing,
                dimensions: LensDimensions(width: 1_280, height: 720),
                assets: processing.manifest.assets
            ),
            primaryAssetURL: processing.primaryAssetURL,
            displayAssetURL: processing.displayAssetURL,
            ocrText: nil
        )
        let ready = makeEntry(root: root, kind: .screenshot, title: "可删除", ocrText: nil)
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [processing, ready]
        )

        XCTAssertFalse(model.canDelete(processing))
        model.setOrganizing(true, id: ready.id)
        XCTAssertFalse(model.canDelete(ready))
        model.setOrganizing(false, id: ready.id)
        XCTAssertTrue(model.canDelete(ready))
    }

    private func makeEntry(
        root: URL,
        kind: LensKind,
        title: String,
        ocrText: String?
    ) -> LensLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).lens", isDirectory: true)
        let assetName = kind == .screenshot ? "screenshot.png" : "screen.mp4"
        let asset = package.appendingPathComponent("raw/\(assetName)")
        let role: LensAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = LensManifest(
            id: id,
            kind: kind,
            title: title,
            dimensions: LensDimensions(width: 1_280, height: 720),
            assets: [LensAsset(role: role, relativePath: "raw/\(assetName)")]
        )
        return LensLibraryEntry(
            packageURL: package,
            manifest: manifest,
            primaryAssetURL: asset,
            displayAssetURL: asset,
            ocrText: ocrText
        )
    }

    private actor RecoveryScanGate {
        private(set) var callCount = 0
        private var isReleased = false
        private var waiters: [CheckedContinuation<Double?, Never>] = []

        func wait() async -> Double? {
            callCount += 1
            if isReleased { return nil }
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func releaseAll() {
            isReleased = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: nil) }
        }
    }
}
