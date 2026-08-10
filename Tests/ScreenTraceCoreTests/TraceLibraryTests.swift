import Foundation
import XCTest
@testable import ScreenTraceCore

final class TraceLibraryTests: XCTestCase {
    func testLibraryIndexesNewestFirstUsesRenderedAssetAndSkipsCorruptPackages() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
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
                    text: "设计 ScreenTrace Roadmap",
                    confidence: 1,
                    normalizedBounds: TraceRect(x: 0, y: 0, width: 1, height: 0.2)
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

        let corrupt = root.appendingPathComponent("broken.screentrace", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("manifest.json"))

        let entries = store.libraryEntries()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.manifest.kind), [.screenshot, .recording])
        XCTAssertEqual(
            entries[0].displayAssetURL.resolvingSymlinksInPath(),
            renderedURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(entries[0].ocrText, "设计 ScreenTrace Roadmap")
        XCTAssertEqual(
            entries[1].primaryAssetURL.resolvingSymlinksInPath(),
            recordingSession.videoURL.resolvingSymlinksInPath()
        )
    }

    func testLibrarySearchMatchesAllTokensOCRAndTypeFilter() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
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
                        text: "Résumé ScreenTrace launch checklist",
                        confidence: 1,
                        normalizedBounds: TraceRect(x: 0, y: 0, width: 1, height: 0.2)
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
            TraceLibrarySearch.filter(entries, query: "resume checklist", filter: .all).map(\.manifest.kind),
            [.screenshot]
        )
        XCTAssertEqual(
            TraceLibrarySearch.filter(entries, query: "", filter: .recordings).map(\.manifest.kind),
            [.recording]
        )
        XCTAssertTrue(
            TraceLibrarySearch.filter(entries, query: "missing token", filter: .all).isEmpty
        )
    }

    func testPersistentIndexInvalidatesWhenOCRChangesOutsideTheManifest() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
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
        let store = TraceProjectStore(rootDirectory: root)
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
            try decoder.decode(TraceLibraryPersistentIndex.self, from: repairedData).records.count,
            1
        )

        try FileManager.default.removeItem(at: screenshot.packageURL)
        XCTAssertTrue(store.libraryEntries().isEmpty)
        let prunedData = try Data(contentsOf: store.libraryIndexURL)
        XCTAssertTrue(
            try decoder.decode(TraceLibraryPersistentIndex.self, from: prunedData).records.isEmpty
        )
    }

    func testOutdatedPersistentIndexRebuildsThroughCurrentSchemaGate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1, 3, 5]),
            width: 320,
            height: 180
        )
        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(
            TraceLibraryPersistentIndex.self,
            from: Data(contentsOf: store.libraryIndexURL)
        )
        let outdated = TraceLibraryPersistentIndex(schemaVersion: 2, records: current.records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(outdated).write(to: store.libraryIndexURL, options: .atomic)

        XCTAssertEqual(store.libraryEntries().map(\.manifest.id), [screenshot.manifest.id])
        let rebuilt = try decoder.decode(
            TraceLibraryPersistentIndex.self,
            from: Data(contentsOf: store.libraryIndexURL)
        )
        XCTAssertEqual(rebuilt.schemaVersion, TraceLibraryPersistentIndex.currentSchemaVersion)
    }

    func testPersistentIndexSkipsSymlinkPackagesAndRecursiveCycles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([4, 5, 6]),
            width: 320,
            height: 180
        )
        let duplicate = root.appendingPathComponent("duplicate.screentrace")
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
                    normalizedBounds: TraceRect(x: 0, y: 0, width: 1, height: 0.2)
                )
            ]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }
}
