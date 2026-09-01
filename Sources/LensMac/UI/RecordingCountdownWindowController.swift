import AppKit
import LensCore
import SwiftUI

/// Shows the 3-2-1 countdown before a recording actually starts, bordering
/// the exact capture bounds so the user can both confirm the region and
/// switch to their target window/app during the delay. Bypasses
/// `LensPanelPresenter` like `CaptureOverlayWindow` does: this is a
/// full-screen instant overlay, not a small anchored panel, and scaling a
/// screen-sized window in/out would read as a glitch rather than polish.
@MainActor
final class RecordingCountdownWindowController {
    /// Overrides the real 1-second-per-step pacing so tests don't block for
    /// three real seconds; `nil` means the real cadence.
    static var stepDurationOverride: Duration?

    private var window: NSWindow?
    private var activeTask: Task<Void, Never>?
    private var escMonitors: [Any] = []
    private let model = RecordingCountdownModel()

    /// Runs the countdown and resolves `true` once the caller may start
    /// recording. Resolves `true` immediately without showing anything when
    /// `isEnabled` is `false` (the user turned the countdown off in
    /// settings). Resolves `false` if `cancel()` runs first (wired to Esc),
    /// in which case the caller must not create a project package.
    func run(source: RecordingCaptureSource, isEnabled: Bool) async -> Bool {
        guard isEnabled else { return true }
        guard let screen = Self.screen(for: source) else { return true }

        let window = Self.makeWindow(on: screen)
        self.window = window
        model.reset()
        window.contentView = NSHostingView(
            rootView: RecordingCountdownView(
                model: model,
                borderRect: Self.localBorderRect(
                    captureBounds: source.captureBounds,
                    screenAppKitFrame: screen.frame,
                    mainHeight: NSScreen.screens.first?.frame.height ?? 0
                )
            )
        )
        window.orderFrontRegardless()
        installEscMonitors()
        defer {
            removeEscMonitors()
            window.orderOut(nil)
            self.window = nil
        }

        let stepDuration = Self.stepDurationOverride ?? .seconds(1)
        let task = Task { @MainActor [model] in
            for value in [3, 2, 1] {
                guard !Task.isCancelled else { return }
                model.count = value
                try? await Task.sleep(for: stepDuration)
            }
        }
        activeTask = task
        await task.value
        activeTask = nil
        return !task.isCancelled
    }

    /// Cancels an in-flight countdown. Wired to Esc; harmless once the
    /// countdown has already resolved.
    func cancel() {
        activeTask?.cancel()
    }

    private func installEscMonitors() {
        // Global, because the whole point of the delay is letting the user
        // activate a different app before recording starts — Esc must still
        // cancel even though Lens is no longer frontmost by then.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.cancel()
        }) {
            escMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }) {
            escMonitors.append(monitor)
        }
    }

    private func removeEscMonitors() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors.removeAll()
    }

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return window
    }

    private static func screen(for source: RecordingCaptureSource) -> NSScreen? {
        if let displayID = source.displayID,
           let matched = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return matched
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.max { lhs, rhs in
            overlapArea(lhs, source.captureBounds, mainHeight: mainHeight)
                < overlapArea(rhs, source.captureBounds, mainHeight: mainHeight)
        }
    }

    private static func overlapArea(
        _ screen: NSScreen,
        _ quartzTarget: CGRect,
        mainHeight: CGFloat
    ) -> CGFloat {
        let intersection = quartzRect(forAppKitFrame: screen.frame, mainHeight: mainHeight)
            .intersection(quartzTarget)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// AppKit screen frames are bottom-left origin, Y-up; Quartz's global
    /// display space (what `CGDisplayBounds`/`captureBounds` use) is
    /// top-left origin, Y-down, relative to the main display. `mainHeight`
    /// is that main display's point height — `NSScreen.screens.first`'s
    /// frame height in production, injected here so the pure math is
    /// testable without a real multi-display setup.
    static func quartzRect(forAppKitFrame frame: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// `captureBounds` is Quartz-space (top-left origin, relative to the
    /// main display) — the same handedness SwiftUI's local coordinate space
    /// uses, so this only needs a translation to the target window's own
    /// top-left corner, never a Y-flip.
    static func localBorderRect(
        captureBounds: CGRect,
        screenAppKitFrame: CGRect,
        mainHeight: CGFloat
    ) -> CGRect {
        let screenOrigin = quartzRect(forAppKitFrame: screenAppKitFrame, mainHeight: mainHeight).origin
        return CGRect(
            x: captureBounds.minX - screenOrigin.x,
            y: captureBounds.minY - screenOrigin.y,
            width: captureBounds.width,
            height: captureBounds.height
        )
    }
}

@MainActor
private final class RecordingCountdownModel: ObservableObject {
    @Published var count = 3
    func reset() { count = 3 }
}

private struct RecordingCountdownView: View {
    @ObservedObject var model: RecordingCountdownModel
    let borderRect: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LensGlassMetrics.tileCornerRadius, style: .continuous)
                .stroke(LensGlassPalette.recording, lineWidth: 3)
                .frame(width: borderRect.width, height: borderRect.height)
                .position(x: borderRect.midX, y: borderRect.midY)

            Text("\(model.count)")
                .font(.system(size: 120, weight: .bold, design: .rounded)) // lens-token-exempt: 全屏倒计时数字，一次性巨型展示态，不属于常规文字层级
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 16)
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .position(x: borderRect.midX, y: borderRect.midY)
                .accessibilityLabel("录制倒计时")
                .accessibilityValue("\(model.count)")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.count)
        .ignoresSafeArea()
    }
}
