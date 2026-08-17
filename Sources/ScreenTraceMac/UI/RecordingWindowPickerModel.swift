import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
import ScreenTraceCore

struct RecordingWindowOption: Identifiable {
    let id: CGWindowID
    let source: RecordingCaptureSource
    let applicationName: String
    let windowTitle: String
    let appIcon: NSImage?
    var thumbnail: NSImage?

    init(
        id: CGWindowID,
        source: RecordingCaptureSource,
        applicationName: String,
        windowTitle: String,
        appIcon: NSImage? = nil,
        thumbnail: NSImage? = nil
    ) {
        self.id = id
        self.source = source
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.appIcon = appIcon
        self.thumbnail = thumbnail
    }
}

@MainActor
final class RecordingWindowPickerModel: ObservableObject {
    @Published private(set) var options: [RecordingWindowOption]
    @Published private(set) var selectedWindowID: CGWindowID?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let loadsLiveWindows: Bool
    private let captureService = ScreenCaptureService()
    private var refreshGeneration = 0

    init() {
        options = []
        selectedWindowID = nil
        loadsLiveWindows = true
    }

    init(
        previewOptions: [RecordingWindowOption],
        selectedWindowID: CGWindowID? = nil
    ) {
        options = previewOptions
        self.selectedWindowID = selectedWindowID
        loadsLiveWindows = false
    }

    var selectedOption: RecordingWindowOption? {
        guard let selectedWindowID else { return nil }
        return options.first { $0.id == selectedWindowID }
    }

    var selectedSource: RecordingCaptureSource? {
        selectedOption?.source
    }

    func selectWindow(id: CGWindowID) {
        guard options.contains(where: { $0.id == id }) else { return }
        selectedWindowID = id
    }

    func refresh() async {
        guard loadsLiveWindows else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let previousSelection = selectedWindowID
        isRefreshing = true
        errorMessage = nil

        do {
            let targets = try await captureService.availableWindowTargets(
                excludingProcessID: ProcessInfo.processInfo.processIdentifier,
                excludingBundleIdentifier: Bundle.main.bundleIdentifier
            )
            guard generation == refreshGeneration, !Task.isCancelled else { return }

            let refreshedOptions = targets.map { target in
                let processID = target.window.owningApplication?.processID
                let icon = processID.flatMap {
                    NSRunningApplication(processIdentifier: $0)?.icon
                }
                return RecordingWindowOption(
                    id: target.candidate.id,
                    source: CaptureGeometry.windowRecordingSource(target.candidate),
                    applicationName: target.candidate.applicationName,
                    windowTitle: target.candidate.title,
                    appIcon: icon
                )
            }
            let priorities = Dictionary(uniqueKeysWithValues: targets.map { target in
                let application = target.window.owningApplication.flatMap {
                    NSRunningApplication(processIdentifier: $0.processID)
                }
                let priority: Int
                if application?.isActive == true {
                    priority = 0
                } else if application?.activationPolicy == .regular {
                    priority = 1
                } else {
                    priority = 2
                }
                return (target.candidate.id, priority)
            })
            let stableIDs = Self.stableWindowOrder(
                previous: options.map(\.id),
                available: refreshedOptions.map(\.id),
                priority: priorities
            )
            let optionsByID = Dictionary(uniqueKeysWithValues: refreshedOptions.map {
                ($0.id, $0)
            })
            options = stableIDs.compactMap { optionsByID[$0] }
            if let previousSelection,
               options.contains(where: { $0.id == previousSelection }) {
                selectedWindowID = previousSelection
            } else {
                selectedWindowID = nil
            }
            isRefreshing = false

            // Metadata appears immediately. Thumbnails then fill in progressively so
            // a desktop with many windows never blocks the picker from becoming usable.
            let targetsByID = Dictionary(uniqueKeysWithValues: targets.map {
                ($0.candidate.id, $0)
            })
            for windowID in stableIDs.prefix(36) {
                guard let target = targetsByID[windowID] else { continue }
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                do {
                    let image = try await captureService.captureThumbnail(window: target.window)
                    guard generation == refreshGeneration, !Task.isCancelled,
                          let index = options.firstIndex(where: {
                              $0.id == target.candidate.id
                          }) else { return }
                    options[index].thumbnail = NSImage(cgImage: image, size: .zero)
                } catch {
                    // Protected or transient windows can reject preview capture. Keep
                    // their metadata card selectable; the recorder performs the final
                    // availability check when the user starts.
                    continue
                }
            }
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            options = []
            selectedWindowID = nil
            isRefreshing = false
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func stableWindowOrder(
        previous: [CGWindowID],
        available: [CGWindowID],
        priority: [CGWindowID: Int]
    ) -> [CGWindowID] {
        let previousIndex = Dictionary(uniqueKeysWithValues: previous.enumerated().map {
            ($0.element, $0.offset)
        })
        let availableIndex = Dictionary(uniqueKeysWithValues: available.enumerated().map {
            ($0.element, $0.offset)
        })
        return available.sorted { lhs, rhs in
            let lhsPriority = priority[lhs] ?? 1
            let rhsPriority = priority[rhs] ?? 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            switch (previousIndex[lhs], previousIndex[rhs]) {
            case let (lhsIndex?, rhsIndex?):
                return lhsIndex < rhsIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return (availableIndex[lhs] ?? .max) < (availableIndex[rhs] ?? .max)
            }
        }
    }
}
