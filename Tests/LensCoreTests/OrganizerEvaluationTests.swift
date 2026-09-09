import Foundation
import XCTest
@testable import LensCore

final class OrganizerEvaluationTests: XCTestCase {
    private struct Fixture: Decodable {
        let schemaVersion: Int
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let category: String
        let kind: String
        let createdAt: Date
        let manifestTitle: String
        let ocrText: String
        let expectedTitleContains: String
        let expectsSourceDateFallback: Bool
    }

    func testFixedSixtySampleOrganizerSetMeetsFirstPassQualityTarget() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let fixtureURL = resources
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("organizer-evaluation-v1.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: fixtureURL))

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.cases.count, 60)

        var passingIDs: [String] = []
        var failures: [String] = []
        for sample in fixture.cases {
            let kind: LensKind = sample.kind == "recording" ? .recording : .screenshot
            let manifest = LensManifest(
                kind: kind,
                createdAt: sample.createdAt,
                title: sample.manifestTitle,
                dimensions: LensDimensions(width: 1_920, height: 1_080),
                assets: []
            )
            let ocr = OCRDocument(
                engine: "fixture",
                recognizedAt: sample.createdAt,
                recognitionLanguages: sample.category == "multilingual"
                    ? ["zh-Hans"]
                    : ["en-US"],
                blocks: [OCRTextBlock(
                    text: sample.ocrText,
                    confidence: 0.9,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
                )]
            )
            let title = LocalLensOrganizer.organize(
                manifest: manifest,
                ocr: ocr,
                generatedAt: sample.createdAt
            ).suggestedTitle
            let passed = title.contains(sample.expectedTitleContains)
            if passed {
                passingIDs.append(sample.id)
            } else {
                failures.append(
                    "\(sample.id) [\(sample.category)] expected \(sample.expectedTitleContains), got \(title)"
                )
            }
            if sample.expectsSourceDateFallback {
                XCTAssertTrue(
                    title.contains(" · 2025-08-16"),
                    "\(sample.id) should use the stable source/date fallback"
                )
            }
        }

        let score = Double(passingIDs.count) / Double(fixture.cases.count)
        XCTAssertGreaterThanOrEqual(
            score,
            0.85,
            failures.joined(separator: "\n")
        )
        XCTAssertEqual(passingIDs.count, fixture.cases.count, failures.joined(separator: "\n"))
    }
}
