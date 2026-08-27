import CoreGraphics
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class ScreenCaptureServiceTests: XCTestCase {
    func testThumbnailPixelSizeFitsRetinaWindowWithoutChangingAspectRatio() {
        XCTAssertEqual(
            ScreenCaptureService.thumbnailPixelSize(
                pointSize: CGSize(width: 1_440, height: 900),
                pointPixelScale: 2,
                maximumPixelSize: CGSize(width: 360, height: 220)
            ),
            CGSize(width: 352, height: 220)
        )
        XCTAssertEqual(
            ScreenCaptureService.thumbnailPixelSize(
                pointSize: CGSize(width: 100, height: 50),
                pointPixelScale: 1,
                maximumPixelSize: CGSize(width: 360, height: 220)
            ),
            CGSize(width: 100, height: 50)
        )
    }

    func testRegionSnapRectsKeepOnlyEligibleForeignWindows() {
        func item(pid: pid_t, layer: Int, rect: CGRect) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowBounds as String: rect.dictionaryRepresentation
            ]
        }
        let result = ScreenCaptureService().regionSnapRects(
            from: [
                item(pid: 99, layer: 0, rect: CGRect(x: 20, y: 30, width: 640, height: 480)),
                item(pid: 42, layer: 0, rect: CGRect(x: 0, y: 0, width: 800, height: 600)),
                item(pid: 99, layer: 4, rect: CGRect(x: 0, y: 0, width: 800, height: 600)),
                item(pid: 99, layer: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20))
            ],
            excludingProcessID: 42
        )

        XCTAssertEqual(result, [CGRect(x: 20, y: 30, width: 640, height: 480)])
    }

    func testWindowCompositionPreservesBackToFrontPixelOrder() throws {
        let back = WindowSelectionCandidate(
            id: 10,
            globalFrame: CGRect(x: 0, y: 0, width: 4, height: 4),
            frontToBackOrder: 4,
            title: "Back",
            applicationName: "Tests"
        )
        let front = WindowSelectionCandidate(
            id: 20,
            globalFrame: CGRect(x: 2, y: 0, width: 4, height: 4),
            frontToBackOrder: 1,
            title: "Front",
            applicationName: "Tests"
        )
        let layout = try XCTUnwrap(
            CaptureGeometry.multiWindowLayout(candidates: [front, back])
        )
        let composed = try ScreenCaptureService().composeWindowImages(
            [
                back.id: solidImage(red: 0, green: 0, blue: 1),
                front.id: solidImage(red: 1, green: 0, blue: 0)
            ],
            using: layout
        )

        XCTAssertEqual(composed.width, 6)
        XCTAssertEqual(composed.height, 4)
        XCTAssertEqual(rgb(in: composed, x: 1), [0, 0, 255])
        XCTAssertEqual(rgb(in: composed, x: 3), [255, 0, 0])
        XCTAssertEqual(rgb(in: composed, x: 5), [255, 0, 0])
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: colorSpace,
            components: [red, green, blue, 1]
        )!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private func rgb(in image: CGImage, x: Int) -> [UInt8] {
        let data = image.dataProvider!.data!
        let bytes = CFDataGetBytePtr(data)!
        let offset = image.bytesPerRow + (x * 4)
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }
}
