import CoreGraphics
import XCTest
@testable import LensCore

final class CameraPresentationMappingTests: XCTestCase {
    func testAspectFitLetterboxesWideContentInsideTallBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 202, height: 360)
        let rect = CameraPresentationMapping.aspectFitRect(
            for: CGSize(width: 640, height: 360),
            in: bounds
        )
        XCTAssertEqual(rect.width, 202, accuracy: 0.001)
        XCTAssertEqual(rect.height, 202 * 360 / 640, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertGreaterThan(rect.minY, 0)
    }

    func testSameAspectDeliveryKeepsCursorOnSourceViewport() {
        let source = CGRect(x: 0, y: 0, width: 640, height: 360)
        let point = CameraPresentationMapping.ciOutputPoint(
            sourceNormalized: LensPoint(x: 0.5, y: 0.25),
            sourceExtent: source,
            viewport: source,
            scale: 1,
            deliveryExtent: source,
            contentSize: source.size
        )
        XCTAssertEqual(point.x, 320, accuracy: 0.001)
        XCTAssertEqual(point.y, 270, accuracy: 0.001)
    }

    func testVerticalReframeAddsContainOffsetAndUsesSourceExtent() {
        let source = CGRect(x: 0, y: 0, width: 640, height: 360)
        let delivery = CGRect(x: 0, y: 0, width: 202, height: 360)
        let scale = CGFloat(202) / 640
        let contentSize = CGSize(width: 202, height: 360 * scale)
        let center = CameraPresentationMapping.ciOutputPoint(
            sourceNormalized: LensPoint(x: 0.5, y: 0.5),
            sourceExtent: source,
            viewport: source,
            scale: scale,
            deliveryExtent: delivery,
            contentSize: contentSize
        )
        XCTAssertEqual(center.x, contentSize.width / 2, accuracy: 0.05)
        XCTAssertEqual(center.y, delivery.height / 2, accuracy: 0.05)

        let buggyIfMappedAgainstDeliveryWidth = 202 * 0.5 * scale
        XCTAssertGreaterThan(
            abs(center.x - buggyIfMappedAgainstDeliveryWidth),
            20,
            "Must map against source extent, not the 9:16 canvas width"
        )
    }
}
