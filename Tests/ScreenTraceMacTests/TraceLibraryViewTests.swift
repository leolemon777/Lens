import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class TraceLibraryViewTests: XCTestCase {
    func testLibraryViewLaysOutAndRendersWithMixedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceLibraryViewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let screenshotURL = root.appendingPathComponent("screenshot.png")
        try screenshotPNGData(width: 960, height: 540).write(to: screenshotURL)
        let screenshot = makeEntry(
            root: root,
            kind: .screenshot,
            title: "设计评审截图",
            assetURL: screenshotURL,
            state: .ready,
            duration: nil,
            ocrText: "ScreenTrace launch checklist"
        )
        let recordingURL = root.appendingPathComponent("recording.mp4")
        let recording = makeEntry(
            root: root,
            kind: .recording,
            title: "自然运镜演示",
            assetURL: recordingURL,
            state: .processing,
            duration: 72,
            ocrText: nil
        )
        let model = TraceLibraryModel(
            store: TraceProjectStore(rootDirectory: root),
            initialEntries: [screenshot, recording]
        )
        let rootView = TraceLibraryView(
            model: model,
            onOpen: { _ in },
            onReveal: { _ in },
            onCopy: { _ in },
            onAnnotate: { _ in },
            onOpenFolder: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_020, height: 690)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1_020)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 690)
        XCTAssertEqual(
            Double(representation.pixelsWide) / Double(representation.pixelsHigh),
            34.0 / 23.0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(png?.count ?? 0, 25_000)
    }

    private func makeEntry(
        root: URL,
        kind: TraceKind,
        title: String,
        assetURL: URL,
        state: TraceState,
        duration: Double?,
        ocrText: String?
    ) -> TraceLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).screentrace", isDirectory: true)
        let role: TraceAsset.Role = kind == .screenshot ? .screenshot : .screenVideo
        let manifest = TraceManifest(
            id: id,
            kind: kind,
            title: title,
            state: state,
            durationSeconds: duration,
            dimensions: TraceDimensions(width: 960, height: 540),
            assets: [TraceAsset(role: role, relativePath: assetURL.lastPathComponent)]
        )
        return TraceLibraryEntry(
            packageURL: package,
            manifest: manifest,
            primaryAssetURL: assetURL,
            displayAssetURL: assetURL,
            ocrText: ocrText
        )
    }

    private func screenshotPNGData(width: Int, height: Int) throws -> Data {
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
        context.setFillColor(CGColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.15, green: 0.78, blue: 0.90, alpha: 1))
        context.fill(CGRect(x: 90, y: 90, width: 460, height: 260))
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create source image")
        }
        return try ImageEncoding.pngData(from: image)
    }
}
