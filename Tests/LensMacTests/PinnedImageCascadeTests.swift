import AppKit
import XCTest
@testable import LensMac

/// Pinned images cascade from the centred position so stacked pins stay
/// individually grabbable. Before this was bounded, the offset grew without
/// limit and a long pinning session marched windows off the bottom-right
/// corner, where they could be neither seen nor closed.
@MainActor
final class PinnedImageCascadeTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testFirstPinStaysExactlyWhereCenteringPutIt() {
        let centered = centeredFrame()
        let origin = PinnedImageWindowController.cascadedOrigin(
            centeredFrame: centered,
            pinIndex: 0,
            visibleFrame: visible
        )
        XCTAssertEqual(origin, centered.origin)
    }

    func testEachOfTheFirstFewPinsIsOffsetSoNoneIsCompletelyHidden() {
        let centered = centeredFrame()
        let origins = (0..<4).map { index in
            PinnedImageWindowController.cascadedOrigin(
                centeredFrame: centered,
                pinIndex: index,
                visibleFrame: visible
            )
        }
        XCTAssertEqual(Set(origins.map(\.x)).count, origins.count)
        XCTAssertEqual(Set(origins.map(\.y)).count, origins.count)
    }

    func testEveryPinInALongSessionStaysFullyOnScreen() {
        let centered = centeredFrame()
        for index in 0..<40 {
            let origin = PinnedImageWindowController.cascadedOrigin(
                centeredFrame: centered,
                pinIndex: index,
                visibleFrame: visible
            )
            let frame = CGRect(origin: origin, size: centered.size)
            XCTAssertTrue(
                visible.contains(frame),
                "pin #\(index) landed at \(frame), outside the visible area \(visible)"
            )
        }
    }

    func testCascadeWrapsInsteadOfGrowingWithoutBound() {
        let centered = centeredFrame()
        let origins = (0..<40).map { index in
            PinnedImageWindowController.cascadedOrigin(
                centeredFrame: centered,
                pinIndex: index,
                visibleFrame: visible
            )
        }
        XCTAssertLessThan(
            Set(origins.map(\.x)).count,
            origins.count,
            "a bounded cascade must reuse positions rather than drift forever"
        )
    }

    func testAWindowLargerThanTheScreenIsClampedRatherThanPushedFurtherOut() {
        let oversized = CGRect(x: -200, y: -150, width: 2_000, height: 1_400)
        let origin = PinnedImageWindowController.cascadedOrigin(
            centeredFrame: oversized,
            pinIndex: 3,
            visibleFrame: visible
        )
        XCTAssertEqual(origin.x, visible.minX)
        XCTAssertEqual(origin.y, visible.minY)
    }

    func testMissingScreenFallsBackToTheOldUnclampedCascade() {
        let centered = centeredFrame()
        let origin = PinnedImageWindowController.cascadedOrigin(
            centeredFrame: centered,
            pinIndex: 2,
            visibleFrame: nil
        )
        XCTAssertEqual(origin.x, centered.minX + 56)
        XCTAssertEqual(origin.y, centered.minY - 56)
    }

    /// A pin is a reference kept beside your work. At the previous 520×420 cap
    /// one pin blanketed whatever sat under it, and several buried each other.
    func testAPinStartsSmallEnoughToSitBesideTheWorkItReferences() {
        let cap = CGSize(width: 340, height: 260)
        let wide = PinnedImagePresentation(
            imageSize: CGSize(width: 2_560, height: 1_440),
            maximumInitialSize: cap
        )
        XCTAssertLessThanOrEqual(wide.windowSize.width, cap.width)
        XCTAssertLessThanOrEqual(wide.windowSize.height, cap.height)

        let tall = PinnedImagePresentation(
            imageSize: CGSize(width: 600, height: 2_000),
            maximumInitialSize: cap
        )
        XCTAssertLessThanOrEqual(tall.windowSize.width, cap.width)
        XCTAssertLessThanOrEqual(tall.windowSize.height, cap.height)
    }

    /// Shrinking the default must not cost the ability to inspect a pin: the
    /// zoom range is relative to the fitted scale, so it scales down with it.
    func testASmallerDefaultStillZoomsUpToTheSameRelativeRange() {
        var pin = PinnedImagePresentation(
            imageSize: CGSize(width: 2_560, height: 1_440),
            maximumInitialSize: CGSize(width: 340, height: 260)
        )
        let fitted = pin.windowSize.width
        pin.zoom(by: 8)
        XCTAssertGreaterThan(
            pin.windowSize.width,
            fitted * 3,
            "a pin must still zoom well past its fitted size"
        )
    }

    /// A capture already smaller than the cap is shown at its true size rather
    /// than being blown up.
    func testASmallCaptureIsNotUpscaledToFillTheCap() {
        let small = PinnedImagePresentation(
            imageSize: CGSize(width: 160, height: 90),
            maximumInitialSize: CGSize(width: 340, height: 260)
        )
        XCTAssertEqual(small.windowSize.width, 160)
        XCTAssertEqual(small.windowSize.height, 90)
    }

    private func centeredFrame() -> CGRect {
        CGRect(
            x: visible.midX - 260,
            y: visible.midY - 210,
            width: 520,
            height: 420
        )
    }
}
