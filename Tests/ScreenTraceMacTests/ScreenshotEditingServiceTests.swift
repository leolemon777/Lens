import CoreGraphics
import Foundation
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

final class ScreenshotEditingServiceTests: XCTestCase {
    func testFullEditingWorkflowWritesPreviewAndPlanWithoutMutatingRawImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceEditingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let source = try solidImage(width: 360, height: 220)
        let rawPNG = try ImageEncoding.pngData(from: source)
        let trace = try store.saveScreenshot(
            pngData: rawPNG,
            width: source.width,
            height: source.height
        )
        let plan = ScreenshotEditPlan(
            sourceDimensions: TraceDimensions(width: source.width, height: source.height),
            annotations: [
                ScreenshotAnnotation(
                    kind: .rectangle,
                    bounds: TraceRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.02, color: .red)
                )
            ]
        )

        let result = try ScreenshotEditingService(store: store).renderAndSave(
            source: source,
            plan: plan,
            trace: trace
        )

        XCTAssertEqual(try Data(contentsOf: trace.rawAssetURL), rawPNG)
        XCTAssertGreaterThan(try Data(contentsOf: result.renderedImageURL).count, 100)
        XCTAssertEqual(try store.loadScreenshotEditPlan(from: trace.packageURL), plan)
        XCTAssertTrue(result.trace.manifest.assets.contains { $0.role == .screenshotEditPlan })
        XCTAssertTrue(result.trace.manifest.assets.contains { $0.role == .renderedScreenshot })
        XCTAssertNotEqual(
            try ImageEncoding.pngData(from: result.renderedImage),
            rawPNG
        )
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
