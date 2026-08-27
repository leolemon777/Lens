import AppKit
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class QuickAccessViewTests: XCTestCase {
    func testOneHundredScreenshotDeliveriesRemainReadableAndDraggable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessStress-\(UUID().uuidString)", isDirectory: true)
        let store = LensProjectStore(rootDirectory: root)
        let png = try pngData(color: .systemTeal)
        let image = try XCTUnwrap(NSImage(data: png))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.\(UUID().uuidString)")
        )
        var durations: [Double] = []
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }

        for index in 0..<100 {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let lens = try store.saveScreenshot(
                pngData: png,
                width: 12,
                height: 8,
                titlePrefix: "G1-\(index)"
            )
            let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: lens))
            let provider = QuickAccessFileTransfer.itemProvider(
                fileURL: fileURL,
                suggestedName: QuickAccessFileTransfer.suggestedFileName(
                    for: lens,
                    fileURL: fileURL
                ),
                fallbackImage: image
            )

            XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
            XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))
            XCTAssertEqual(try Data(contentsOf: fileURL), png)
            XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.png"))
            durations.append((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        }

        let sorted = durations.sorted()
        let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        XCTAssertLessThan(p95, 250, "100-cycle local delivery P95 regressed to \(p95) ms")
    }

    func testClipboardSuccessRequiresDiscoverableImageRepresentation() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("LensTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let image = try XCTUnwrap(NSImage(data: pngData(color: .systemOrange)))

        XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
        XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))
    }

    func testFileTransferPrefersRenderedScreenshotAndAdvertisesRealPNGFile() throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }

        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.lens))
        let suggestedName = QuickAccessFileTransfer.suggestedFileName(
            for: fixture.lens,
            fileURL: fileURL
        )
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: suggestedName,
            fallbackImage: NSImage(size: CGSize(width: 4, height: 4))
        )

        XCTAssertEqual(fileURL, fixture.lens.packageURL.appendingPathComponent("previews/annotated.png"))
        XCTAssertTrue(suggestedName.hasPrefix("Lens-"))
        XCTAssertTrue(suggestedName.hasSuffix(".png"))
        XCTAssertFalse(suggestedName.contains("/"))
        XCTAssertEqual(provider.suggestedName, suggestedName)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.png"))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
    }

    func testFileTransferFallsBackToRawScreenshotWhenRenderedAssetIsMissing() throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/missing.png",
            createRenderedFile: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.lens),
            fixture.lens.rawAssetURL
        )
    }

    func testFileTransferRejectsManifestPathOutsideLensPackage() throws {
        let fixture = try makeLens(
            renderedRelativePath: "../../outside.png",
            createRenderedFile: false
        )
        let outsideURL = fixture.lens.packageURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outsideURL)
        defer {
            try? FileManager.default.removeItem(at: fixture.lens.packageURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.lens),
            fixture.lens.rawAssetURL
        )
    }

    func testFileTransferPrefersRenderedRecordingForShareableDelivery() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessRecording-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screen.mp4")
        let renderedURL = packageURL.appendingPathComponent("previews/share.mp4")
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renderedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawURL)
        try Data("share".utf8).write(to: renderedURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .recording,
                title: "演示录屏",
                durationSeconds: 12,
                dimensions: LensDimensions(width: 1280, height: 720),
                assets: [
                    LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    LensAsset(role: .renderedVideo, relativePath: "previews/share.mp4")
                ]
            )
        )

        XCTAssertEqual(QuickAccessFileTransfer.bestFileURL(for: lens), renderedURL)
        XCTAssertTrue(
            QuickAccessFileTransfer.suggestedFileName(for: lens, fileURL: renderedURL)
                .hasSuffix(".mp4")
        )
    }

    func testFileProviderMaterializesTheRenderedPNGBytes() async throws {
        let fixture = try makeLens(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.lens.packageURL) }
        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.lens))
        let expected = try Data(contentsOf: fileURL)
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: "Lens-E2.png",
            fallbackImage: NSImage(size: CGSize(width: 4, height: 4))
        )

        let transferred = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: "public.png") { url, error in
                do {
                    if let error { throw error }
                    let url = try XCTUnwrap(url)
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(transferred, expected)
        XCTAssertNotNil(NSImage(data: transferred))
    }

    private func makeLens(
        renderedRelativePath: String,
        createRenderedFile: Bool
    ) throws -> (lens: SavedLens, rawURL: URL) {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccess-\(UUID().uuidString).lens", isDirectory: true)
        let rawURL = packageURL.appendingPathComponent("raw/screenshot.png")
        try FileManager.default.createDirectory(
            at: rawURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData(color: .cyan).write(to: rawURL)

        if createRenderedFile {
            let renderedURL = packageURL.appendingPathComponent(renderedRelativePath)
            try FileManager.default.createDirectory(
                at: renderedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData(color: .systemOrange).write(to: renderedURL)
        }

        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: LensManifest(
                kind: .screenshot,
                title: "Quick Access",
                dimensions: LensDimensions(width: 320, height: 180),
                assets: [
                    LensAsset(role: .screenshot, relativePath: "raw/screenshot.png"),
                    LensAsset(role: .renderedScreenshot, relativePath: renderedRelativePath)
                ]
            )
        )
        return (lens, rawURL)
    }

    private func pngData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
