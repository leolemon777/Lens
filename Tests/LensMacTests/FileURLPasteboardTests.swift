import AppKit
import XCTest
@testable import LensMac

@MainActor
final class FileURLPasteboardTests: XCTestCase {
    func testCopyWritesAFileURLInsteadOfAnImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileURLPasteboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("share.mp4")
        try Data("video".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.FileURL.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(FileURLPasteboard.copy(fileURL, to: pasteboard))
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(copied?.first?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertNil(pasteboard.availableType(from: [.png, .tiff]))
    }
}
