import AppKit
import CoreImage
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class PresenterCameraRendererTests: XCTestCase {
    func testRoundedPresenterLayoutAnchorsAndMirrorsCameraImage() throws {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 200)
        let screen = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: extent)
        let cameraExtent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let camera = red.composited(over: blue).cropped(to: cameraExtent)
        let layout = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.4,
            margin: 0.05,
            cornerRadius: 0.12,
            isMirrored: true,
            shadowOpacity: 0.3
        )

        let result = PresenterCameraRenderer.compose(
            screen: screen,
            camera: camera,
            layout: layout,
            outputExtent: extent
        )
        let bitmap = try render(result, extent: extent)
        // NSBitmapImageRep exposes image rows from the top, while Core Image uses a bottom origin.
        let left = try color(bitmap, x: 245, y: 145)
        let right = try color(bitmap, x: 355, y: 145)

        XCTAssertGreaterThan(left.blueComponent, 0.8)
        XCTAssertLessThan(left.redComponent, 0.2)
        XCTAssertGreaterThan(right.redComponent, 0.8)
        XCTAssertLessThan(right.blueComponent, 0.2)
    }

    func testCirclePresenterMaskLeavesBoundingCornersUntouched() throws {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screen = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
            .cropped(to: extent)
        let camera = CIImage(color: CIColor(red: 0.05, green: 0.9, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let layout = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .circle,
            anchor: .bottomLeading,
            size: 0.4,
            margin: 0,
            isMirrored: false,
            shadowOpacity: 0
        )

        let result = PresenterCameraRenderer.compose(
            screen: screen,
            camera: camera,
            layout: layout,
            outputExtent: extent
        )
        let bitmap = try render(result, extent: extent)
        let center = try color(bitmap, x: 40, y: 40)
        let corner = try color(bitmap, x: 2, y: 2)

        XCTAssertGreaterThan(center.greenComponent, 0.8)
        XCTAssertLessThan(center.redComponent, 0.2)
        XCTAssertGreaterThan(corner.redComponent, 0.85)
        XCTAssertGreaterThan(corner.greenComponent, 0.85)
        XCTAssertGreaterThan(corner.blueComponent, 0.85)
    }

    private func render(_ image: CIImage, extent: CGRect) throws -> NSBitmapImageRep {
        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: extent))
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }
}
