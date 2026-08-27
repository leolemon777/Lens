import Foundation
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class LensLibraryModelTests: XCTestCase {
    func testCountsSearchAndTypeFilterStayInSync() {
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
        XCTAssertEqual(model.visibleEntries.map(\.id), [screenshot.id])

        model.query = ""
        model.filter = .recordings
        XCTAssertEqual(model.visibleEntries.map(\.id), [recording.id])

        model.setTranscribing(true, id: recording.id)
        XCTAssertTrue(model.isTranscribing(recording.id))
        model.setTranscribing(false, id: recording.id)
        XCTAssertFalse(model.isTranscribing(recording.id))

        XCTAssertTrue(model.canDelete(screenshot))
        model.removeEntries(withIDs: [screenshot.id])
        XCTAssertEqual(model.entries.map(\.id), [recording.id])
        XCTAssertEqual(model.screenshotCount, 0)
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
}
