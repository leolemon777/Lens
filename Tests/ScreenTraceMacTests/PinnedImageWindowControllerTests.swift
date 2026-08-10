import AppKit
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

@MainActor
final class PinnedImageWindowControllerTests: XCTestCase {
    func testInitialPresentationFitsLargeImageWithoutUpscalingSmallImage() {
        let large = PinnedImagePresentation(
            imageSize: CGSize(width: 1_600, height: 1_200),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        let small = PinnedImagePresentation(
            imageSize: CGSize(width: 320, height: 200),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )

        XCTAssertEqual(large.windowSize.width, 520, accuracy: 0.001)
        XCTAssertEqual(large.windowSize.height, 390, accuracy: 0.001)
        XCTAssertEqual(small.windowSize, CGSize(width: 320, height: 200))
    }

    func testZoomAndOpacityRemainInsideUsableBounds() {
        var presentation = PinnedImagePresentation(
            imageSize: CGSize(width: 800, height: 600),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )

        presentation.zoom(by: 100)
        XCTAssertEqual(presentation.scale, presentation.maximumScale)
        presentation.zoom(by: 0.0001)
        XCTAssertEqual(presentation.scale, presentation.minimumScale)
        presentation.setOpacity(0.05)
        XCTAssertEqual(presentation.opacity, PinnedImagePresentation.minimumOpacity)
        presentation.setOpacity(2)
        XCTAssertEqual(presentation.opacity, 1)
    }

    func testOpacityCycleAndScaleResetAreDeterministic() {
        var presentation = PinnedImagePresentation(
            imageSize: CGSize(width: 1_000, height: 500),
            maximumInitialSize: CGSize(width: 500, height: 400)
        )
        let fittedScale = presentation.fittedScale
        presentation.zoom(by: 1.2)
        presentation.resetScale()

        XCTAssertEqual(presentation.scale, fittedScale)
        presentation.cycleOpacity()
        XCTAssertEqual(presentation.opacity, 0.8)
        presentation.cycleOpacity()
        XCTAssertEqual(presentation.opacity, 0.6)
        presentation.cycleOpacity()
        XCTAssertEqual(presentation.opacity, 0.4)
        presentation.cycleOpacity()
        XCTAssertEqual(presentation.opacity, 1)
    }

    func testPinnedWindowRendersControlsAndExposesContextActions() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pinned-\(UUID().uuidString).screentrace", isDirectory: true)
        let imageURL = packageURL.appendingPathComponent("raw/screenshot.png")
        let trace = SavedTrace(
            packageURL: packageURL,
            rawAssetURL: imageURL,
            manifest: TraceManifest(
                kind: .screenshot,
                title: "测试贴图",
                dimensions: TraceDimensions(width: 400, height: 200),
                assets: [TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
        )
        let image = NSImage(size: CGSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemCyan.setFill()
            rect.fill()
            return true
        }
        let window = PinnedImageWindow(
            image: image,
            trace: trace,
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        window.setControlsVisible(true)
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        )
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertEqual(window.accessibilityLabel(), "贴图：测试贴图")
        XCTAssertGreaterThan(png?.count ?? 0, 1_000)
        XCTAssertEqual(contentView.menu?.items.map(\.title), [
            "复制图像", "", "放大", "缩小", "适合初始大小", "透明度", "锁定位置", "", "在 Finder 中显示项目", "关闭贴图"
        ])
        XCTAssertEqual(
            contentView.menu?.item(withTitle: "透明度")?.submenu?.items.map(\.title),
            ["100%", "80%", "60%", "40%"]
        )
    }
}
