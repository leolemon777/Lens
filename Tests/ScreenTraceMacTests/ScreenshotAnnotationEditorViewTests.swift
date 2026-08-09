import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class ScreenshotAnnotationEditorViewTests: XCTestCase {
    func testEditorViewLaysOutAndRendersAtDesktopWindowSize() throws {
        let image = try sourceImage(width: 1_000, height: 600)
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: TraceDimensions(width: 1_000, height: 600)
        )
        model.selectedTool = .rectangle
        _ = model.commitDraft(
            start: TracePoint(x: 0.1, y: 0.1),
            end: TracePoint(x: 0.4, y: 0.4)
        )
        let root = ScreenshotAnnotationEditorView(
            model: model,
            image: image,
            onSave: { _ in },
            onCancel: {}
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_080, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_080)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 720)
        XCTAssertEqual(
            Double(representation.pixelsWide) / Double(representation.pixelsHigh),
            1.5,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(png?.count ?? 0, 20_000)
    }

    private func sourceImage(width: Int, height: Int) throws -> NSImage {
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
            throw XCTSkip("Unable to create source bitmap")
        }
        context.setFillColor(CGColor(red: 0.18, green: 0.24, blue: 0.34, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create source image")
        }
        return ImageEncoding.nsImage(from: image)
    }
}
