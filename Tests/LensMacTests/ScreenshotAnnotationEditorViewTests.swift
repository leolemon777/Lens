import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import LensCore
@testable import LensMac

@MainActor
final class ScreenshotAnnotationEditorViewTests: XCTestCase {
    func testAccessibilityAuditRequiresNamedScreenshotSliders() throws {
        let editorSource = try String(
            contentsOf: screenshotEditorSourceURL(
                "Sources/LensMac/UI/ScreenshotAnnotationEditorView.swift"
            ),
            encoding: .utf8
        )
        let canvasSource = try String(
            contentsOf: screenshotEditorSourceURL(
                "Sources/LensMac/UI/ScreenshotCanvasToolbar.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(editorSource.contains(
            ".accessibilityLabel(\"\\(activeEffectAnnotation?.editorTitle ?? \"效果\")强度\")"
        ))
        XCTAssertTrue(canvasSource.contains(".accessibilityLabel(\"画布\\(title)\")"))
        XCTAssertTrue(canvasSource.contains(".accessibilityValue"))
        XCTAssertTrue(editorSource.contains("setAccessibilityRole(.group)"))
        XCTAssertTrue(editorSource.contains("setAccessibilityValue(value)"))
    }

    func testSensitiveRedactionSuggestionsExposeAReviewSurface() throws {
        let source = try String(
            contentsOf: screenshotEditorSourceURL(
                "Sources/LensMac/UI/ScreenshotAnnotationEditorView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("showsRedactionReview.toggle()"))
        XCTAssertTrue(source.contains("redactionReviewPanel"))
        XCTAssertTrue(source.contains("橙色虚线框只表示 OCR 建议"))
        XCTAssertTrue(source.contains("model.applySuggestedRedaction(suggestion.id)"))
        XCTAssertTrue(source.contains("model.dismissSuggestedRedaction(suggestion.id)"))
        XCTAssertTrue(source.contains("drawPendingRedaction"))
        XCTAssertTrue(source.contains("待复核敏感信息建议"))
    }

    func testEditorViewLaysOutAndRendersAtDesktopWindowSize() throws {
        let image = try sourceImage(width: 1_000, height: 600)
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: LensDimensions(width: 1_000, height: 600)
        )
        model.selectedTool = .rectangle
        _ = model.commitDraft(
            start: LensPoint(x: 0.1, y: 0.1),
            end: LensPoint(x: 0.4, y: 0.4)
        )
        model.activateSelectionTool()
        model.setCanvasEnabled(true)
        model.setCanvasAspectRatio(.widescreen16x9)
        model.beginSelectionInteraction(
            at: LensPoint(x: 0.2, y: 0.2),
            hitTolerance: 0.01,
            handleTolerance: 0.01
        )
        model.endSelectionInteraction()
        let root = ScreenshotAnnotationEditorView(
            model: model,
            image: image,
            onSave: { _ in },
            onCopy: { _ in },
            onExport: { _, _ in },
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

    func testPendingRedactionOverlayRendersForVisualReview() throws {
        let image = try sourceImage(width: 1_000, height: 600)
        let suggestion = ScreenshotAnnotation(
            kind: .pixelate,
            bounds: LensRect(x: 0.24, y: 0.32, width: 0.28, height: 0.08),
            style: ScreenshotAnnotationStyle(intensity: 0.05)
        )
        let model = ScreenshotAnnotationEditorModel(
            sourceDimensions: LensDimensions(width: 1_000, height: 600),
            suggestedRedactions: [suggestion]
        )
        let root = ScreenshotAnnotationEditorView(
            model: model,
            image: image,
            onSave: { _ in },
            onCopy: { _ in },
            onExport: { _, _ in },
            onCancel: {}
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_080, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["LENS_REDACTION_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertGreaterThan(png.count, 20_000)
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

private func screenshotEditorSourceURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
}
