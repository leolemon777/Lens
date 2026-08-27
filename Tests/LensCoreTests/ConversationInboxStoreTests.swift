import Foundation
import XCTest
@testable import LensCore

final class ConversationInboxStoreTests: XCTestCase {
    func testDefaultDirectoryLivesUnderTheLensRoot() {
        let root = URL(fileURLWithPath: "/tmp/Lens", isDirectory: true)
        XCTAssertEqual(
            ConversationInboxStore.directory(under: root),
            root.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(ConversationInboxStore.latestFileName, "latest.png")
    }

    func testResolvedDirectoryFallsBackWhenPathIsMissingOrAFile() throws {
        XCTAssertEqual(
            ConversationInboxStore.resolvedDirectory(storedPath: nil),
            ConversationInboxStore.defaultDirectory()
        )
        XCTAssertEqual(
            ConversationInboxStore.resolvedDirectory(storedPath: ""),
            ConversationInboxStore.defaultDirectory()
        )

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationInboxFile-\(UUID().uuidString)")
        try Data([0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(
            ConversationInboxStore.resolvedDirectory(storedPath: file.path),
            ConversationInboxStore.defaultDirectory()
        )

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(
            ConversationInboxStore.resolvedDirectory(storedPath: directory.path),
            directory.standardizedFileURL
        )
    }

    func testSaveWritesLatestAndATimestampedArchive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationInboxStore(directory: directory)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = try store.save(pngData: png, createdAt: createdAt)

        XCTAssertEqual(snapshot.directory, directory.standardizedFileURL)
        XCTAssertEqual(snapshot.latestURL.lastPathComponent, "latest.png")
        XCTAssertEqual(try Data(contentsOf: snapshot.latestURL), png)
        XCTAssertEqual(try Data(contentsOf: snapshot.archivedURL), png)
        XCTAssertTrue(snapshot.archivedURL.lastPathComponent.hasPrefix("Lens-"))
        XCTAssertTrue(snapshot.archivedURL.pathExtension == "png")
        XCTAssertNotEqual(snapshot.archivedURL.lastPathComponent, "latest.png")
    }

    func testLaterSaveOverwritesLatestWithoutDeletingThePreviousArchive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationInboxStore(directory: directory)
        let first = Data([0x89, 0x01])
        let second = Data([0x89, 0x02])
        let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondAt = Date(timeIntervalSince1970: 1_700_000_030)

        let firstSnapshot = try store.save(pngData: first, createdAt: firstAt)
        let secondSnapshot = try store.save(pngData: second, createdAt: secondAt)

        XCTAssertEqual(try Data(contentsOf: store.latestURL), second)
        XCTAssertEqual(try Data(contentsOf: firstSnapshot.archivedURL), first)
        XCTAssertEqual(try Data(contentsOf: secondSnapshot.archivedURL), second)
        XCTAssertNotEqual(firstSnapshot.archivedURL, secondSnapshot.archivedURL)
    }

    func testSameSecondSaveUsesANumericSuffixInsteadOfOverwritingTheArchive() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationInboxStore(directory: directory)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try store.save(pngData: Data([0x89, 0x01]), createdAt: createdAt)
        let second = try store.save(pngData: Data([0x89, 0x02]), createdAt: createdAt)

        XCTAssertNotEqual(first.archivedURL, second.archivedURL)
        XCTAssertTrue(second.archivedURL.lastPathComponent.hasSuffix("-2.png"))
        XCTAssertEqual(try Data(contentsOf: first.archivedURL), Data([0x89, 0x01]))
        XCTAssertEqual(try Data(contentsOf: second.archivedURL), Data([0x89, 0x02]))
        XCTAssertEqual(try Data(contentsOf: store.latestURL), Data([0x89, 0x02]))
    }

    func testEmptyPNGIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationInboxStore(directory: directory)

        XCTAssertThrowsError(try store.save(pngData: Data())) { error in
            XCTAssertEqual(error as? ConversationInboxStoreError, .emptyPNG)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.latestURL.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationInbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
