import AppKit
import SwiftUI

@MainActor
final class RecordingControlWindowController {
    private let model = RecordingControlModel()
    private let panel: RecordingPanel
    private var levelTimer: Timer?
    private var storageTimer: Timer?
    private var levelProvider: (() -> (system: Double, microphone: Double))?
    private var storageURL: URL?
    private var didReportCriticalStorage = false
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
    var onDiscardAndRestart: (() -> Void)?
    var onCriticalStorage: ((Int64?) -> Void)?

    init() {
        panel = RecordingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 98),
            styleMask: [.borderless, .fullSizeContentView],
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
        levelProvider: @escaping () -> (system: Double, microphone: Double)
    ) {
        model.reset(
            sourceTitle: sourceTitle,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            capturesCamera: capturesCamera
        )
        self.levelProvider = levelProvider
        self.storageURL = storageURL
        didReportCriticalStorage = false
        startLevelUpdates()
        startStorageUpdates()
        showExisting()
    }

    func showExisting() {
        startLevelUpdates()
        startStorageUpdates()
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        storageTimer?.invalidate()
        storageTimer = nil
        panel.orderOut(nil)
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

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.stop() }
        let root = RecordingControlView(
            model: model,
            onPauseToggle: { [weak self] in self?.onPauseToggle?() },
            onDiscardAndRestart: { [weak self] in self?.requestDiscardAndRestart() },
            onStop: { [weak self] in self?.stop() }
        )
        panel.contentView = NSHostingView(rootView: root)
    }

    private func positionPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 26
        ))
    }

    private func startLevelUpdates() {
        guard levelTimer == nil, levelProvider != nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let levels = self.levelProvider?() else { return }
                self.model.updateAudioLevels(
                    system: levels.system,
                    microphone: levels.microphone
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
