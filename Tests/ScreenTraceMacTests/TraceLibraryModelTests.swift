import Foundation
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class TraceLibraryModelTests: XCTestCase {
    func testCountsSearchAndTypeFilterStayInSync() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceLibraryModelTests", isDirectory: true)
        let screenshot = makeEntry(
            root: root,
            kind: .screenshot,
            title: "设计评审",
            ocrText: "ScreenTrace roadmap checklist"
        )
        let recording = makeEntry(
            root: root,
            kind: .recording,
            title: "产品演示录屏",
            ocrText: nil
        )
        let model = TraceLibraryModel(
            store: TraceProjectStore(rootDirectory: root),
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
    }

    private func makeEntry(
        root: URL,
        kind: TraceKind,
        title: String,
        ocrText: String?
    ) -> TraceLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).screentrace", isDirectory: true)
        let assetName = kind == .screenshot ? "screenshot.png" : "screen.mp4"
        let asset = package.appendingPathComponent("raw/\(assetName)")
        let role: TraceAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = TraceManifest(
            id: id,
            kind: kind,
            title: title,
            dimensions: TraceDimensions(width: 1_280, height: 720),
            assets: [TraceAsset(role: role, relativePath: "raw/\(assetName)")]
        )
        return TraceLibraryEntry(
            packageURL: package,
            manifest: manifest,
            primaryAssetURL: asset,
            displayAssetURL: asset,
            ocrText: ocrText
        )
    }
}
