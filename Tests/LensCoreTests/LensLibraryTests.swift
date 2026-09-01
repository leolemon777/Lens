import Foundation
import XCTest
@testable import LensCore

final class LensLibraryTests: XCTestCase {
    func testLibraryIndexesNewestFirstUsesRenderedAssetAndSkipsCorruptPackages() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1, 2, 3]),
            width: 800,
            height: 500,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans", "en-US"],
            blocks: [
                OCRTextBlock(
                    text: "设计 Lens Roadmap",
                    confidence: 1,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 0.2)
                )
            ]
        )
        let withOCR = try store.attachOCR(ocr, to: screenshot)
        let renderedURL = screenshot.packageURL.appendingPathComponent("previews/annotated.png")
        try Data([9, 8, 7]).write(to: renderedURL)
        _ = try store.completeScreenshotEditing(
            packageURL: withOCR.packageURL,
            renderedImageURL: renderedURL
        )

        let recordingSession = try store.beginRecording(
            width: 1_920,
            height: 1_080,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        try Data([4, 5, 6]).write(to: recordingSession.videoURL)
        _ = try store.finalizeRecording(recordingSession, durationSeconds: 5, state: .ready)

        let corrupt = root.appendingPathComponent("broken.lens", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))

        let entries = store.libraryEntries()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.manifest.kind), [.screenshot, .recording])
        XCTAssertEqual(
            entries[0].displayAssetURL.resolvingSymlinksInPath(),
            renderedURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(entries[0].ocrText, "设计 Lens Roadmap")
        XCTAssertEqual(
            entries[1].primaryAssetURL.resolvingSymlinksInPath(),
            recordingSession.videoURL.resolvingSymlinksInPath()
        )
    }

    func testLibrarySearchMatchesAllTokensOCRAndTypeFilter() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1]),
            width: 640,
            height: 360,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        _ = try store.attachOCR(
            OCRDocument(
                engine: "test",
                recognitionLanguages: ["en-US"],
                blocks: [
                    OCRTextBlock(
                        text: "Résumé Lens launch checklist",
                        confidence: 1,
                        normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 0.2)
                    )
                ]
            ),
            to: screenshot
        )
        let recordingSession = try store.beginRecording(
            width: 640,
            height: 360,
            createdAt: Date(timeIntervalSince1970: 90)
        )
        try Data([2]).write(to: recordingSession.videoURL)
        _ = try store.finalizeRecording(recordingSession, durationSeconds: 1, state: .ready)
        let entries = store.libraryEntries()

        XCTAssertEqual(
            LensLibrarySearch.filter(entries, query: "resume checklist", filter: .all).map(\.manifest.kind),
            [.screenshot]
        )
        XCTAssertEqual(
            LensLibrarySearch.filter(entries, query: "", filter: .recordings).map(\.manifest.kind),
            [.recording]
        )
        XCTAssertTrue(
            LensLibrarySearch.filter(entries, query: "missing token", filter: .all).isEmpty
        )
    }

    func testLibrarySearchRanksIntentionalMatchesBeforeLongBodyMatches() {
        let root = temporaryRoot()
        let bodyMatch = makeEntry(
            root: root,
            kind: .screenshot,
            title: "周会记录",
            ocrText: "这里提到 roadmap，后面还有很多正文内容"
        )
        let tagMatch = LensLibraryEntry(
            packageURL: bodyMatch.packageURL.appendingPathComponent("tagged.lens"),
            manifest: LensManifest(
                id: UUID(),
                kind: .screenshot,
                title: "设计评审",
                dimensions: LensDimensions(width: 640, height: 360),
                assets: bodyMatch.manifest.assets
            ),
            primaryAssetURL: bodyMatch.primaryAssetURL,
            displayAssetURL: bodyMatch.displayAssetURL,
            ocrText: nil,
            insights: LensInsightsDocument(
                engine: "test",
                suggestedTitle: "设计评审",
                summary: "",
                tags: ["roadmap"]
            )
        )
        let titleMatch = makeEntry(
            root: root,
            kind: .screenshot,
            title: "Roadmap 评审",
            ocrText: nil
        )

        let result = LensLibrarySearch.filter(
            [bodyMatch, tagMatch, titleMatch],
            query: "roadmap",
            filter: .all
        )

        XCTAssertEqual(result.map(\.id), [titleMatch.id, tagMatch.id, bodyMatch.id])
    }

    func testLibrarySearchUsesLocalIntentAliasesWithoutUploadingContent() {
        let root = temporaryRoot()
        let recording = makeEntry(
            root: root,
            kind: .recording,
            title: "录屏演示",
            ocrText: nil
        )
        let guide = makeEntry(
            root: root,
            kind: .screenshot,
            title: "录屏操作指南",
            ocrText: nil
        )

        let videoResult = LensLibrarySearch.filter(
            [recording, guide],
            query: "视频",
            filter: .all
        )
        XCTAssertEqual(Set(videoResult.map(\.id)), Set([recording.id, guide.id]))
        XCTAssertEqual(
            LensLibrarySearch.filter(
                [recording, guide],
                query: "教程",
                filter: .all
            ).map(\.id),
            [guide.id]
        )
        let contiguousIntentResult = LensLibrarySearch.filter(
            [recording, guide],
            query: "视频教程",
            filter: .all
        )
        XCTAssertEqual(
            contiguousIntentResult.map(\.id),
            [guide.id]
        )
        XCTAssertTrue(LensLibrarySearch.usesIntentExpansion(for: "视频"))
        XCTAssertTrue(LensLibrarySearch.usesIntentExpansion(for: "视频教程"))
        XCTAssertFalse(LensLibrarySearch.usesIntentExpansion(for: "roadmap"))
    }

    func testPersistentIndexInvalidatesWhenOCRChangesOutsideTheManifest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1, 2, 3]),
            width: 640,
            height: 360
        )
        _ = try store.attachOCR(makeOCR(text: "first indexed text"), to: screenshot)

        XCTAssertEqual(store.libraryEntries().first?.ocrText, "first indexed text")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.libraryIndexURL.path))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(makeOCR(text: "second, substantially longer indexed text")).write(
            to: screenshot.packageURL.appendingPathComponent("analysis/ocr.json"),
            options: .atomic
        )

        XCTAssertEqual(
            store.libraryEntries().first?.ocrText,
            "second, substantially longer indexed text"
        )
    }

    func testCorruptPersistentIndexRebuildsAndRemovedPackagesArePruned() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([7, 8, 9]),
            width: 320,
            height: 180
        )
        XCTAssertEqual(store.libraryEntries().count, 1)
        try Data("not an index".utf8).write(to: store.libraryIndexURL, options: .atomic)

        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])
        let repairedData = try Data(contentsOf: store.libraryIndexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(LensLibraryPersistentIndex.self, from: repairedData).records.count,
            1
        )

        try FileManager.default.removeItem(at: screenshot.packageURL)
        XCTAssertTrue(store.libraryEntries().isEmpty)
        let prunedData = try Data(contentsOf: store.libraryIndexURL)
        XCTAssertTrue(
            try decoder.decode(LensLibraryPersistentIndex.self, from: prunedData).records.isEmpty
        )
    }

    func testOutdatedPersistentIndexRebuildsThroughCurrentSchemaGate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1, 3, 5]),
            width: 320,
            height: 180
        )
        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(
            LensLibraryPersistentIndex.self,
            from: Data(contentsOf: store.libraryIndexURL)
        )
        let outdated = LensLibraryPersistentIndex(schemaVersion: 2, records: current.records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(outdated).write(to: store.libraryIndexURL, options: .atomic)

        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])
        let rebuilt = try decoder.decode(
            LensLibraryPersistentIndex.self,
            from: Data(contentsOf: store.libraryIndexURL)
        )
        XCTAssertEqual(rebuilt.schemaVersion, LensLibraryPersistentIndex.currentSchemaVersion)
    }

    func testPersistentIndexSkipsSymlinkPackagesAndRecursiveCycles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([4, 5, 6]),
            width: 320,
            height: 180
        )
        let duplicate = root.appendingPathComponent("duplicate.lens")
        try FileManager.default.createSymbolicLink(
            at: duplicate,
            withDestinationURL: screenshot.packageURL
        )
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: nested.appendingPathComponent("cycle", isDirectory: true),
            withDestinationURL: root
        )

        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])
    }

    private func makeOCR(text: String) -> OCRDocument {
        OCRDocument(
            engine: "test",
            recognitionLanguages: ["en-US"],
            blocks: [
                OCRTextBlock(
                    text: text,
                    confidence: 1,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 0.2)
                )
            ]
        )
    }

    private func makeEntry(
        root: URL,
        kind: LensKind,
        title: String,
        ocrText: String?
    ) -> LensLibraryEntry {
        let id = UUID()
        let packageURL = root.appendingPathComponent("\(id.uuidString).lens", isDirectory: true)
        let assetName = kind == .screenshot ? "screenshot.png" : "screen.mp4"
        let assetURL = packageURL.appendingPathComponent("raw/\(assetName)")
        let role: LensAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = LensManifest(
            id: id,
            kind: kind,
            title: title,
            dimensions: LensDimensions(width: 640, height: 360),
            assets: [LensAsset(role: role, relativePath: "raw/\(assetName)")]
        )
        return LensLibraryEntry(
            packageURL: packageURL,
            manifest: manifest,
            primaryAssetURL: assetURL,
            displayAssetURL: assetURL,
            ocrText: ocrText
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LensLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }
}
