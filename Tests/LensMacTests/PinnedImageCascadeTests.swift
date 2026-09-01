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

    private func centeredFrame() -> CGRect {
        CGRect(
            x: visible.midX - 260,
            y: visible.midY - 210,
            width: 520,
            height: 420
        )
    }
}
