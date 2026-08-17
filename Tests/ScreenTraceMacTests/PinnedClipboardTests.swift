import AppKit
import XCTest
@testable import ScreenTraceMac

@MainActor
final class PinnedClipboardTests: XCTestCase {
    func testReadsImageFromPasteboardBeforeText() throws {
        let pasteboard = NSPasteboard(name: .init("PinImage-\(UUID().uuidString)"))
        let image = NSImage(size: CGSize(width: 64, height: 40), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        pasteboard.clearContents()
        XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))

        let item = try XCTUnwrap(PinnedClipboardReader.read(from: pasteboard))
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.title, "剪贴板图像")
        XCTAssertEqual(item.image.size.width, 64, accuracy: 0.5)
    }

    func testReadsHexAndRGBColorsAndLeavesOrdinaryTextAsACard() throws {
        XCTAssertNotNil(PinnedColorSwatch.color(from: "#3B82F6"))
        XCTAssertEqual(PinnedColorSwatch.hexString(try XCTUnwrap(PinnedColorSwatch.color(from: "#00ff00"))), "#00FF00")
        XCTAssertNotNil(PinnedColorSwatch.color(from: "rgb(255, 0, 128)"))
        XCTAssertNil(PinnedColorSwatch.color(from: "只是一段说明文字"))

        let colorPasteboard = NSPasteboard(name: .init("PinColor-\(UUID().uuidString)"))
        colorPasteboard.clearContents()
        colorPasteboard.setString("#112233", forType: .string)
        let colorItem = try XCTUnwrap(PinnedClipboardReader.read(from: colorPasteboard))
        XCTAssertEqual(colorItem.kind, .color)
        XCTAssertEqual(colorItem.title, "#112233")
        XCTAssertGreaterThan(colorItem.image.size.width, 40)

        let textPasteboard = NSPasteboard(name: .init("PinText-\(UUID().uuidString)"))
        textPasteboard.clearContents()
        textPasteboard.setString("API_TOKEN=demo", forType: .string)
        let textItem = try XCTUnwrap(PinnedClipboardReader.read(from: textPasteboard))
        XCTAssertEqual(textItem.kind, .text)
        XCTAssertEqual(textItem.title, "API_TOKEN=demo")
        XCTAssertGreaterThan(textItem.image.size.height, 20)
    }

    func testEmptyPasteboardIsNotPinned() {
        let pasteboard = NSPasteboard(name: .init("PinEmpty-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertNil(PinnedClipboardReader.read(from: pasteboard))
    }
}
