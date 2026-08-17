import AppKit
import SwiftUI

@MainActor
final class RecordingControlWindowController {
    // The outer transparent inset is part of the SwiftUI surface. Keeping the
    // panel at the view's natural 110 pt height prevents the glass rim from
    // being compressed or clipped while still making the primary strip compact.
    static let panelSize = NSSize(width: 590, height: 110)

    private let model = RecordingControlModel()
    private let panel: RecordingPanel
    private var levelTimer: Timer?
    private var storageTimer: Timer?
    private var levelProvider: (() -> (system: Double, microphone: Double))?
    private var eventCaptureHealthProvider: (() -> EventCaptureHealth)?
    private var capturePerformanceProvider: (() -> CapturePerformanceSnapshot?)?
    private var cachedEventCaptureHealth: EventCaptureHealth = .checking
    private var cachedCapturePerformance: CapturePerformanceSnapshot?
    private var lastEventHealthSampleUptime = -Double.infinity
    private var lastPerformanceSampleUptime = -Double.infinity
    private var storageURL: URL?
    private var didReportCriticalStorage = false
    private var hasPositionedPanel = false
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onDiscardAndRestart: (() -> Void)?
    var onHide: (() -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    var onCriticalStorage: ((Int64?) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }

    init() {
        panel = RecordingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    func begin(
        sourceTitle: String,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        capturesCamera: Bool,
        storageURL: URL,
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
        self.storageURL = storageURL
        didReportCriticalStorage = false
        hasPositionedPanel = false
        startLevelUpdates()
        startStorageUpdates()
        showExisting()
    }

    func showExisting() {
        startLevelUpdates()
        startStorageUpdates()
        ensurePanelIsOnScreen()
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        storageTimer?.invalidate()
        storageTimer = nil
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    func setPaused(_ paused: Bool) {
        model.setPaused(paused)
    }

    func setTransitioning(_ transitioning: Bool) {
        model.isTransitioning = transitioning
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

    private func startStorageUpdates() {
        guard storageTimer == nil, storageURL != nil else { return }
        updateStorageStatus()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStorageStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        storageTimer = timer
    }

    private func updateStorageStatus() {
        let availableBytes = storageURL.flatMap(Self.availableStorageBytes(at:))
        applyAvailableStorageBytes(availableBytes)
    }

    func applyAvailableStorageBytes(_ availableBytes: Int64?) {
        let level = model.updateAvailableStorageBytes(availableBytes)
        guard level == .critical, !didReportCriticalStorage else { return }
        didReportCriticalStorage = true
        model.isTransitioning = true
        onCriticalStorage?(availableBytes)
    }

    nonisolated static func availableStorageBytes(at requestedURL: URL) -> Int64? {
        var probeURL = requestedURL.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probeURL.path),
              probeURL.pathComponents.count > 1 {
            probeURL.deleteLastPathComponent()
        }
        do {
            let values = try probeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            let importantCapacity = values.volumeAvailableCapacityForImportantUsage
            let immediateCapacity = values.volumeAvailableCapacity.map(Int64.init)
            switch (importantCapacity, immediateCapacity) {
            case let (important?, immediate?):
                return max(min(important, immediate), 0)
            case let (important?, nil):
                return max(important, 0)
            case let (nil, immediate?):
                return max(immediate, 0)
            case (nil, nil):
                return nil
            }
        } catch {
            return nil
        }
    }

    private func stop() {
        guard !model.isTransitioning else { return }
        hide()
        onStop?()
    }
}

private final class RecordingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
