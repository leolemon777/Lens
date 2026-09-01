import AppKit

/// Shared show/hide transition for Lens's transient glass panels (Toast,
/// Quick Access, the action center, recording/scrolling-capture control
/// bars, OCR results, recording setup, permission center, onboarding).
///
/// Every one of those controllers used to call `orderFrontRegardless()` /
/// `orderOut(nil)` directly, which cuts the panel in and out with no
/// transition. This type owns a single short fade + pop-scale transition so
/// every glass surface in the app moves the same way.
///
/// Deliberately excluded: `LensLibraryWindowController`,
/// `VideoEditorWindowController` and `ScreenshotAnnotationEditorWindowController`
/// are standard resizable document windows and keep default AppKit
/// show/hide behavior. `PinnedImageWindowController` owns its own
/// click-through badge and hover-toolbar fades. `CaptureOverlayWindow` must
/// never animate in — a screenshot selection overlay has to appear
/// instantly or it makes the capture itself feel slow.
@MainActor
enum LensPanelPresenter {
    /// Where the panel visually "grows from" on present and "shrinks back
    /// toward" on dismiss, expressed as a unit point within its own frame
    /// (0,0 = bottom-left, 1,1 = top-right — AppKit's native screen space).
    enum Anchor {
        case center
        case top
        case bottomTrailing

        fileprivate var unitPoint: CGPoint {
            switch self {
            case .center: CGPoint(x: 0.5, y: 0.5)
            case .top: CGPoint(x: 0.5, y: 1)
            case .bottomTrailing: CGPoint(x: 1, y: 0)
            }
        }
    }

    private static let presentDuration: TimeInterval = 0.18
    private static let dismissDuration: TimeInterval = 0.13
    private static let presentScale: CGFloat = 0.96
    private static let dismissScale: CGFloat = 0.97
    private static let timingFunction = CAMediaTimingFunction(
        controlPoints: 0.2, 0.9, 0.25, 1
    )

    /// Tracks the most recent call per window so a dismiss's completion
    /// block can detect that a newer `present` superseded it and skip the
    /// `orderOut` that would otherwise hide the panel it just reshowed.
    private static var generationsByWindow: [ObjectIdentifier: Int] = [:]

    /// Overridable for tests; production always reads the live system
    /// signal, the same one SwiftUI's `accessibilityReduceMotion`
    /// environment value is backed by.
    static var reduceMotionOverride: Bool?

    private static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shows `window` with a short fade-and-pop toward its current frame.
    /// Callers must position the window (origin and size) *before* calling
    /// this — `present` treats `window.frame` as the destination and
    /// animates from a scaled-down variant anchored at `anchor`.
    ///
    /// Motion never gates visibility: the window is ordered front
    /// immediately, and only its alpha/frame animate afterward. Reduce
    /// Motion skips the scale and jumps straight to the final state.
    static func present(_ window: NSWindow, from anchor: Anchor = .center) {
        let identifier = ObjectIdentifier(window)
        generationsByWindow[identifier, default: 0] += 1
        let finalFrame = window.frame

        guard !reduceMotion else {
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }

        window.alphaValue = 0
        window.setFrame(
            scaledFrame(around: finalFrame, anchor: anchor, scale: presentScale),
            display: false
        )
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = presentDuration
            context.timingFunction = timingFunction
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    /// Hides `window` with a short fade-and-shrink, then orders it out.
    /// `completion` always runs exactly once, animated or not — including
    /// when `window` was already hidden. If `present` is called again for
    /// the same window before this finishes, the pending `orderOut` is
    /// skipped so the reshown panel is not immediately hidden underneath it.
    static func dismiss(_ window: NSWindow, completion: (() -> Void)? = nil) {
        guard window.isVisible else {
            completion?()
            return
        }

        let identifier = ObjectIdentifier(window)
        let generation = generationsByWindow[identifier, default: 0] + 1
        generationsByWindow[identifier] = generation

        guard !reduceMotion else {
            window.orderOut(nil)
            completion?()
            return
        }

        let currentFrame = window.frame
        // `completionHandler:` is a `@Sendable` closure in the AppKit
        // overlay, so the MainActor-isolated `completion` value can't be
        // captured into it directly under strict concurrency checking.
        // AppKit only ever invokes NSAnimationContext completion blocks
        // back on the main thread, so asserting that here (rather than
        // hopping through `Task`, which would delay the callback by an
        // extra run-loop turn) is both correct and precise.
        nonisolated(unsafe) let completion = completion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = dismissDuration
            context.timingFunction = timingFunction
            window.animator().alphaValue = 0
            window.animator().setFrame(
                scaledFrame(around: currentFrame, anchor: .center, scale: dismissScale),
                display: true
            )
        }, completionHandler: {
            MainActor.assumeIsolated {
                if generationsByWindow[identifier] == generation {
                    window.orderOut(nil)
                }
                completion?()
            }
        })
    }

    /// Crossfades `outgoing` out while `incoming` fades in on one shared
    /// timing curve, so the transition reads as one glass island handing
    /// off to the next rather than a hide followed by a separate show.
    /// Neither controller needs a reference to the other — callers pass
    /// both windows directly. `incoming` must already be positioned and
    /// sized by its own caller, exactly like `present`; `handoff` never
    /// repositions it to match `outgoing`; each surface keeps its own
    /// normal placement; the shared start/end timing is what reads as
    /// continuous, not shared geometry.
    static func handoff(from outgoing: NSWindow, to incoming: NSWindow, anchor: Anchor = .center) {
        guard outgoing.isVisible else {
            present(incoming, from: anchor)
            return
        }

        let outgoingIdentifier = ObjectIdentifier(outgoing)
        let outgoingGeneration = generationsByWindow[outgoingIdentifier, default: 0] + 1
        generationsByWindow[outgoingIdentifier] = outgoingGeneration
        generationsByWindow[ObjectIdentifier(incoming), default: 0] += 1

        let outgoingFrame = outgoing.frame
        let incomingFinalFrame = incoming.frame

        guard !reduceMotion else {
            outgoing.alphaValue = 0
            outgoing.orderOut(nil)
            incoming.alphaValue = 1
            incoming.orderFrontRegardless()
            return
        }

        incoming.alphaValue = 0
        incoming.setFrame(
            scaledFrame(around: incomingFinalFrame, anchor: anchor, scale: presentScale),
            display: false
        )
        incoming.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = presentDuration
            context.timingFunction = timingFunction
            outgoing.animator().alphaValue = 0
            outgoing.animator().setFrame(
                scaledFrame(around: outgoingFrame, anchor: .center, scale: dismissScale),
                display: true
            )
            incoming.animator().alphaValue = 1
            incoming.animator().setFrame(incomingFinalFrame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                if generationsByWindow[outgoingIdentifier] == outgoingGeneration {
                    outgoing.orderOut(nil)
                }
            }
        })
    }

    private static func scaledFrame(
        around finalFrame: NSRect,
        anchor: Anchor,
        scale: CGFloat
    ) -> NSRect {
        let unit = anchor.unitPoint
        let anchorPoint = CGPoint(
            x: finalFrame.origin.x + finalFrame.width * unit.x,
            y: finalFrame.origin.y + finalFrame.height * unit.y
        )
        let width = finalFrame.width * scale
        let height = finalFrame.height * scale
        return NSRect(
            x: anchorPoint.x - width * unit.x,
            y: anchorPoint.y - height * unit.y,
            width: width,
            height: height
        )
    }
}
