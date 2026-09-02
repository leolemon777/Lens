import AppKit
import SwiftUI

@MainActor
final class RecordingControlWindowController {
    // The outer transparent inset is part of the SwiftUI surface. Keeping the
    // panel at the view's natural 110 pt height prevents the glass rim from
    // being compressed or clipped while still making the primary strip compact.
    static let panelSize = NSSize(width: 590, height: 110)

    private let model = RecordingControlModel()
    private let panel: LensGlassPanel
    private var levelTimer: Timer?
    private var levelProvider: (() -> (system: Double, microphone: Double))?
    private var eventCaptureHealthProvider: (() -> EventCaptureHealth)?
    private var capturePerformanceProvider: (() -> CapturePerformanceSnapshot?)?
    private var cachedEventCaptureHealth: EventCaptureHealth = .checking
    private var cachedCapturePerformance: CapturePerformanceSnapshot?
    private var lastEventHealthSampleUptime = -Double.infinity
    private var lastPerformanceSampleUptime = -Double.infinity
    private var hasPositionedPanel = false
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onDiscardAndRestart: (() -> Void)?
    var onHide: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }
    /// Exposed so `AppDelegate` can hand this panel off to Quick Access on a
    /// successful stop without either controller knowing the other's type.
    var currentWindow: NSWindow { panel }

    init() {
        panel = LensGlassPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            placement: .bottomCenter,
            nonactivating: true
        )
        configurePanel()
    }

    func begin(
        sourceTitle: String,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        capturesCamera: Bool,
        levelProvider: @escaping () -> (system: Double, microphone: Double),
        eventCaptureHealthProvider: @escaping () -> EventCaptureHealth,
        capturePerformanceProvider: @escaping () -> CapturePerformanceSnapshot?
    ) {
        model.reset(
            sourceTitle: sourceTitle,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            capturesCamera: capturesCamera
        )
        self.levelProvider = levelProvider
        self.eventCaptureHealthProvider = eventCaptureHealthProvider
        self.capturePerformanceProvider = capturePerformanceProvider
        cachedEventCaptureHealth = .checking
        cachedCapturePerformance = nil
        lastEventHealthSampleUptime = -Double.infinity
        lastPerformanceSampleUptime = -Double.infinity
        hasPositionedPanel = false
        startLevelUpdates()
        showExisting()
    }

    func showExisting() {
        startLevelUpdates()
        ensurePanelIsOnScreen()
        LensPanelPresenter.present(panel, from: .center)
        onVisibilityChange?(true)
    }

    func hide() {
        stopLevelUpdates()
        onVisibilityChange?(false)
        LensPanelPresenter.dismiss(panel)
    }

    /// Same cleanup as `hide()`, minus dismissing the panel: used when the
    /// caller is about to hand this panel off to another window via
    /// `LensPanelPresenter.handoff`, which owns the panel's own fade-out.
    /// Calling both would fight over the same window's animation.
    func prepareForHandoff() {
        stopLevelUpdates()
        onVisibilityChange?(false)
    }

    /// Ends live meters for this recording session. Disk monitoring lives on
    /// ``RecordingStorageMonitor`` so hiding the float cannot disable auto-stop.
    func endSession() {
        stopLevelUpdates()
        levelProvider = nil
        eventCaptureHealthProvider = nil
        capturePerformanceProvider = nil
        onVisibilityChange?(false)
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    func setPaused(_ paused: Bool) {
        model.setPaused(paused)
    }

    func setTransitioning(_ transitioning: Bool) {
        model.isTransitioning = transitioning
    }

    func beginFinalizing() {
        model.isFinalizing = true
        model.isTransitioning = true
    }

    func requestDiscardAndRestart() {
        guard !model.isTransitioning else { return }
        onDiscardAndRestart?()
    }

    func requestHide() {
        hide()
        onHide?()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets the AppKit level to `.floating`, so the
        // always-on recording affordance must assign its final level after it.
        panel.level = .statusBar
        panel.worksWhenModal = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.stop() }
        let root = RecordingControlView(
            model: model,
            onHide: { [weak self] in self?.requestHide() },
            onPauseToggle: { [weak self] in self?.onPauseToggle?() },
            onDiscardAndRestart: { [weak self] in self?.requestDiscardAndRestart() },
            onStop: { [weak self] in self?.stop() }
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    private func ensurePanelIsOnScreen() {
        if hasPositionedPanel,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 26
        ))
        hasPositionedPanel = true
    }

    private func startLevelUpdates() {
        guard levelTimer == nil, levelProvider != nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let levels = self.levelProvider?() else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastEventHealthSampleUptime >= 0.25 {
                    self.cachedEventCaptureHealth = self.eventCaptureHealthProvider?()
                        ?? .checking
                    self.lastEventHealthSampleUptime = now
                }
                if now - self.lastPerformanceSampleUptime >= 1 {
                    self.cachedCapturePerformance = self.capturePerformanceProvider?()
                    self.lastPerformanceSampleUptime = now
                }
                self.model.updateLiveStatus(
                    system: levels.system,
                    microphone: levels.microphone,
                    eventHealth: self.cachedEventCaptureHealth,
                    performance: self.cachedCapturePerformance
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func applyAvailableStorageBytes(_ availableBytes: Int64?) {
        let level = model.updateAvailableStorageBytes(availableBytes)
        if level == .critical {
            model.isTransitioning = true
        }
    }

    private func stop() {
        guard !model.isTransitioning, !model.isFinalizing else { return }
        beginFinalizing()
        onStop?()
    }
}
