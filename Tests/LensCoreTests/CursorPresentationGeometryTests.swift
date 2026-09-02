import CoreGraphics
import XCTest
@testable import LensCore

final class CursorPresentationGeometryTests: XCTestCase {
    func testOverlayAndRendererShareTheSameCursorFrame() {
        let point = CGPoint(x: 120, y: 80)
        let frame = CameraPresentationMapping.cursorFrame(
            at: point,
            sourcePixelWidth: 1_280,
            userScale: 1.5,
            relativeWidth: 1,
            imageSize: CGSize(width: 48, height: 64),
            hotSpot: CGPoint(x: 0.1, y: 0.08)
        )
        let width = CameraPresentationMapping.baseCursorWidth(sourcePixelWidth: 1_280) * 1.5
        XCTAssertEqual(frame.width, width, accuracy: 0.001)
        XCTAssertEqual(frame.height, width * 64 / 48, accuracy: 0.001)
        XCTAssertEqual(frame.minX, point.x - width * 0.1, accuracy: 0.001)
        XCTAssertEqual(frame.minY, point.y - frame.height * 0.08, accuracy: 0.001)
    }

    func testOverlayAndRendererShareIdenticalGlyphPixels() throws {
        for kind in CursorGlyphFactory.Kind.allCases {
            let first = try XCTUnwrap(CursorGlyphFactory.image(kind))
            let second = try XCTUnwrap(CursorGlyphFactory.image(kind))
            XCTAssertEqual(first.width, second.width)
            XCTAssertEqual(first.height, second.height)
            XCTAssertEqual(pixelDigest(first), pixelDigest(second), kind.rawValue)
        }
    }

    private func pixelDigest(_ image: CGImage) -> Data {
        let width = image.width
        let height = image.height
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    func testClickPulseDiameterScalesFromTheSharedCursorBaseline() {
        let diameter = CameraPresentationMapping.clickPulseDiameter(
            sourcePixelWidth: 1_920,
            pulseScale: 1
        )
        XCTAssertEqual(
            diameter,
            CameraPresentationMapping.baseCursorWidth(sourcePixelWidth: 1_920) * 1.85,
            accuracy: 0.001
        )
    }
}
