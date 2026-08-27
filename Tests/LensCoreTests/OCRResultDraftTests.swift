import Foundation
import XCTest
@testable import LensCore

final class OCRResultDraftTests: XCTestCase {
    func testDraftStartsFromDocumentTextAndCanBeResetAfterEditing() {
        let document = OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            fullText: "第一行\n第二行",
            blocks: [
                OCRTextBlock(
                    text: "第一行",
                    confidence: 0.9,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 0.5)
                ),
                OCRTextBlock(
                    text: "第二行",
                    confidence: 0.8,
                    normalizedBounds: LensRect(x: 0, y: 0.5, width: 1, height: 0.5)
                )
            ]
        )
        var draft = OCRResultDraft(document: document)

        XCTAssertEqual(draft.originalText, "第一行\n第二行")
        XCTAssertEqual(draft.editedText, "第一行\n第二行")
        XCTAssertEqual(draft.blockCount, 2)
        XCTAssertFalse(draft.isEdited)
        XCTAssertTrue(draft.hasText)

        draft.editedText = "改过的文字"
        XCTAssertTrue(draft.isEdited)
        XCTAssertEqual(draft.originalText, "第一行\n第二行")

        draft.reset()
        XCTAssertEqual(draft.editedText, "第一行\n第二行")
        XCTAssertFalse(draft.isEdited)
    }

    func testBlankEditedTextIsNotTreatableAsCopyableResult() {
        var draft = OCRResultDraft(originalText: "  有字  ", blockCount: 1)
        XCTAssertTrue(draft.hasText)
        draft.editedText = " \n "
        XCTAssertFalse(draft.hasText)
        XCTAssertTrue(draft.isEdited)
    }
}
