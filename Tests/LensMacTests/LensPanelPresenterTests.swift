import AppKit
import XCTest
@testable import LensMac

@MainActor
final class LensPanelPresenterTests: XCTestCase {
    override func tearDown() {
        // This is process-global state; never let one test's forced value
        // bleed into another.
        LensPanelPresenter.reduceMotionOverride = nil
        super.tearDown()
    }

    /// Off-screen so the animation never becomes visible on the machine
    /// actually running the test, matching the existing snapshot-window
    /// convention (see ActionCenterViewTests).
    private func makeWindow(originX: CGFloat = -4_000) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: -4_000, width: 320, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        return panel
    }

    func testReduceMotionPresentSkipsAnimationAndJumpsToFinalState() {
        LensPanelPresenter.reduceMotionOverride = true
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let finalFrame = window.frame

        LensPanelPresenter.present(window, from: .bottomTrailing)

        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame, finalFrame)
    }

    func testReduceMotionDismissOrdersOutImmediatelyAndCallsCompletionOnce() {
        LensPanelPresenter.reduceMotionOverride = true
        let window = makeWindow()
        LensPanelPresenter.present(window, from: .center)
        XCTAssertTrue(window.isVisible)

        var completionCount = 0
        LensPanelPresenter.dismiss(window) { completionCount += 1 }

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(completionCount, 1)
    }

    func testDismissingAnAlreadyHiddenWindowStillCallsCompletionExactlyOnce() {
        LensPanelPresenter.reduceMotionOverride = true
        let window = makeWindow()
        XCTAssertFalse(window.isVisible)

        var completionCount = 0
        LensPanelPresenter.dismiss(window) { completionCount += 1 }

        XCTAssertEqual(completionCount, 1)
    }

    /// The animated path must still reach the correct terminal state: no
    /// leftover partial alpha/frame once Core Animation's completion block
    /// has actually run.
    func testAnimatedPresentReachesFullOpacityAndFinalFrame() {
        LensPanelPresenter.reduceMotionOverride = false
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.setFrameOrigin(NSPoint(x: -4_000, y: -4_000))
        let finalFrame = window.frame

        LensPanelPresenter.present(window, from: .top)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(window.frame, finalFrame)
    }

    /// Regression guard for the reuse case Quick Access depends on: a second
    /// capture arriving while the previous card is still fading out must not
    /// be hidden by the first dismiss's now-stale completion.
    func testPresentDuringInFlightDismissLeavesWindowVisible() {
        LensPanelPresenter.reduceMotionOverride = false
        let window = makeWindow()
        defer { window.orderOut(nil) }
        LensPanelPresenter.present(window, from: .bottomTrailing)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        XCTAssertTrue(window.isVisible)

        var dismissCompletions = 0
        LensPanelPresenter.dismiss(window) { dismissCompletions += 1 }
        // Re-present before the 0.13s dismiss animation's completion block
        // has had a chance to run.
        LensPanelPresenter.present(window, from: .bottomTrailing)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

        XCTAssertEqual(dismissCompletions, 1, "the dismiss completion itself still fires")
        XCTAssertTrue(
            window.isVisible,
            "a present() that arrives mid-dismiss must win; the superseded " +
            "dismiss must not order the window out from under it"
        )
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testReduceMotionHandoffDegradesToDirectSwitch() {
        LensPanelPresenter.reduceMotionOverride = true
        let outgoing = makeWindow(originX: -4_000)
        let incoming = makeWindow(originX: -3_000)
        defer {
            outgoing.orderOut(nil)
            incoming.orderOut(nil)
        }
        LensPanelPresenter.present(outgoing, from: .center)
        XCTAssertTrue(outgoing.isVisible)

        LensPanelPresenter.handoff(from: outgoing, to: incoming)

        XCTAssertFalse(outgoing.isVisible)
        XCTAssertTrue(incoming.isVisible)
        XCTAssertEqual(incoming.alphaValue, 1)
    }

    func testAnimatedHandoffEndsWithOutgoingHiddenAndIncomingAtFullOpacity() {
        LensPanelPresenter.reduceMotionOverride = false
        let outgoing = makeWindow(originX: -4_000)
        let incoming = makeWindow(originX: -3_000)
        defer {
            outgoing.orderOut(nil)
            incoming.orderOut(nil)
        }
        LensPanelPresenter.present(outgoing, from: .center)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        XCTAssertTrue(outgoing.isVisible)
        let incomingFinalFrame = incoming.frame

        LensPanelPresenter.handoff(from: outgoing, to: incoming)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertFalse(
            outgoing.isVisible,
            "the outgoing window must end up ordered out, not stuck visible forever"
        )
        XCTAssertTrue(incoming.isVisible)
        XCTAssertEqual(incoming.alphaValue, 1)
        XCTAssertEqual(incoming.frame, incomingFinalFrame)
    }

    func testHandoffFromAnAlreadyHiddenWindowDegradesToPlainPresent() {
        LensPanelPresenter.reduceMotionOverride = true
        let outgoing = makeWindow(originX: -4_000)
        let incoming = makeWindow(originX: -3_000)
        defer { incoming.orderOut(nil) }
        XCTAssertFalse(outgoing.isVisible)

        LensPanelPresenter.handoff(from: outgoing, to: incoming)

        XCTAssertTrue(incoming.isVisible)
    }

    /// Mirrors `testPresentDuringInFlightDismissLeavesWindowVisible`: if the
    /// outgoing window is re-presented by some other caller while a
    /// handoff's fade-out is still in flight, the handoff's completion must
    /// not order it back out from under that newer present. This is the
    /// concrete failure mode "both panels must never end up in the wrong
    /// visibility state" actually guards against.
    func testRePresentingOutgoingDuringHandoffLeavesItVisible() {
        LensPanelPresenter.reduceMotionOverride = false
        let outgoing = makeWindow(originX: -4_000)
        let incoming = makeWindow(originX: -3_000)
        defer {
            outgoing.orderOut(nil)
            incoming.orderOut(nil)
        }
        LensPanelPresenter.present(outgoing, from: .center)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        XCTAssertTrue(outgoing.isVisible)

        LensPanelPresenter.handoff(from: outgoing, to: incoming)
        // Re-present before the handoff's ~0.18s completion has run.
        LensPanelPresenter.present(outgoing, from: .center)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertTrue(
            outgoing.isVisible,
            "a present() that arrives mid-handoff must win over the superseded handoff's orderOut"
        )
    }

    func testConsecutivePresentsOnTheSameWindowKeepItVisibleWithNoCrash() {
        LensPanelPresenter.reduceMotionOverride = true
        let window = makeWindow()
        defer { window.orderOut(nil) }

        LensPanelPresenter.present(window, from: .center)
        LensPanelPresenter.present(window, from: .center)
        LensPanelPresenter.present(window, from: .center)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
    }
}
