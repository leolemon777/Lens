import Foundation
import XCTest
@testable import LensCore

final class SensitiveRedactionPlannerTests: XCTestCase {
    /// Each tuple: (x, y, width, height, text) in normalized bounds.
    private func ocr(_ blocks: [(x: Double, y: Double, w: Double, h: Double, text: String)]) -> OCRDocument {
        OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            blocks: blocks.map {
                OCRTextBlock(
                    text: $0.text,
                    confidence: 0.9,
                    normalizedBounds: LensRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)
                )
            }
        )
    }

    func testEmailMatchBecomesPaddedPixelateAnnotation() throws {
        let suggestions = SensitiveRedactionPlanner().suggestions(
            ocr: ocr([(x: 0.1, y: 0.4, w: 0.5, h: 0.02, text: "联系 someone@example.com 谢谢")])
        )
        XCTAssertEqual(suggestions.count, 1)
        let annotation = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(annotation.kind, .pixelate)
        XCTAssertEqual(annotation.style.intensity, 0.05, accuracy: 0.000_1)
        // The hit stays inside the block's horizontal span (an email that
        // fills the line legitimately covers it whole) and expands vertically.
        XCTAssertGreaterThanOrEqual(annotation.bounds.x, 0.1)
        XCTAssertLessThanOrEqual(annotation.bounds.x + annotation.bounds.width, 0.6)
        XCTAssertLessThan(annotation.bounds.y, 0.4)
        XCTAssertGreaterThan(annotation.bounds.height, 0.02)
    }

    func testAdjacentHitsInOneBlockMergeIntoSingleRect() {
        let suggestions = SensitiveRedactionPlanner().suggestions(
            ocr: ocr([(x: 0.1, y: 0.4, w: 0.6, h: 0.02, text: "a@b.co 和 c@d.io 都在这里")])
        )
        XCTAssertEqual(suggestions.count, 1)
    }

    func testCleanTextProducesNoSuggestions() {
        let suggestions = SensitiveRedactionPlanner().suggestions(
            ocr: ocr([(x: 0.1, y: 0.4, w: 0.5, h: 0.02, text: "普通文本 12345 而已")])
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testInvalidChecksumNumbersAreNotFlagged() {
        // 18 digits but wrong ISO 7064 checksum — must not trigger redaction.
        let suggestions = SensitiveRedactionPlanner().suggestions(
            ocr: ocr([(x: 0.1, y: 0.4, w: 0.5, h: 0.02, text: "号码 123456789012345678 结束")])
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testMaximumSuggestionsCapIsRespected() {
        var blocks: [(x: Double, y: Double, w: Double, h: Double, text: String)] = []
        for index in 0..<60 {
            blocks.append((
                x: 0.1,
                y: 0.4,
                w: 0.5,
                h: 0.02,
                text: "第\(index)个 user\(index)@example.com"
            ))
        }
        let suggestions = SensitiveRedactionPlanner().suggestions(ocr: ocr(blocks))
        XCTAssertEqual(suggestions.count, 40)
    }
}
