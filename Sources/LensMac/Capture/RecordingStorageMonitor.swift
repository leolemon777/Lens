import Foundation

/// Disk-space watchdog bound to the recording session, not the control float.
/// Hiding the HUD must not disable the 1 GB auto-stop.
@MainActor
final class RecordingStorageMonitor {
    var onAvailableBytes: ((Int64?) -> Void)?
    var onCriticalStorage: ((Int64?) -> Void)?

    private var storageURL: URL?
    private var storageTimer: Timer?
    private var didReportCriticalStorage = false

    var isMonitoring: Bool { storageTimer != nil }

    func start(storageURL: URL) {
        stop()
        self.storageURL = storageURL
        didReportCriticalStorage = false
        update()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        storageTimer = timer
    }

    func stop() {
        storageTimer?.invalidate()
        storageTimer = nil
        storageURL = nil
        didReportCriticalStorage = false
    }

    func applyAvailableStorageBytes(_ availableBytes: Int64?) {
        onAvailableBytes?(availableBytes)
        let level = RecordingControlModel.storageLevel(for: availableBytes)
        guard level == .critical, !didReportCriticalStorage else { return }
        didReportCriticalStorage = true
        onCriticalStorage?(availableBytes)
    }

    private func update() {
        let availableBytes = storageURL.flatMap(Self.availableStorageBytes(at:))
        applyAvailableStorageBytes(availableBytes)
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
}
