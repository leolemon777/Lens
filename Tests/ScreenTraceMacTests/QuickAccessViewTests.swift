import AppKit
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

@MainActor
final class QuickAccessViewTests: XCTestCase {
    func testOneHundredScreenshotDeliveriesRemainReadableAndDraggable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccessStress-\(UUID().uuidString)", isDirectory: true)
        let store = TraceProjectStore(rootDirectory: root)
        let png = try pngData(color: .systemTeal)
        let image = try XCTUnwrap(NSImage(data: png))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ScreenTraceTests.\(UUID().uuidString)")
        )
        var durations: [Double] = []
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }

        for index in 0..<100 {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let trace = try store.saveScreenshot(
                pngData: png,
                width: 12,
                height: 8,
                titlePrefix: "G1-\(index)"
            )
            let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: trace))
            let provider = QuickAccessFileTransfer.itemProvider(
                fileURL: fileURL,
                suggestedName: QuickAccessFileTransfer.suggestedFileName(
                    for: trace,
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
            name: NSPasteboard.Name("ScreenTraceTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let image = try XCTUnwrap(NSImage(data: pngData(color: .systemOrange)))

        XCTAssertTrue(ImageClipboardWriter.write(image, to: pasteboard))
        XCTAssertNotNil(pasteboard.availableType(from: [.png, .tiff]))
    }

    func testFileTransferPrefersRenderedScreenshotAndAdvertisesRealPNGFile() throws {
        let fixture = try makeTrace(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.trace.packageURL) }

        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.trace))
        let suggestedName = QuickAccessFileTransfer.suggestedFileName(
            for: fixture.trace,
            fileURL: fileURL
        )
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: suggestedName,
            fallbackImage: NSImage(size: CGSize(width: 4, height: 4))
        )

        XCTAssertEqual(fileURL, fixture.trace.packageURL.appendingPathComponent("previews/annotated.png"))
        XCTAssertTrue(suggestedName.hasPrefix("ScreenTrace-"))
        XCTAssertTrue(suggestedName.hasSuffix(".png"))
        XCTAssertFalse(suggestedName.contains("/"))
        XCTAssertEqual(provider.suggestedName, suggestedName)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.png"))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"))
    }

    func testFileTransferFallsBackToRawScreenshotWhenRenderedAssetIsMissing() throws {
        let fixture = try makeTrace(
            renderedRelativePath: "previews/missing.png",
            createRenderedFile: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.trace.packageURL) }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.trace),
            fixture.trace.rawAssetURL
        )
    }

    func testFileTransferRejectsManifestPathOutsideTracePackage() throws {
        let fixture = try makeTrace(
            renderedRelativePath: "../../outside.png",
            createRenderedFile: false
        )
        let outsideURL = fixture.trace.packageURL
            .deletingLastPathComponent()
            .appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outsideURL)
        defer {
            try? FileManager.default.removeItem(at: fixture.trace.packageURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertEqual(
            QuickAccessFileTransfer.bestFileURL(for: fixture.trace),
            fixture.trace.rawAssetURL
        )
    }

    func testFileProviderMaterializesTheRenderedPNGBytes() async throws {
        let fixture = try makeTrace(
            renderedRelativePath: "previews/annotated.png",
            createRenderedFile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.trace.packageURL) }
        let fileURL = try XCTUnwrap(QuickAccessFileTransfer.bestFileURL(for: fixture.trace))
        let expected = try Data(contentsOf: fileURL)
        let provider = QuickAccessFileTransfer.itemProvider(
            fileURL: fileURL,
            suggestedName: "ScreenTrace-E2.png",
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

    private func makeTrace(
        renderedRelativePath: String,
        createRenderedFile: Bool
    ) throws -> (trace: SavedTrace, rawURL: URL) {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAccess-\(UUID().uuidString).screentrace", isDirectory: true)
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

        let trace = SavedTrace(
            packageURL: packageURL,
            rawAssetURL: rawURL,
            manifest: TraceManifest(
                kind: .screenshot,
                title: "Quick Access",
                dimensions: TraceDimensions(width: 320, height: 180),
                assets: [
                    TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png"),
                    TraceAsset(role: .renderedScreenshot, relativePath: renderedRelativePath)
                ]
            )
        )
        return (trace, rawURL)
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
