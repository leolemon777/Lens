import CoreGraphics
import CoreText
import XCTest
@testable import ScreenTraceMac

final class VisionOCRServiceTests: XCTestCase {
    func testSyntheticImageRecognizesEnglishAndProducesNormalizedTopLeftBounds() async throws {
        let image = try makeTextImage("SCREEN TRACE 2026")

        let document = try await VisionOCRService(
            preferredLanguages: ["en-US"]
        ).recognizeText(in: image)

        let normalizedText = document.fullText.uppercased()
        XCTAssertTrue(normalizedText.contains("SCREEN"), "Recognized text: \(document.fullText)")
        XCTAssertFalse(document.blocks.isEmpty)
        XCTAssertEqual(document.engine, "apple-vision")
        XCTAssertEqual(document.recognitionLanguages, ["en-US"])
        for block in document.blocks {
            XCTAssertGreaterThanOrEqual(block.normalizedBounds.x, 0)
            XCTAssertGreaterThanOrEqual(block.normalizedBounds.y, 0)
            XCTAssertGreaterThan(block.normalizedBounds.width, 0)
            XCTAssertGreaterThan(block.normalizedBounds.height, 0)
            XCTAssertLessThanOrEqual(block.normalizedBounds.x + block.normalizedBounds.width, 1.001)
            XCTAssertLessThanOrEqual(block.normalizedBounds.y + block.normalizedBounds.height, 1.001)
        }
    }

    private func makeTextImage(_ text: String) throws -> CGImage {
        let width = 1_600
        let height = 420
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create bitmap context")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 128, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0.02, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any])
        )
        context.textPosition = CGPoint(x: 70, y: 145)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create test image")
        }
        return image
    }
}
