import AppKit
import LensCore
import XCTest
@testable import LensMac

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

    func testScrollZoomsAndModifierScrollChangesOpacity() {
        var presentation = PinnedImagePresentation(
            imageSize: CGSize(width: 800, height: 600),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        let fitted = presentation.scale

        presentation.applyScroll(deltaY: 1, isPrecise: false, adjustsOpacity: false)
        XCTAssertGreaterThan(presentation.scale, fitted)

        presentation.applyScroll(deltaY: -20, isPrecise: false, adjustsOpacity: false)
        XCTAssertEqual(presentation.scale, presentation.minimumScale)

        presentation.setOpacity(1)
        presentation.applyScroll(deltaY: -1, isPrecise: false, adjustsOpacity: true)
        XCTAssertEqual(presentation.opacity, 0.92, accuracy: 0.0001)
        presentation.applyScroll(deltaY: -100, isPrecise: false, adjustsOpacity: true)
        XCTAssertEqual(presentation.opacity, PinnedImagePresentation.minimumOpacity)
    }

    func testPinchMagnificationZoomsWithinBounds() {
        var presentation = PinnedImagePresentation(
            imageSize: CGSize(width: 800, height: 600),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        let fitted = presentation.scale
        presentation.applyMagnification(0.25)
        XCTAssertGreaterThan(presentation.scale, fitted)
        presentation.applyMagnification(50)
        XCTAssertEqual(presentation.scale, presentation.maximumScale)
    }

    func testPinnedWindowScrollWheelZoomsUntilResetByMiddleClick() throws {
        let window = makePinnedWindow()
        let original = window.frame.size

        window.applyScroll(deltaY: 3, isPrecise: false, modifiers: [])
        XCTAssertGreaterThan(window.frame.width, original.width)

        window.applyScroll(deltaY: -1, isPrecise: false, modifiers: [.option])
        XCTAssertEqual(window.alphaValue, 0.92, accuracy: 0.02)

        window.resetSizeAndOpacity()
        XCTAssertEqual(window.frame.size.width, original.width, accuracy: 0.5)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
    }

    func testClickThroughIgnoresMouseAndShowsExitAffordance() throws {
        let window = makePinnedWindow()
        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertFalse(window.ignoresMouseEvents)

        let clickThroughItem = try XCTUnwrap(contentView.menu?.item(withTitle: "鼠标穿透"))
        XCTAssertTrue(
            NSApp.sendAction(
                try XCTUnwrap(clickThroughItem.action),
                to: clickThroughItem.target,
                from: clickThroughItem
            )
        )

        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertLessThanOrEqual(window.alphaValue, 0.6)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertEqual(clickThroughItem.state, .on)

        XCTAssertTrue(
            NSApp.sendAction(
                try XCTUnwrap(clickThroughItem.action),
                to: clickThroughItem.target,
                from: clickThroughItem
            )
        )
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
    }

    func testPinnedImageCanMoveByDraggingUntilPositionIsLocked() throws {
        let window = makePinnedWindow()
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let imageView = try XCTUnwrap(
            contentView.subviews.first { $0 is NSImageView },
            "The screenshot fills the pin; if that view swallows mouse-down, the window cannot move"
        )

        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(
            imageView.mouseDownCanMoveWindow,
            "NSImageView is an NSControl, so it must opt into window-background dragging"
        )
        XCTAssertTrue(contentView.mouseDownCanMoveWindow)
        XCTAssertTrue(contentView.acceptsFirstMouse(for: nil))

        let lockItem = try XCTUnwrap(contentView.menu?.item(withTitle: "锁定位置"))
        XCTAssertTrue(
            NSApp.sendAction(try XCTUnwrap(lockItem.action), to: lockItem.target, from: lockItem)
        )

        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertFalse(imageView.mouseDownCanMoveWindow)
        XCTAssertFalse(contentView.mouseDownCanMoveWindow)
    }

    func testPinnedWindowRendersControlsAndExposesContextActions() throws {
        let window = makePinnedWindow()
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
            "复制图像", "", "放大", "缩小", "适合初始大小", "透明度", "锁定位置", "鼠标穿透", "", "在 Finder 中显示项目", "关闭贴图"
        ])
        XCTAssertEqual(
            contentView.menu?.item(withTitle: "透明度")?.submenu?.items.map(\.title),
            ["100%", "80%", "60%", "40%"]
        )
        XCTAssertTrue(PinnedImageWindow.shouldBeginFileDrag(.command))
        XCTAssertTrue(PinnedImageWindow.shouldBeginFileDrag(.option))
        XCTAssertFalse(PinnedImageWindow.shouldBeginFileDrag([]))
        XCTAssertFalse(
            PinnedImageWindow.shouldBeginFileDrag(.control),
            "Control+click is the macOS context menu and must not steal the file drag"
        )
        XCTAssertNotNil(window.fileURLForDragging())
    }

    func testClipboardPinOmitsFinderRevealAndStillExportsAPNG() throws {
        let image = NSImage(size: CGSize(width: 80, height: 50), flipped: false) { rect in
            NSColor.systemMint.setFill()
            rect.fill()
            return true
        }
        let window = PinnedImageWindow(
            image: image,
            source: .clipboard(title: "API_TOKEN=demo"),
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertEqual(window.accessibilityLabel(), "贴图：API_TOKEN=demo")
        XCTAssertNil(contentView.menu?.item(withTitle: "在 Finder 中显示项目"))
        let dragURL = try XCTUnwrap(window.fileURLForDragging())
        XCTAssertEqual(dragURL.pathExtension.lowercased(), "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dragURL.path))
        window.closePinnedImage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dragURL.path))
    }

    func testHidingAllPinsKeepsThemUntilShownOrClosed() {
        let controller = PinnedImageWindowController()
        let first = makeLensAndImage()
        let second = makeLensAndImage()
        controller.pin(lens: first.lens, image: first.image)
        controller.pin(lens: second.lens, image: second.image)
        XCTAssertTrue(controller.hasPins)
        XCTAssertFalse(controller.areHidden)

        controller.hideAll()
        XCTAssertTrue(controller.areHidden)
        controller.showAll()
        XCTAssertFalse(controller.areHidden)

        controller.hideAll()
        controller.pin(lens: makeLensAndImage().lens, image: makeLensAndImage().image)
        XCTAssertFalse(controller.areHidden, "A new pin should bring the set back on screen")

        controller.closeAll()
        XCTAssertFalse(controller.hasPins)
        XCTAssertFalse(controller.areHidden)
    }

    private func makePinnedWindow() -> PinnedImageWindow {
        let fixture = makeLensAndImage()
        return PinnedImageWindow(
            image: fixture.image,
            lens: fixture.lens,
            maximumInitialSize: CGSize(width: 520, height: 420)
        )
    }

    private func makeLensAndImage() -> (lens: SavedLens, image: NSImage) {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pinned-\(UUID().uuidString).lens", isDirectory: true)
        let imageURL = packageURL.appendingPathComponent("raw/screenshot.png")
        let lens = SavedLens(
            packageURL: packageURL,
            rawAssetURL: imageURL,
            manifest: LensManifest(
                kind: .screenshot,
                title: "测试贴图",
                dimensions: LensDimensions(width: 400, height: 200),
                assets: [LensAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
        )
        let image = NSImage(size: CGSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemCyan.setFill()
            rect.fill()
            return true
        }
        return (lens, image)
    }
}
