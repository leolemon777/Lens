import CoreGraphics
import XCTest
import ScreenTraceCore
@testable import ScreenTraceMac

final class ScreenshotAnnotationRendererTests: XCTestCase {
    func testVectorAnnotationsRenderVisibleRectangleArrowAndText() throws {
        let source = try solidImage(width: 480, height: 300, gray: 1)
        let dimensions = TraceDimensions(width: source.width, height: source.height)
        let plan = ScreenshotEditPlan(
            sourceDimensions: dimensions,
            annotations: [
                ScreenshotAnnotation(
                    kind: .rectangle,
                    bounds: TraceRect(x: 0.08, y: 0.08, width: 0.34, height: 0.32),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.018, color: .red)
                ),
                ScreenshotAnnotation(
                    kind: .arrow,
                    bounds: TraceRect(x: 0.12, y: 0.75, width: 0.72, height: -0.48),
                    start: TracePoint(x: 0.12, y: 0.75),
                    end: TracePoint(x: 0.84, y: 0.27),
                    style: ScreenshotAnnotationStyle(lineWidth: 0.014, color: .blue)
                ),
                ScreenshotAnnotation(
                    kind: .text,
                    bounds: TraceRect(x: 0.50, y: 0.72, width: 0.4, height: 0.1),
                    text: "ScreenTrace",
                    style: ScreenshotAnnotationStyle(fontSize: 0.07, color: .yellow)
                )
            ]
        )

        let output = try ScreenshotAnnotationRenderer().render(source: source, plan: plan)
        let pixels = try rgbaPixels(output)

        XCTAssertEqual(output.width, source.width)
        XCTAssertEqual(output.height, source.height)
        XCTAssertGreaterThan(countPixels(pixels, matching: { $0.r > 210 && $0.g < 120 && $0.b < 120 }), 350)
        XCTAssertGreaterThan(countPixels(pixels, matching: { $0.b > 180 && $0.r < 120 }), 300)
        XCTAssertGreaterThan(countPixels(pixels, matching: { $0.r > 190 && $0.g > 140 && $0.b < 90 }), 100)
    }

    func testBlurAndPixelateChangeTargetRegionsButPreserveOutsidePixels() throws {
        let source = try checkerboardImage(width: 400, height: 240, cell: 3)
        let plan = ScreenshotEditPlan(
            sourceDimensions: TraceDimensions(width: source.width, height: source.height),
            annotations: [
                ScreenshotAnnotation(
                    kind: .blur,
                    bounds: TraceRect(x: 0.12, y: 0.25, width: 0.28, height: 0.5),
                    style: ScreenshotAnnotationStyle(intensity: 0.05)
                ),
                ScreenshotAnnotation(
                    kind: .pixelate,
                    bounds: TraceRect(x: 0.60, y: 0.25, width: 0.28, height: 0.5),
                    style: ScreenshotAnnotationStyle(intensity: 0.07)
                )
            ]
        )

        let output = try ScreenshotAnnotationRenderer().render(source: source, plan: plan)
        let inputPixels = try rgbaPixels(source)
        let outputPixels = try rgbaPixels(output)

        let leftDifference = meanDifference(
            inputPixels,
            outputPixels,
            width: source.width,
            height: source.height,
            normalizedRect: TraceRect(x: 0.14, y: 0.30, width: 0.24, height: 0.40)
        )
        let rightDifference = meanDifference(
            inputPixels,
            outputPixels,
            width: source.width,
            height: source.height,
            normalizedRect: TraceRect(x: 0.62, y: 0.30, width: 0.24, height: 0.40)
        )
        let outsideDifference = meanDifference(
            inputPixels,
            outputPixels,
            width: source.width,
            height: source.height,
            normalizedRect: TraceRect(x: 0.43, y: 0.05, width: 0.12, height: 0.14)
        )

        XCTAssertGreaterThan(leftDifference, 25)
        XCTAssertGreaterThan(rightDifference, 25)
        XCTAssertLessThan(outsideDifference, 2)
    }

    func testMismatchedDimensionsAreRejected() throws {
        let source = try solidImage(width: 100, height: 80, gray: 1)
        let plan = ScreenshotEditPlan(sourceDimensions: TraceDimensions(width: 101, height: 80))

        XCTAssertThrowsError(try ScreenshotAnnotationRenderer().render(source: source, plan: plan)) { error in
            XCTAssertTrue(error is ScreenshotAnnotationRendererError)
        }
    }

    private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    private func solidImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        try makeImage(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func checkerboardImage(width: Int, height: Int, cell: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { context in
            for y in stride(from: 0, to: height, by: cell) {
                for x in stride(from: 0, to: width, by: cell) {
                    let isLight = ((x / cell) + (y / cell)).isMultiple(of: 2)
                    context.setFillColor(CGColor(gray: isLight ? 1 : 0, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
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
        draw(context)
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to make CGImage")
        }
        return image
    }

    private func rgbaPixels(_ image: CGImage) throws -> [RGBA] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to read pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            (bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3])
        }
    }

    private func countPixels(_ pixels: [RGBA], matching predicate: (RGBA) -> Bool) -> Int {
        pixels.reduce(into: 0) { count, pixel in
            if predicate(pixel) { count += 1 }
        }
    }

    private func meanDifference(
        _ lhs: [RGBA],
        _ rhs: [RGBA],
        width: Int,
        height: Int,
        normalizedRect: TraceRect
    ) -> Double {
        let minX = max(Int(normalizedRect.x * Double(width)), 0)
        let maxX = min(Int((normalizedRect.x + normalizedRect.width) * Double(width)), width)
        let minY = max(Int(normalizedRect.y * Double(height)), 0)
        let maxY = min(Int((normalizedRect.y + normalizedRect.height) * Double(height)), height)
        var difference = 0.0
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let index = y * width + x
                difference += abs(Double(lhs[index].r) - Double(rhs[index].r))
                difference += abs(Double(lhs[index].g) - Double(rhs[index].g))
                difference += abs(Double(lhs[index].b) - Double(rhs[index].b))
                count += 3
            }
        }
        return count == 0 ? 0 : difference / Double(count)
    }
}
