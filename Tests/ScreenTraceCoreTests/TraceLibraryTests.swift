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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }
}
