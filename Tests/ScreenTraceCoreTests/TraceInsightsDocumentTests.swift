import Foundation
import XCTest
@testable import ScreenTraceCore

final class TraceInsightsDocumentTests: XCTestCase {
    func testVersionZeroOneDocumentDecodesWithoutCustomization() throws {
        let json = #"""
        {
          "schemaVersion": "0.1",
          "engine": "legacy-local",
          "generatedAt": "1970-01-01T00:00:10Z",
          "suggestedTitle": "Legacy title",
          "summary": "Legacy summary",
          "tags": ["legacy"],
          "keyPoints": [],
          "chapters": [],
          "sensitiveFindings": []
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(
            TraceInsightsDocument.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(document.customization)
        XCTAssertEqual(document.resolvedTitle, "Legacy title")
        XCTAssertEqual(document.resolvedSummary, "Legacy summary")
        XCTAssertEqual(document.resolvedTags, ["legacy"])
    }

    func testDocumentNormalizesOpenSchemaAndRoundTrips() throws {
        let document = TraceInsightsDocument(
            engine: " local-test ",
            generatedAt: Date(timeIntervalSince1970: 10.9),
            suggestedTitle: " Suggested title ",
            summary: " Summary ",
            tags: ["Swift", "swift", "", "macOS"],
            keyPoints: ["First", "First", "Second"],
            chapters: [
                TraceChapter(
                    index: 1,
                    startSeconds: 20,
                    endSeconds: 30,
                    title: "Later",
                    summary: "Later summary"
                ),
                TraceChapter(
                    index: 0,
                    startSeconds: 0,
                    endSeconds: 10,
                    title: "First",
                    summary: "First summary"
                )
            ],
            sensitiveFindings: [
                TraceSensitiveFinding(
                    kind: .credential,
                    source: .ocr,
                    redactedPreview: "api_key: ••••",
                    occurrenceCount: 0
                )
            ],
            customization: TraceInsightsCustomization(
                title: " Human title ",
                summary: "",
                tags: ["Reviewed", "reviewed", ""]
            )
        )

        XCTAssertEqual(document.engine, "local-test")
        XCTAssertEqual(document.generatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(document.tags, ["Swift", "macOS"])
        XCTAssertEqual(document.keyPoints, ["First", "Second"])
        XCTAssertEqual(document.chapters.map(\.index), [0, 1])
        XCTAssertEqual(document.sensitiveFindings[0].occurrenceCount, 1)
        XCTAssertEqual(document.resolvedTitle, "Human title")
        XCTAssertEqual(document.resolvedSummary, "")
        XCTAssertEqual(document.resolvedTags, ["Reviewed"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            TraceInsightsDocument.self,
            from: encoder.encode(document)
        )
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.schemaVersion, TraceInsightsDocument.currentSchemaVersion)

        let automatic = decoded.replacingCustomization(nil)
        XCTAssertEqual(automatic.resolvedTitle, "Suggested title")
        XCTAssertEqual(automatic.resolvedSummary, "Summary")
        XCTAssertEqual(automatic.resolvedTags, ["Swift", "macOS"])
    }

    func testInsightsPersistBecomeSearchableAndInvalidateDisposableIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceInsightsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let saved = try store.saveScreenshot(
            pngData: Data([1, 2, 3]),
            width: 640,
            height: 360
        )
        let first = TraceInsightsDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 1),
            suggestedTitle: "Launch planning",
            summary: "Prepare the ScreenTrace public release.",
            tags: ["roadmap", "release"]
        )

        let updated = try store.attachInsights(first, to: saved)
        XCTAssertEqual(updated.manifest.schemaVersion, TraceManifest.currentSchemaVersion)
        XCTAssertEqual(updated.manifest.assets.filter { $0.role == .insights }.count, 1)
        XCTAssertEqual(try store.loadInsights(from: saved.packageURL), first)
        XCTAssertEqual(try Data(contentsOf: saved.rawAssetURL), Data([1, 2, 3]))
        XCTAssertEqual(
            TraceLibrarySearch.filter(
                store.libraryEntries(),
                query: "roadmap public",
                filter: .all
            ).map(\.id),
            [saved.manifest.id]
        )

        let customized = first.replacingCustomization(TraceInsightsCustomization(
            title: "Reviewed launch",
            summary: "Human-approved local summary",
            tags: ["approved", "privacy"]
        ))
        _ = try store.attachInsights(customized, to: updated)
        XCTAssertEqual(
            TraceLibrarySearch.filter(
                store.libraryEntries(),
                query: "approved privacy",
                filter: .all
            ).map(\.id),
            [saved.manifest.id]
        )
        XCTAssertEqual(store.libraryEntries().first?.insights?.resolvedTitle, "Reviewed launch")

        let second = TraceInsightsDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 2),
            suggestedTitle: "Accessibility audit",
            summary: "A substantially longer replacement summary for index invalidation.",
            tags: ["accessibility"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(second).write(
            to: saved.packageURL.appendingPathComponent("analysis/insights.json"),
            options: .atomic
        )

        XCTAssertEqual(store.libraryEntries().first?.insights, second)
        XCTAssertEqual(
            TraceLibrarySearch.filter(
                store.libraryEntries(),
                query: "accessibility audit",
                filter: .all
            ).map(\.id),
            [saved.manifest.id]
        )
    }
}
