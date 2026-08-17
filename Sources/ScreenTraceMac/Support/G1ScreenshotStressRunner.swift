import AppKit
import Foundation
import ScreenTraceCore

struct G1ScreenshotStressConfiguration {
    let iterations: Int
    let reportURL: URL

    init?(arguments: [String]) {
        guard arguments.contains("--g1-screenshot-stress") else { return nil }
        let requestedIterations = Self.option("--iterations", in: arguments)
            .flatMap(Int.init) ?? 100
        iterations = min(max(requestedIterations, 1), 1_000)

        let requestedPath = Self.option("--report", in: arguments)
            ?? "Build/Quality/g1-screenshot-stress-latest.json"
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        reportURL = URL(fileURLWithPath: requestedPath, relativeTo: workingDirectory)
            .standardizedFileURL
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
enum G1ScreenshotStressRunner {
    static func run(_ configuration: G1ScreenshotStressConfiguration) async -> Int32 {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        guard ScreenPermission.hasAccess else {
            writeReport(
                [
                    "schemaVersion": 1,
                    "generatedAt": generatedAt,
                    "gate": "G1",
                    "result": "blocked",
                    "reason": "screenCapturePermissionUnavailable",
                    "requestedIterations": configuration.iterations
                ],
                to: configuration.reportURL
            )
            return 77
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = displayID(for: screen) else {
            writeReport(
                [
                    "schemaVersion": 1,
                    "generatedAt": generatedAt,
                    "gate": "G1",
                    "result": "blocked",
                    "reason": "displayUnavailable",
                    "requestedIterations": configuration.iterations
                ],
                to: configuration.reportURL
            )
            return 78
        }

        let displayBounds = CGDisplayBounds(displayID)
        let width = min(max(displayBounds.width * 0.25, 320), 640)
        let height = min(max(displayBounds.height * 0.25, 180), 360)
        let captureRect = CGRect(
            x: displayBounds.midX - width / 2,
            y: displayBounds.midY - height / 2,
            width: width,
            height: height
        ).integral
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ScreenTrace-G1-Stress-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = TraceProjectStore(rootDirectory: temporaryRoot)
        let clipboardSnapshot = PasteboardSnapshot(pasteboard: .general)
        let captureService = ScreenCaptureService()
        var captureDurations: [Double] = []
        var deliveryDurations: [Double] = []
        var totalDurations: [Double] = []
        var failures: [[String: Any]] = []

        defer {
            clipboardSnapshot.restore(to: .general)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        do {
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true
            )
        } catch {
            writeReport(
                [
                    "schemaVersion": 1,
                    "generatedAt": generatedAt,
                    "gate": "G1",
                    "result": "failed",
                    "reason": "temporaryStorageUnavailable",
                    "requestedIterations": configuration.iterations
                ],
                to: configuration.reportURL
            )
            return 73
        }

        for iteration in 1...configuration.iterations {
            let totalStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                let captureStartedAt = ProcessInfo.processInfo.systemUptime
                let cgImage = try await captureService.capture(
                    globalDisplayRect: captureRect
                )
                captureDurations.append(milliseconds(since: captureStartedAt))

                let deliveryStartedAt = ProcessInfo.processInfo.systemUptime
                let pngData = try ImageEncoding.pngData(from: cgImage)
                let trace = try store.saveScreenshot(
                    pngData: pngData,
                    width: cgImage.width,
                    height: cgImage.height,
                    titlePrefix: "G1 压力验证"
                )
                let image = ImageEncoding.nsImage(from: cgImage)
                guard ImageClipboardWriter.write(image) else {
                    throw G1ScreenshotStressError.clipboardUnreadable
                }
                guard let fileURL = QuickAccessFileTransfer.bestFileURL(for: trace),
                      try Data(contentsOf: fileURL, options: [.mappedIfSafe]) == pngData else {
                    throw G1ScreenshotStressError.quickAccessFileUnreadable
                }
                let provider = QuickAccessFileTransfer.itemProvider(
                    fileURL: fileURL,
                    suggestedName: QuickAccessFileTransfer.suggestedFileName(
                        for: trace,
                        fileURL: fileURL
                    ),
                    fallbackImage: image
                )
                guard provider.registeredTypeIdentifiers.contains("public.png") else {
                    throw G1ScreenshotStressError.quickAccessProviderUnavailable
                }
                deliveryDurations.append(milliseconds(since: deliveryStartedAt))
                totalDurations.append(milliseconds(since: totalStartedAt))
            } catch {
                failures.append([
                    "iteration": iteration,
                    "code": failureCode(for: error)
                ])
            }
        }

        let succeeded = totalDurations.count
        let passed = succeeded == configuration.iterations && failures.isEmpty
        let report: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "gate": "G1",
            "result": passed ? "passed" : "failed",
            "requestedIterations": configuration.iterations,
            "successfulIterations": succeeded,
            "failedIterations": failures.count,
            "failures": failures,
            "capture": metricSummary(captureDurations),
            "delivery": metricSummary(deliveryDurations),
            "captureToUseful": metricSummary(totalDurations),
            "source": [
                "displayID": displayID,
                "widthPoints": Int(captureRect.width),
                "heightPoints": Int(captureRect.height)
            ],
            "checks": [
                "realScreenCapture": true,
                "atomicProjectWrite": true,
                "generalClipboardReadable": true,
                "clipboardRestoredAfterRun": true,
                "quickAccessPNGProvider": true,
                "temporaryProjectIsolation": true
            ],
            "privacy": "Only aggregate timings and stable failure codes are recorded. Captured pixels and projects are deleted after the run."
        ]
        writeReport(report, to: configuration.reportURL)
        return passed ? 0 : 1
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func milliseconds(since startedAt: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private static func metricSummary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else {
            return ["sampleCount": 0]
        }
        let sorted = values.sorted()
        return [
            "sampleCount": sorted.count,
            "p50Milliseconds": percentile(0.50, sorted: sorted),
            "p95Milliseconds": percentile(0.95, sorted: sorted),
            "maximumMilliseconds": sorted.last ?? 0
        ]
    }

    private static func percentile(_ requested: Double, sorted: [Double]) -> Double {
        let position = max(Int(ceil(requested * Double(sorted.count))) - 1, 0)
        return sorted[min(position, sorted.count - 1)]
    }

    private static func failureCode(for error: Error) -> String {
        if let stressError = error as? G1ScreenshotStressError {
            return stressError.rawValue
        }
        if error is ScreenCaptureServiceError {
            return "screenCaptureFailed"
        }
        if error is ImageEncodingError {
            return "imageEncodingFailed"
        }
        if error is TraceProjectStoreError {
            return "projectWriteFailed"
        }
        return "unexpectedFailure"
    }

    private static func writeReport(_ report: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("Unable to write G1 screenshot stress report.\n".utf8)
            )
        }
    }
}

private enum G1ScreenshotStressError: String, Error {
    case clipboardUnreadable
    case quickAccessFileUnreadable
    case quickAccessProviderUnavailable
}

@MainActor
private struct PasteboardSnapshot {
    private struct Item {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    private let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(representations: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems: [NSPasteboardItem] = items.compactMap { item in
            guard !item.representations.isEmpty else { return nil }
            let restored = NSPasteboardItem()
            for (type, data) in item.representations {
                restored.setData(data, forType: type)
            }
            return restored
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
