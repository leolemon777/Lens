import AppKit
import CoreGraphics
import Foundation
import XCTest
import LensCore
@testable import LensMac

final class ScreenshotEditingServiceTests: XCTestCase {
    @MainActor
    func testThumbnailCacheDropsSamePathWhenFileVersionChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensThumbnailCache-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first-version".utf8).write(to: url)

        let image = NSImage(size: NSSize(width: 12, height: 8))
        LensLibraryThumbnailCache.shared.insert(image, for: url)
        XCTAssertNotNil(LensLibraryThumbnailCache.shared.image(for: url))

        try Data("second-version-with-a-different-size".utf8).write(to: url)
        XCTAssertNil(
            LensLibraryThumbnailCache.shared.image(for: url),
            "A rewritten annotated.png must not reuse the old image for the same URL."
        )

        LensLibraryThumbnailCache.shared.insert(image, for: url)
        LensLibraryThumbnailCache.shared.invalidate(url)
        XCTAssertNil(LensLibraryThumbnailCache.shared.image(for: url))
    }

    func testJPEGExportFlattensTransparentPixelsOntoWhite() throws {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ), let transparentImage = context.makeImage() else {
            throw XCTSkip("Unable to create transparent bitmap")
        }

        let data = try ImageEncoding.jpegData(from: transparentImage, quality: 1)
        guard let representation = NSBitmapImageRep(data: data),
              let color = representation.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB) else {
            return XCTFail("Unable to decode exported JPEG")
        }

        XCTAssertGreaterThan(color.redComponent, 0.97)
        XCTAssertGreaterThan(color.greenComponent, 0.97)
        XCTAssertGreaterThan(color.blueComponent, 0.97)
    }

    func testFullEditingWorkflowWritesPreviewAndPlanWithoutMutatingRawImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensEditingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let source = try solidImage(width: 360, height: 220)
        let rawPNG = try ImageEncoding.pngData(from: source)
        let lens = try store.saveScreenshot(
            pngData: rawPNG,
            width: source.width,
            height: source.height
        )
        let plan = ScreenshotEditPlan(
            sourceDimensions: LensDimensions(width: source.width, height: source.height),
            annotations: [
                ScreenshotAnnotation(
                    kind: .rectangle,
                    bounds: LensRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.02, color: .red)
                )
            ]
        )

        let result = try ScreenshotEditingService(store: store).renderAndSave(
            source: source,
            plan: plan,
            lens: lens
        )

        XCTAssertEqual(try Data(contentsOf: lens.rawAssetURL), rawPNG)
        XCTAssertGreaterThan(try Data(contentsOf: result.renderedImageURL).count, 100)
        XCTAssertEqual(try store.loadScreenshotEditPlan(from: lens.packageURL), plan)
        XCTAssertTrue(result.lens.manifest.assets.contains { $0.role == .screenshotEditPlan })
        XCTAssertTrue(result.lens.manifest.assets.contains { $0.role == .renderedScreenshot })
        XCTAssertNotEqual(
            try ImageEncoding.pngData(from: result.renderedImage),
            rawPNG
        )

        let pngURL = root.appendingPathComponent("export.png")
        let jpegURL = root.appendingPathComponent("export.jpg")
        let service = ScreenshotEditingService(store: store)
        try service.export(image: result.renderedImage, to: pngURL, format: .png)
        try service.export(image: result.renderedImage, to: jpegURL, format: .jpeg)

        XCTAssertGreaterThan(try Data(contentsOf: pngURL).count, 100)
        XCTAssertGreaterThan(try Data(contentsOf: jpegURL).count, 100)
        XCTAssertNotNil(NSImage(contentsOf: pngURL))
        XCTAssertNotNil(NSImage(contentsOf: jpegURL))
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create bitmap context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to make source image")
        }
        return image
    }
}
