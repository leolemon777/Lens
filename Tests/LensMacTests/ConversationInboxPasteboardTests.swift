import AppKit
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class ConversationInboxPasteboardTests: XCTestCase {
    func testCopyPathPutsPOSIXPathAndClearsAnyPreviousImage() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.Inbox.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
        XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))

        let fileURL = URL(fileURLWithPath: "/tmp/Lens/Inbox/latest.png")
        XCTAssertTrue(ConversationInboxPasteboard.copyPath(fileURL, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), fileURL.path)
        XCTAssertNil(pasteboard.availableType(from: [.png, .tiff]))
    }
}
