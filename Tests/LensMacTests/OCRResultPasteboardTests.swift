import AppKit
import XCTest
@testable import LensMac

@MainActor
final class OCRResultPasteboardTests: XCTestCase {
    func testCopyWritesEditedTextInsteadOfAnImage() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.OCR.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(OCRResultPasteboard.copy("改过的识别结果", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "改过的识别结果")
        XCTAssertNil(pasteboard.availableType(from: [.png, .tiff]))
    }
}
