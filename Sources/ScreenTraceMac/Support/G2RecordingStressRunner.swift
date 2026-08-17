import AppKit
import AVFoundation
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit
import ScreenTraceCore

struct G2RecordingStressConfiguration {
    let durationSeconds: Double
    let framesPerSecond: Int
    let reportURL: URL
    let workRootURL: URL?
    let readyMarkerURL: URL?

    init?(arguments: [String]) {
        guard arguments.contains("--g2-recording-stress") else { return nil }
        let requestedDuration = Self.option("--duration-seconds", in: arguments)
            .flatMap(Double.init) ?? 60
        durationSeconds = min(max(requestedDuration, 5), 7_200)
        let requestedFPS = Self.option("--fps", in: arguments).flatMap(Int.init) ?? 60
        framesPerSecond = requestedFPS >= 45 ? 60 : 30
        let requestedPath = Self.option("--report", in: arguments)
            ?? "Build/Quality/g2-recording-stress-latest.json"
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        reportURL = URL(fileURLWithPath: requestedPath, relativeTo: workingDirectory)
            .standardizedFileURL
        workRootURL = Self.option("--work-root", in: arguments).map {
            URL(fileURLWithPath: $0, relativeTo: workingDirectory).standardizedFileURL
        }
        readyMarkerURL = Self.option("--ready-marker", in: arguments).map {
            URL(fileURLWithPath: $0, relativeTo: workingDirectory).standardizedFileURL
        }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

struct G2RecordingAcceptanceInput {
    let requestedDurationSeconds: Double
    let actualDurationSeconds: Double
    let requestedFramesPerSecond: Int
    let measuredFramesPerSecond: Double
    let receivedCompleteVideoFrameCount: Int
    let writtenVideoFrameCount: Int
    let videoTrackPresent: Bool
    let videoHealthy: Bool
    let droppedFrameCount: Int
    let physicalTracksVerified: Bool
    let systemAudioRMS: Double
    let minimumSystemAudioWindowRMS: Double
    let sampledSystemAudioWindowCount: Int
    let systemAudioDurationSeconds: Double
    let systemAudioObservedTimelineSeconds: Double
    let generatedToneDurationSeconds: Double
    let routerAudioCallbackCount: Int
    let deliveredAudioCallbackCount: Int
    let receivedAudioSampleCount: Int
    let appendedAudioSampleCount: Int
    let pendingAudioSampleCount: Int
    let startPhysicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let endPhysicalFootprintBytes: UInt64
    let stopToPlayableMilliseconds: Double
    let p95MainActorSchedulingDelayMilliseconds: Double
    let maximumMainActorSchedulingDelayMilliseconds: Double
    let sampledVideoFrameCount: Int
    let distinctVideoFrameSignatureCount: Int
}

struct G2RecordingAcceptanceResult {
    static let maximumPeakPhysicalFootprintBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumPhysicalFootprintGrowthBytes: UInt64 = 128 * 1_024 * 1_024
    static let maximumStopToPlayableMilliseconds = 10_000.0
    static let maximumP95MainActorSchedulingDelayMilliseconds = 50.0
    static let maximumMainActorSchedulingDelayMilliseconds = 250.0
    static let maximumAudioVideoDriftSeconds = 0.25
    static let minimumAudioCallbacksPerSecond = 49.0

    static func requiredDistributedSampleCount(
        for durationSeconds: Double,
        shortCount: Int
    ) -> Int {
        DistributedMediaEvidenceSampling.sampleCount(
            for: durationSeconds,
            shortCount: shortCount
        )
    }

    let realScreenCapture: Bool
    let mediaDurationWithinTwoSeconds: Bool
    let frameRateMet: Bool
    let videoFrameCountComplete: Bool
    let videoHealthy: Bool
    let zeroDroppedFrames: Bool
    let physicalTracksVerified: Bool
    let systemAudioNonSilent: Bool
    let systemAudioContinuous: Bool
    let systemAudioSynchronized: Bool
    let systemAudioTimelineComplete: Bool
    let systemAudioCallbacksComplete: Bool
    let audioStimulusComplete: Bool
    let memoryBounded: Bool
    let stopLatencyMet: Bool
    let mainActorResponsive: Bool
    let dynamicContentVerified: Bool

    var passed: Bool {
        realScreenCapture
            && mediaDurationWithinTwoSeconds
            && frameRateMet
            && videoFrameCountComplete
            && videoHealthy
            && zeroDroppedFrames
            && physicalTracksVerified
            && systemAudioNonSilent
            && systemAudioContinuous
            && systemAudioSynchronized
            && systemAudioTimelineComplete
            && systemAudioCallbacksComplete
            && audioStimulusComplete
            && memoryBounded
            && stopLatencyMet
            && mainActorResponsive
            && dynamicContentVerified
    }

    init(_ input: G2RecordingAcceptanceInput) {
        let durationDrift = abs(
            input.actualDurationSeconds - input.requestedDurationSeconds
        )
        let minimumFPS = input.requestedFramesPerSecond >= 60
            ? 58.0
            : Double(input.requestedFramesPerSecond) * 0.95
        let minimumAudioCallbacks = Int(
            floor(
                input.requestedDurationSeconds
                    * Self.minimumAudioCallbacksPerSecond
            )
        )
        let footprintGrowth = input.endPhysicalFootprintBytes
            > input.startPhysicalFootprintBytes
            ? input.endPhysicalFootprintBytes - input.startPhysicalFootprintBytes
            : 0

        realScreenCapture = input.videoTrackPresent
        mediaDurationWithinTwoSeconds = input.actualDurationSeconds
            >= input.requestedDurationSeconds - 1
            && durationDrift <= 2
        frameRateMet = input.measuredFramesPerSecond >= minimumFPS
        let minimumWrittenVideoFrames = Int(
            floor(
                input.requestedDurationSeconds
                    * Double(input.requestedFramesPerSecond)
                    * 0.98
            )
        )
        videoFrameCountComplete = input.writtenVideoFrameCount
            >= minimumWrittenVideoFrames
        videoHealthy = input.videoHealthy
        zeroDroppedFrames = input.droppedFrameCount == 0
        physicalTracksVerified = input.physicalTracksVerified
        systemAudioNonSilent = input.systemAudioRMS > 0.000_05
        let requiredAudioWindowCount = Self.requiredDistributedSampleCount(
            for: input.requestedDurationSeconds,
            shortCount: 5
        )
        systemAudioContinuous = input.sampledSystemAudioWindowCount
            >= requiredAudioWindowCount
            && input.minimumSystemAudioWindowRMS > 0.000_05
        systemAudioSynchronized = abs(
            input.systemAudioDurationSeconds - input.actualDurationSeconds
        ) <= Self.maximumAudioVideoDriftSeconds
        systemAudioTimelineComplete = input.systemAudioObservedTimelineSeconds
            >= input.requestedDurationSeconds - Self.maximumAudioVideoDriftSeconds
        systemAudioCallbacksComplete = input.routerAudioCallbackCount >= minimumAudioCallbacks
            && input.deliveredAudioCallbackCount == input.routerAudioCallbackCount
            && input.receivedAudioSampleCount == input.deliveredAudioCallbackCount
            && input.appendedAudioSampleCount == input.receivedAudioSampleCount
            && input.pendingAudioSampleCount == 0
        audioStimulusComplete = input.generatedToneDurationSeconds
            >= input.requestedDurationSeconds - 0.5
        memoryBounded = input.peakPhysicalFootprintBytes > 0
            && input.peakPhysicalFootprintBytes
                <= Self.maximumPeakPhysicalFootprintBytes
            && footprintGrowth <= Self.maximumPhysicalFootprintGrowthBytes
        stopLatencyMet = input.stopToPlayableMilliseconds >= 0
            && input.stopToPlayableMilliseconds
                <= Self.maximumStopToPlayableMilliseconds
        mainActorResponsive = input.p95MainActorSchedulingDelayMilliseconds
            <= Self.maximumP95MainActorSchedulingDelayMilliseconds
            && input.maximumMainActorSchedulingDelayMilliseconds
                <= Self.maximumMainActorSchedulingDelayMilliseconds
        let requiredVideoSampleCount = Self.requiredDistributedSampleCount(
            for: input.requestedDurationSeconds,
            shortCount: 6
        )
        let requiredDistinctVideoFrames = max(
            3,
            Int(ceil(Double(requiredVideoSampleCount) * 0.5))
        )
        dynamicContentVerified = input.sampledVideoFrameCount
            >= requiredVideoSampleCount
            && input.distinctVideoFrameSignatureCount
                >= requiredDistinctVideoFrames
    }
}

struct G2DynamicVideoEvidence: Sendable {
    let sampledFrameCount: Int
    let distinctFrameSignatureCount: Int
}

@MainActor
enum G2DynamicVideoAnalyzer {
    static func analyze(url: URL, durationSeconds: Double) async -> G2DynamicVideoEvidence {
        guard durationSeconds.isFinite, durationSeconds >= 3 else {
            return G2DynamicVideoEvidence(
                sampledFrameCount: 0,
                distinctFrameSignatureCount: 0
            )
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let sampleCount = G2RecordingAcceptanceResult.requiredDistributedSampleCount(
            for: durationSeconds,
            shortCount: 6
        )
        let sampleTimes = (0..<sampleCount).map { index in
            let progress = sampleCount == 1
                ? 0.5
                : 0.04 + (0.92 * Double(index) / Double(sampleCount - 1))
            return progress
        }.map {
            min(max(durationSeconds * $0, 1), durationSeconds - 1)
        }
        var signatures: Set<UInt64> = []
        var sampledCount = 0
        for seconds in sampleTimes {
            do {
                let image = try await generator.image(at: CMTime(
                    seconds: seconds,
                    preferredTimescale: 600
                )).image
                guard let signature = signature(of: image) else { continue }
                sampledCount += 1
                signatures.insert(signature)
            } catch {
                continue
            }
        }
        return G2DynamicVideoEvidence(
            sampledFrameCount: sampledCount,
            distinctFrameSignatureCount: signatures.count
        )
    }

    private static func signature(of image: CGImage) -> UInt64? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let bytes = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(bitmap.bitsPerPixel / 8, 1)
        guard bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0,
              bitmap.bytesPerRow >= bitmap.pixelsWide * bytesPerPixel else {
            return nil
        }
        let xStride = max(bitmap.pixelsWide / 48, 1)
        let yStride = max(bitmap.pixelsHigh / 32, 1)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                for component in 0..<min(bytesPerPixel, 4) {
                    hash ^= UInt64(bytes[offset + component])
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return hash
    }
}

@MainActor
private final class G2VisualStimulusController: NSObject {
    private let window: NSWindow
    private let stimulusView: G2VisualStimulusView
    private var timer: Timer?

    init(screen: NSScreen) {
        let size = CGSize(width: 560, height: 180)
        let visibleFrame = screen.visibleFrame
        let frame = CGRect(
            x: visibleFrame.minX + 24,
            y: visibleFrame.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
        stimulusView = G2VisualStimulusView(frame: CGRect(origin: .zero, size: size))
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        super.init()
        window.contentView = stimulusView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    func start() {
        window.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(advance),
            userInfo: nil,
            repeats: true
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        window.close()
    }

    @objc private func advance() {
        stimulusView.advance()
    }
}

@MainActor
private final class G2VisualStimulusView: NSView {
    private var tick = 0

    override var isFlipped: Bool { true }

    func advance() {
        tick &+= 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        bounds.fill()

        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemCyan, .systemBlue, .systemPurple
        ]
        let barWidth = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.withAlphaComponent(0.72).setFill()
            CGRect(
                x: CGFloat(index) * barWidth,
                y: bounds.height - 22,
                width: barWidth + 1,
                height: 22
            ).fill()
        }

        let travel = max(bounds.width - 72, 1)
        let progress = CGFloat(tick % 97) / 96
        let markerX = 36 + progress * travel
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: markerX - 24, y: 72, width: 48, height: 48),
            xRadius: 13,
            yRadius: 13
        ).fill()

        let title = "SCREENTRACE LIVE  \(tick)"
        title.draw(
            at: CGPoint(x: 24, y: 20),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 25, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }
}

struct G2SystemAudioProbeConfiguration {
    let durationSeconds: Double
    let reportURL: URL

    init?(arguments: [String]) {
        guard arguments.contains("--g2-system-audio-probe") else { return nil }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        durationSeconds = min(max(option("--duration-seconds").flatMap(Double.init) ?? 12, 5), 120)
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        reportURL = URL(
            fileURLWithPath: option("--report")
                ?? "Build/Quality/g2-system-audio-probe.json",
            relativeTo: workingDirectory
        ).standardizedFileURL
    }
}

struct G2SourceHostConfiguration {
    let windowTitle: String
    let readyMarkerURL: URL

    init?(arguments: [String]) {
        guard arguments.contains("--g2-source-host") else { return nil }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let title = option("--window-title"),
              let readyMarker = option("--ready-marker") else { return nil }
        windowTitle = title
        readyMarkerURL = URL(fileURLWithPath: readyMarker).standardizedFileURL
    }
}

@MainActor
enum G2SourceHostRunner {
    private static var retainedWindow: NSWindow?

    static func start(_ configuration: G2SourceHostConfiguration) -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = configuration.windowTitle
        window.backgroundColor = NSColor(
            calibratedRed: 0.12,
            green: 0.38,
            blue: 0.78,
            alpha: 1
        )
        window.orderFrontRegardless()
        retainedWindow = window
        do {
            try FileManager.default.createDirectory(
                at: configuration.readyMarkerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ready\n".utf8).write(
                to: configuration.readyMarkerURL,
                options: .atomic
            )
            return true
        } catch {
            retainedWindow = nil
            return false
        }
    }
}

struct G2SourceInterruptionConfiguration {
    let closeAfterSeconds: Double
    let callbackTimeoutSeconds: Double
    let reportURL: URL

    init?(arguments: [String]) {
        guard arguments.contains("--g2-source-interruption") else { return nil }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        closeAfterSeconds = min(
            max(option("--close-after-seconds").flatMap(Double.init) ?? 8, 5),
            30
        )
        callbackTimeoutSeconds = min(
            max(option("--callback-timeout-seconds").flatMap(Double.init) ?? 12, 3),
            30
        )
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        reportURL = URL(
            fileURLWithPath: option("--report")
                ?? "Build/Quality/g2-source-interruption-latest.json",
            relativeTo: workingDirectory
        ).standardizedFileURL
    }
}

@MainActor
enum G2SourceInterruptionRunner {
    static func run(_ configuration: G2SourceInterruptionConfiguration) async -> Int32 {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let workRoot = configuration.reportURL.deletingLastPathComponent()
            .appendingPathComponent(
                "g2-source-interruption-\(UUID().uuidString)",
                isDirectory: true
        )
        let windowTitle = "ScreenTrace G2 Source \(UUID().uuidString)"
        let hostReadyMarker = workRoot.appendingPathComponent("source-host.ready")
        let hostProcess = Process()
        hostProcess.standardOutput = FileHandle.nullDevice
        hostProcess.standardError = FileHandle.nullDevice
        let store = TraceProjectStore(rootDirectory: workRoot)
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )
        let tone = G2EnduranceToneGenerator()
        var interruptionError: Error?
        var interruptionObservedAtUptime: TimeInterval?
        service.onUnexpectedCaptureStop = { error in
            interruptionError = error
            interruptionObservedAtUptime = interruptionObservedAtUptime
                ?? ProcessInfo.processInfo.systemUptime
        }
        do {
            guard ScreenPermission.hasAccess else { return 77 }
            try FileManager.default.createDirectory(
                at: workRoot,
                withIntermediateDirectories: true
            )
            guard let executableURL = Bundle.main.executableURL else {
                throw G2SourceInterruptionError.sourceHostUnavailable
            }
            hostProcess.executableURL = executableURL
            hostProcess.arguments = [
                "--g2-source-host",
                "--window-title", windowTitle,
                "--ready-marker", hostReadyMarker.path
            ]
            try hostProcess.run()
            let hostReadyDeadline = ProcessInfo.processInfo.systemUptime + 5
            while !FileManager.default.fileExists(atPath: hostReadyMarker.path),
                  hostProcess.isRunning,
                  ProcessInfo.processInfo.systemUptime < hostReadyDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard hostProcess.isRunning,
                  FileManager.default.fileExists(atPath: hostReadyMarker.path) else {
                throw G2SourceInterruptionError.sourceHostUnavailable
            }
            var capturedWindow: SCWindow?
            let sourceDeadline = ProcessInfo.processInfo.systemUptime + 5
            while capturedWindow == nil,
                  ProcessInfo.processInfo.systemUptime < sourceDeadline {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                capturedWindow = content.windows.first(where: {
                    $0.title == windowTitle
                        && $0.owningApplication?.processID
                            == hostProcess.processIdentifier
                })
                if capturedWindow == nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            guard let capturedWindow else {
                throw G2SourceInterruptionError.testWindowUnavailable
            }
            let source = RecordingCaptureSource(
                mode: .window,
                windowID: capturedWindow.windowID,
                captureBounds: capturedWindow.frame,
                windowTitle: windowTitle,
                applicationName: "ScreenTrace G2"
            )
            try tone.start()
            _ = try await service.start(
                source: source,
                options: ScreenRecordingOptions(
                    framesPerSecond: 60,
                    capturesSystemAudio: true,
                    capturesMicrophone: false,
                    capturesCamera: false,
                    excludesCurrentProcessAudio: true
                )
            )
            try await Task.sleep(for: .seconds(configuration.closeAfterSeconds))
            let sourceClosedAtUptime = ProcessInfo.processInfo.systemUptime
            hostProcess.terminate()
            let hostExitDeadline = ProcessInfo.processInfo.systemUptime + 5
            while hostProcess.isRunning,
                  ProcessInfo.processInfo.systemUptime < hostExitDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !hostProcess.isRunning else {
                throw G2SourceInterruptionError.sourceHostTerminationTimedOut
            }
            let callbackDeadline = ProcessInfo.processInfo.systemUptime
                + configuration.callbackTimeoutSeconds
            while interruptionError == nil,
                  ProcessInfo.processInfo.systemUptime < callbackDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard interruptionError != nil else {
                throw G2SourceInterruptionError.callbackTimedOut
            }
            let interruptionDetectionMilliseconds = max(
                0,
                ((interruptionObservedAtUptime ?? ProcessInfo.processInfo.systemUptime)
                    - sourceClosedAtUptime) * 1_000
            )
            let saved = try await service.stop()
            tone.stop()
            let asset = AVURLAsset(url: saved.rawAssetURL)
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioEvidence = await AudioMediaEvidenceAnalyzer.analyze(
                url: saved.rawAssetURL
            )
            let health = service.lastRecordingHealthReport
                ?? (try? store.loadRecordingHealthReport(from: saved.packageURL))
            let passed = !videoTracks.isEmpty
                && duration >= configuration.closeAfterSeconds - 1
                && duration <= configuration.closeAfterSeconds + 7
                && service.lastCaptureInterruptionError != nil
                && interruptionDetectionMilliseconds <= 6_000
                && health?.rawTrackIntegrity?.isVerified == true
                && (audioEvidence?.rootMeanSquare ?? 0) > 0.000_05
                && (audioEvidence?.minimumWindowRootMeanSquare ?? 0) > 0.000_05
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2-source-interruption",
                "result": passed ? "passed" : "failed",
                "evidenceLevel": Bundle.main.bundleURL.path.hasPrefix("/Applications/")
                    ? "E4-installed-native-app-source-disappearance"
                    : "E2-native-app-source-disappearance",
                "fault": "capturedWindowHostTerminated",
                "closeAfterSeconds": configuration.closeAfterSeconds,
                "callbackTimeoutSeconds": configuration.callbackTimeoutSeconds,
                "interruptionCallbackReceived": interruptionError != nil,
                "serviceRecordedInterruption": service.lastCaptureInterruptionError != nil,
                "interruptionDetectionMilliseconds": interruptionDetectionMilliseconds,
                "recoveredDurationSeconds": duration,
                "systemAudioDurationSeconds": audioEvidence?.durationSeconds ?? 0,
                "systemAudioRMS": audioEvidence?.rootMeanSquare ?? 0,
                "minimumSystemAudioWindowRMS": audioEvidence?
                    .minimumWindowRootMeanSquare ?? 0,
                "systemAudioWindowRMS": audioEvidence?.windowRootMeanSquares ?? [],
                "checks": [
                    "rawVideoPlayable": !videoTracks.isEmpty,
                    "postCloseTailBounded": duration
                        <= configuration.closeAfterSeconds + 7,
                    "interruptionDetectedWithinSixSeconds":
                        interruptionDetectionMilliseconds <= 6_000,
                    "physicalTracksVerified": health?.rawTrackIntegrity?.isVerified == true,
                    "systemAudioNonSilent": (audioEvidence?.rootMeanSquare ?? 0) > 0.000_05,
                    "systemAudioContinuous": (audioEvidence?
                        .minimumWindowRootMeanSquare ?? 0) > 0.000_05,
                    "projectAdvancedToProcessing": saved.manifest.state == .processing
                ]
            ], to: configuration.reportURL)
            try? FileManager.default.removeItem(at: workRoot)
            return passed ? 0 : 1
        } catch {
            tone.stop()
            if hostProcess.isRunning {
                hostProcess.terminate()
            }
            if service.isRecording {
                _ = try? await service.stopForDiscard()
            }
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2-source-interruption",
                "result": "failed",
                "fault": "capturedWindowHostTerminated",
                "errorType": String(reflecting: type(of: error)),
                "errorDescription": error.localizedDescription,
                "interruptionCallbackReceived": interruptionError != nil
            ], to: configuration.reportURL)
            try? FileManager.default.removeItem(at: workRoot)
            return 1
        }
    }

    private static func writeReport(_ report: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private enum G2SourceInterruptionError: LocalizedError {
    case sourceHostUnavailable
    case sourceHostTerminationTimedOut
    case testWindowUnavailable
    case callbackTimedOut

    var errorDescription: String? {
        switch self {
        case .sourceHostUnavailable:
            "无法启动独立录屏来源测试进程。"
        case .sourceHostTerminationTimedOut:
            "独立录屏来源进程未在时限内退出。"
        case .testWindowUnavailable:
            "未能在 ScreenCaptureKit 来源列表中找到测试窗口。"
        case .callbackTimedOut:
            "销毁录制来源后，ScreenCaptureKit 未在时限内报告中断。"
        }
    }
}

@MainActor
enum G2SystemAudioProbeRunner {
    static func run(_ configuration: G2SystemAudioProbeConfiguration) async -> Int32 {
        let tone = G2EnduranceToneGenerator()
        do {
            guard ScreenPermission.hasAccess else { return 77 }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let screen = NSScreen.main ?? NSScreen.screens.first,
                  let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                  ] as? NSNumber,
                  let display = content.displays.first(where: {
                    $0.displayID == number.uint32Value
                  }) else { return 78 }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = display.width
            streamConfiguration.height = display.height
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            streamConfiguration.queueDepth = 8
            streamConfiguration.capturesAudio = true
            streamConfiguration.excludesCurrentProcessAudio = true
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2
            let output = G2SystemAudioProbeOutput()
            let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ScreenTrace-G2-video-probe-\(UUID().uuidString).mp4"
            )
            defer { try? FileManager.default.removeItem(at: videoURL) }
            let videoWriter = try ScreenVideoTrackWriter(
                outputURL: videoURL,
                dimensions: TraceDimensions(
                    width: display.width,
                    height: display.height
                ),
                framesPerSecond: 60,
                capturesSystemAudio: false
            )
            output.videoWriter = videoWriter
            let queue = DispatchQueue(
                label: "app.screentrace.g2-system-audio-probe",
                qos: .userInteractive
            )
            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: nil
            )
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try tone.start()
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(configuration.durationSeconds))
            videoWriter.prepareToFinish()
            try await stream.stopCapture()
            try await videoWriter.finish()
            tone.stop()
            let snapshot = output.snapshot
            let passed = snapshot.sampleCount > Int(configuration.durationSeconds * 30)
                && snapshot.timelineSeconds >= configuration.durationSeconds - 1
            writeReport([
                "schemaVersion": 1,
                "gate": "G2-system-audio-probe",
                "result": passed ? "passed" : "failed",
                "requestedDurationSeconds": configuration.durationSeconds,
                "rawCallbackCount": snapshot.sampleCount,
                "rawCallbackTimelineSeconds": snapshot.timelineSeconds,
                "rawScreenFrameCount": snapshot.screenFrameCount,
                "videoEncoderMeasuredFPS": videoWriter.performanceSnapshot
                    .measuredWrittenFramesPerSecond ?? 0,
                "externalToneRuntimeSeconds": tone.renderedDurationSeconds,
                "evidenceLevel": Bundle.main.bundleURL.path.hasPrefix("/Applications/")
                    ? "E4-installed-native-app"
                    : "E2-native-app-bundle"
            ], to: configuration.reportURL)
            return passed ? 0 : 1
        } catch {
            tone.stop()
            writeReport([
                "schemaVersion": 1,
                "gate": "G2-system-audio-probe",
                "result": "failed",
                "errorDescription": error.localizedDescription
            ], to: configuration.reportURL)
            return 1
        }
    }

    private static func writeReport(_ report: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private final class G2SystemAudioProbeOutput: NSObject, SCStreamOutput,
    @unchecked Sendable {
    var videoWriter: ScreenVideoTrackWriter?
    private let lock = NSLock()
    private var sampleCount = 0
    private var screenFrameCount = 0
    private var firstTime: CMTime?
    private var lastEndTime: CMTime?

    var snapshot: (
        sampleCount: Int,
        timelineSeconds: Double,
        screenFrameCount: Int
    ) {
        lock.withLock {
            let timeline: Double
            if let firstTime,
               let lastEndTime,
               firstTime.isNumeric,
               lastEndTime.isNumeric,
               lastEndTime >= firstTime {
                timeline = (lastEndTime - firstTime).seconds
            } else {
                timeline = 0
            }
            return (sampleCount, timeline, screenFrameCount)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            lock.withLock { screenFrameCount += 1 }
            videoWriter?.stream(
                stream,
                didOutputSampleBuffer: sampleBuffer,
                of: type
            )
            return
        }
        guard type == .audio else { return }
        lock.withLock {
            sampleCount += 1
            if firstTime == nil { firstTime = sampleBuffer.presentationTimeStamp }
            let duration = sampleBuffer.duration.isNumeric
                ? sampleBuffer.duration
                : CMTime(value: 1_024, timescale: 48_000)
            lastEndTime = sampleBuffer.presentationTimeStamp + duration
        }
    }
}

@MainActor
enum G2RecordingStressRunner {
    static func run(_ configuration: G2RecordingStressConfiguration) async -> Int32 {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        guard ScreenPermission.hasAccess else {
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": "blocked",
                "reason": "screenCapturePermissionUnavailable",
                "requestedDurationSeconds": configuration.durationSeconds,
                "requestedFramesPerSecond": configuration.framesPerSecond
            ], to: configuration.reportURL)
            return 77
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = displayID(for: screen) else {
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": "blocked",
                "reason": "displayUnavailable"
            ], to: configuration.reportURL)
            return 78
        }

        let temporaryRoot = configuration.workRootURL
            ?? configuration.reportURL.deletingLastPathComponent()
                .appendingPathComponent("g2-work-\(UUID().uuidString)", isDirectory: true)
        let ownsTemporaryRoot = configuration.workRootURL == nil
        let store = TraceProjectStore(rootDirectory: temporaryRoot)
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )
        let visualStimulus = G2VisualStimulusController(screen: screen)
        let toneGenerator = G2EnduranceToneGenerator()
        var memorySamples: [UInt64] = []
        var mainActorSchedulingDelays: [Double] = []
        var saved: SavedTrace?
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true
            )
            visualStimulus.start()
            let bounds = CGDisplayBounds(displayID)
            let source = CaptureGeometry.displayRecordingSource(
                displayID: displayID,
                displayBounds: bounds
            )
            try toneGenerator.start()
            _ = try await service.start(
                source: source,
                options: ScreenRecordingOptions(
                    framesPerSecond: configuration.framesPerSecond,
                    capturesSystemAudio: true,
                    capturesMicrophone: false,
                    capturesCamera: false,
                    excludesCurrentProcessAudio: true,
                    excludesCurrentProcessWindows: false
                )
            )
            let captureStartedAt = ProcessInfo.processInfo.systemUptime
            if let readyMarkerURL = configuration.readyMarkerURL {
                try FileManager.default.createDirectory(
                    at: readyMarkerURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("ready\n".utf8).write(to: readyMarkerURL, options: .atomic)
            }
            let deadline = captureStartedAt + configuration.durationSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let footprint = physicalFootprintBytes() {
                    memorySamples.append(footprint)
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                let heartbeatSeconds = min(max(remaining, 0.05), 0.25)
                let heartbeatStartedAt = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .seconds(heartbeatSeconds))
                let observedHeartbeatSeconds = ProcessInfo.processInfo.systemUptime
                    - heartbeatStartedAt
                mainActorSchedulingDelays.append(
                    max(0, observedHeartbeatSeconds - heartbeatSeconds) * 1_000
                )
            }
            let stopStartedAt = ProcessInfo.processInfo.systemUptime
            let finalized = try await service.stop()
            toneGenerator.stop()
            visualStimulus.stop()
            let generatedToneSeconds = toneGenerator.renderedDurationSeconds
            let stopDurationMilliseconds = milliseconds(since: stopStartedAt)
            saved = finalized
            if let footprint = physicalFootprintBytes() {
                memorySamples.append(footprint)
            }
            let health = service.lastRecordingHealthReport
                ?? (try? store.loadRecordingHealthReport(from: finalized.packageURL))
            let media = AVURLAsset(url: finalized.rawAssetURL)
            let mediaDuration = try await media.load(.duration).seconds
            let videoTracks = try await media.loadTracks(withMediaType: .video)
            let fileSize = (try? FileManager.default.attributesOfItem(
                atPath: finalized.rawAssetURL.path
            )[.size] as? NSNumber)?.uint64Value ?? 0
            let audioEvidence = await AudioMediaEvidenceAnalyzer.analyze(
                url: finalized.rawAssetURL
            )
            let dynamicVideoEvidence = await G2DynamicVideoAnalyzer.analyze(
                url: finalized.rawAssetURL,
                durationSeconds: mediaDuration
            )
            let durationDrift = abs(mediaDuration - configuration.durationSeconds)
            let measuredFPS = health?.measuredFramesPerSecond ?? 0
            let capturePerformance = service.lastCapturePerformanceSnapshot
            let systemAudioCapture = service.lastSystemAudioCaptureSnapshot
            let startFootprint = memorySamples.first ?? 0
            let peakFootprint = memorySamples.max() ?? 0
            let endFootprint = memorySamples.last ?? 0
            let p95MainActorSchedulingDelay = percentile(
                mainActorSchedulingDelays,
                percentile: 0.95
            )
            let maximumMainActorSchedulingDelay = mainActorSchedulingDelays.max() ?? 0
            let acceptance = G2RecordingAcceptanceResult(
                G2RecordingAcceptanceInput(
                    requestedDurationSeconds: configuration.durationSeconds,
                    actualDurationSeconds: mediaDuration,
                    requestedFramesPerSecond: configuration.framesPerSecond,
                    measuredFramesPerSecond: measuredFPS,
                    receivedCompleteVideoFrameCount: capturePerformance?
                        .receivedCompleteFrameCount ?? 0,
                    writtenVideoFrameCount: capturePerformance?.writtenFrameCount ?? 0,
                    videoTrackPresent: !videoTracks.isEmpty,
                    videoHealthy: health?.videoStatus == .healthy,
                    droppedFrameCount: health?.droppedFrameCount ?? -1,
                    physicalTracksVerified: health?.rawTrackIntegrity?.isVerified == true,
                    systemAudioRMS: audioEvidence?.rootMeanSquare ?? 0,
                    minimumSystemAudioWindowRMS: audioEvidence?
                        .minimumWindowRootMeanSquare ?? 0,
                    sampledSystemAudioWindowCount: audioEvidence?
                        .windowRootMeanSquares.count ?? 0,
                    systemAudioDurationSeconds: audioEvidence?.durationSeconds ?? 0,
                    systemAudioObservedTimelineSeconds: systemAudioCapture?
                        .observedTimelineSeconds ?? 0,
                    generatedToneDurationSeconds: generatedToneSeconds,
                    routerAudioCallbackCount: service.lastRawSystemAudioCallbackCount,
                    deliveredAudioCallbackCount: systemAudioCapture?
                        .deliveredCallbackCount ?? 0,
                    receivedAudioSampleCount: systemAudioCapture?.receivedSampleCount ?? 0,
                    appendedAudioSampleCount: systemAudioCapture?.appendedSampleCount ?? 0,
                    pendingAudioSampleCount: systemAudioCapture?.pendingSampleCount ?? -1,
                    startPhysicalFootprintBytes: startFootprint,
                    peakPhysicalFootprintBytes: peakFootprint,
                    endPhysicalFootprintBytes: endFootprint,
                    stopToPlayableMilliseconds: stopDurationMilliseconds,
                    p95MainActorSchedulingDelayMilliseconds:
                        p95MainActorSchedulingDelay,
                    maximumMainActorSchedulingDelayMilliseconds:
                        maximumMainActorSchedulingDelay,
                    sampledVideoFrameCount: dynamicVideoEvidence.sampledFrameCount,
                    distinctVideoFrameSignatureCount: dynamicVideoEvidence
                        .distinctFrameSignatureCount
                )
            )
            let passed = acceptance.passed
            let isInstalledApplication = Bundle.main.bundleURL.standardizedFileURL.path
                .hasPrefix("/Applications/")
            let report: [String: Any] = [
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": passed ? "passed" : "failed",
                "evidenceLevel": isInstalledApplication
                    ? "E4-installed-native-app"
                    : "E2-real-media-native-app-bundle",
                "requestedDurationSeconds": configuration.durationSeconds,
                "actualDurationSeconds": mediaDuration,
                "durationDriftSeconds": durationDrift,
                "requestedFramesPerSecond": configuration.framesPerSecond,
                "measuredFramesPerSecond": measuredFPS,
                "receivedCompleteVideoFrameCount": capturePerformance?
                    .receivedCompleteFrameCount ?? 0,
                "writtenVideoFrameCount": capturePerformance?.writtenFrameCount ?? 0,
                "p95FrameIntervalMilliseconds": health?.p95FrameIntervalMilliseconds
                    ?? NSNull(),
                "droppedFrameCount": health?.droppedFrameCount ?? -1,
                "stopToPlayableMilliseconds": stopDurationMilliseconds,
                "p95MainActorSchedulingDelayMilliseconds":
                    p95MainActorSchedulingDelay,
                "maximumMainActorSchedulingDelayMilliseconds":
                    maximumMainActorSchedulingDelay,
                "peakPhysicalFootprintBytes": peakFootprint,
                "startPhysicalFootprintBytes": startFootprint,
                "endPhysicalFootprintBytes": endFootprint,
                "rawFileBytes": fileSize,
                "systemAudioRMS": audioEvidence?.rootMeanSquare ?? 0,
                "minimumSystemAudioWindowRMS": audioEvidence?
                    .minimumWindowRootMeanSquare ?? 0,
                "sampledSystemAudioWindowCount": audioEvidence?
                    .windowRootMeanSquares.count ?? 0,
                "systemAudioWindowRMS": audioEvidence?.windowRootMeanSquares ?? [],
                "systemAudioDurationSeconds": audioEvidence?.durationSeconds ?? 0,
                "systemAudioReceivedSampleCount": systemAudioCapture?.receivedSampleCount ?? 0,
                "systemAudioDeliveredCallbackCount": systemAudioCapture?.deliveredCallbackCount ?? 0,
                "routerRawSystemAudioCallbackCount": service.lastRawSystemAudioCallbackCount,
                "systemAudioAppendedSampleCount": systemAudioCapture?.appendedSampleCount ?? 0,
                "systemAudioObservedTimelineSeconds": systemAudioCapture?.observedTimelineSeconds ?? 0,
                "systemAudioPendingSampleCount": systemAudioCapture?.pendingSampleCount ?? 0,
                "generatedToneDurationSeconds": generatedToneSeconds,
                "sampledVideoFrameCount": dynamicVideoEvidence.sampledFrameCount,
                "distinctVideoFrameSignatureCount": dynamicVideoEvidence
                    .distinctFrameSignatureCount,
                "source": [
                    "displayID": displayID,
                    "widthPixels": finalized.manifest.dimensions?.width ?? 0,
                    "heightPixels": finalized.manifest.dimensions?.height ?? 0
                ],
                "checks": [
                    "realScreenCapture": acceptance.realScreenCapture,
                    "mediaDurationWithinTwoSeconds": acceptance
                        .mediaDurationWithinTwoSeconds,
                    "frameRateMet": acceptance.frameRateMet,
                    "videoFrameCountComplete": acceptance.videoFrameCountComplete,
                    "videoHealthy": acceptance.videoHealthy,
                    "zeroDroppedFrames": acceptance.zeroDroppedFrames,
                    "physicalTracksVerified": acceptance.physicalTracksVerified,
                    "systemAudioNonSilent": acceptance.systemAudioNonSilent,
                    "systemAudioContinuous": acceptance.systemAudioContinuous,
                    "systemAudioSynchronized": acceptance.systemAudioSynchronized,
                    "systemAudioTimelineComplete": acceptance.systemAudioTimelineComplete,
                    "systemAudioCallbacksComplete": acceptance.systemAudioCallbacksComplete,
                    "audioStimulusComplete": acceptance.audioStimulusComplete,
                    "memoryBounded": acceptance.memoryBounded,
                    "stopLatencyMet": acceptance.stopLatencyMet,
                    "mainActorResponsive": acceptance.mainActorResponsive,
                    "dynamicContentVerified": acceptance.dynamicContentVerified,
                    "rawVideoPlayable": acceptance.realScreenCapture
                ],
                "scope": configuration.durationSeconds >= 3_600
                    ? "full-one-hour-endurance"
                    : "short-endurance-smoke",
                "application": [
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown",
                    "build": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion"
                    ) as? String ?? "unknown",
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown"
                ],
                "environment": [
                    "operatingSystem": ProcessInfo.processInfo
                        .operatingSystemVersionString,
                    "hardwareModel": sysctlString("hw.model") ?? "unknown",
                    "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount,
                    "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory
                ],
                "thresholds": [
                    "maximumAudioVideoDriftSeconds": G2RecordingAcceptanceResult
                        .maximumAudioVideoDriftSeconds,
                    "minimumAudioCallbacksPerSecond": G2RecordingAcceptanceResult
                        .minimumAudioCallbacksPerSecond,
                    "maximumPeakPhysicalFootprintBytes": G2RecordingAcceptanceResult
                        .maximumPeakPhysicalFootprintBytes,
                    "maximumPhysicalFootprintGrowthBytes": G2RecordingAcceptanceResult
                        .maximumPhysicalFootprintGrowthBytes,
                    "maximumStopToPlayableMilliseconds": G2RecordingAcceptanceResult
                        .maximumStopToPlayableMilliseconds,
                    "maximumP95MainActorSchedulingDelayMilliseconds":
                        G2RecordingAcceptanceResult
                            .maximumP95MainActorSchedulingDelayMilliseconds,
                    "maximumMainActorSchedulingDelayMilliseconds":
                        G2RecordingAcceptanceResult
                            .maximumMainActorSchedulingDelayMilliseconds,
                    "minimumDistributedAudioWindowCount": G2RecordingAcceptanceResult
                        .requiredDistributedSampleCount(
                            for: configuration.durationSeconds,
                            shortCount: 5
                        ),
                    "minimumDistributedVideoSampleCount": G2RecordingAcceptanceResult
                        .requiredDistributedSampleCount(
                            for: configuration.durationSeconds,
                            shortCount: 6
                        ),
                    "minimumDistinctVideoFrameFraction": 0.5,
                    "minimumWrittenVideoFrameFraction": 0.98
                ],
                "privacy": "Only aggregate metrics are retained. The temporary raw recording is deleted after reporting."
            ]
            writeReport(report, to: configuration.reportURL)
            try? FileManager.default.removeItem(at: temporaryRoot)
            return passed ? 0 : 1
        } catch {
            toneGenerator.stop()
            visualStimulus.stop()
            if service.isRecording {
                _ = try? await service.stopForDiscard()
            }
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": "failed",
                "reason": stableFailureCode(error),
                "errorType": String(reflecting: type(of: error)),
                "errorDescription": error.localizedDescription,
                "requestedDurationSeconds": configuration.durationSeconds,
                "requestedFramesPerSecond": configuration.framesPerSecond,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - startedAt,
                "peakPhysicalFootprintBytes": memorySamples.max() ?? 0,
                "recoverableProjectWasCreated": saved != nil,
                "callerOwnedRecoveryRootPreserved": !ownsTemporaryRoot
            ], to: configuration.reportURL)
            if ownsTemporaryRoot {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
            return 1
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        let sizeStatus = name.withCString {
            sysctlbyname($0, nil, &size, nil, 0)
        }
        guard sizeStatus == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        let readStatus = name.withCString { namePointer in
            bytes.withUnsafeMutableBytes { destination in
                sysctlbyname(
                    namePointer,
                    destination.baseAddress,
                    &size,
                    nil,
                    0
                )
            }
        }
        guard readStatus == 0 else { return nil }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private static func percentile(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func physicalFootprintBytes() -> UInt64? {
        var information = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? information.ri_phys_footprint : nil
    }

    private static func stableFailureCode(_ error: Error) -> String {
        if error is ScreenRecordingError { return "screenRecordingFailed" }
        if error is TraceProjectStoreError { return "projectStorageFailed" }
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
                Data("Unable to write G2 recording stress report.\n".utf8)
            )
        }
    }
}

struct G2RecordingRecoveryConfiguration {
    let workRootURL: URL
    let reportURL: URL
    let expectedDurationSeconds: Double
    let fault: String
    let enforcesFragmentLossBoundary: Bool
    let requiresNewlyInterruptedCandidate: Bool

    init?(arguments: [String]) {
        guard arguments.contains("--g2-recording-recovery") else { return nil }
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        guard let workRoot = Self.option("--work-root", in: arguments) else {
            return nil
        }
        workRootURL = URL(fileURLWithPath: workRoot, relativeTo: workingDirectory)
            .standardizedFileURL
        let reportPath = Self.option("--report", in: arguments)
            ?? "Build/Quality/g2-recording-crash-recovery-latest.json"
        reportURL = URL(fileURLWithPath: reportPath, relativeTo: workingDirectory)
            .standardizedFileURL
        expectedDurationSeconds = max(
            Self.option("--expected-duration-seconds", in: arguments)
                .flatMap(Double.init) ?? 15,
            0
        )
        fault = Self.option("--fault", in: arguments) == "ENOSPC"
            ? "ENOSPC"
            : "SIGKILL"
        enforcesFragmentLossBoundary = !arguments.contains(
            "--allow-early-writer-failure"
        )
        requiresNewlyInterruptedCandidate = !arguments.contains(
            "--accept-already-interrupted"
        )
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
enum G2RecordingRecoveryRunner {
    static func run(_ configuration: G2RecordingRecoveryConfiguration) async -> Int32 {
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let store = TraceProjectStore(rootDirectory: configuration.workRootURL)
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: PointerEventRecorder()
        )
        do {
            let newlyInterrupted = store.recoverInterruptedRecordings()
            let candidates = store.interruptedRecordingCandidates()
            guard candidates.count == 1, let candidate = candidates.first else {
                throw G2RecordingRecoveryError.unexpectedCandidateCount(candidates.count)
            }
            let rawBytesBeforeRecovery = (try? FileManager.default.attributesOfItem(
                atPath: candidate.videoURL.path
            )[.size] as? NSNumber)?.uint64Value ?? 0
            let recoveryStartedAt = ProcessInfo.processInfo.systemUptime
            let saved = try await service.recoverInterruptedRecording(candidate)
            let recoveryMilliseconds = max(
                0,
                (ProcessInfo.processInfo.systemUptime - recoveryStartedAt) * 1_000
            )
            let asset = AVURLAsset(url: saved.rawAssetURL)
            let duration = try await asset.load(.duration).seconds
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioEvidence = await AudioMediaEvidenceAnalyzer.analyze(
                url: saved.rawAssetURL
            )
            let health = try? store.loadRecordingHealthReport(from: saved.packageURL)
            let loss = max(configuration.expectedDurationSeconds - duration, 0)
            let durationLossWithinBoundary = loss
                <= ScreenVideoTrackWriter.recoverySegmentIntervalSeconds + 1
            let candidateDiscoveryPassed = configuration
                .requiresNewlyInterruptedCandidate
                ? newlyInterrupted.count == 1
                : newlyInterrupted.count <= 1
            let passed = candidateDiscoveryPassed
                && candidates.count == 1
                && saved.manifest.state == .processing
                && !videoTracks.isEmpty
                && duration >= Self.minimumRecoverableDurationSeconds
                && (!configuration.enforcesFragmentLossBoundary
                    || durationLossWithinBoundary)
                && rawBytesBeforeRecovery > 0
                && health?.rawTrackIntegrity?.isVerified == true
                && (audioEvidence?.rootMeanSquare ?? 0) > 0.000_05
                && (audioEvidence?.minimumWindowRootMeanSquare ?? 0) > 0.000_05
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": passed ? "passed" : "failed",
                "evidenceLevel": evidenceLevel(
                    fault: configuration.fault
                ),
                "fault": configuration.fault,
                "newlyInterruptedCandidateCount": newlyInterrupted.count,
                "recoverableCandidateCount": candidates.count,
                "expectedDurationSeconds": configuration.expectedDurationSeconds,
                "recoveredDurationSeconds": duration,
                "maximumPossibleFragmentLossSeconds": loss,
                "recoveryMilliseconds": recoveryMilliseconds,
                "rawBytesBeforeRecovery": rawBytesBeforeRecovery,
                "systemAudioDurationSeconds": audioEvidence?.durationSeconds ?? 0,
                "systemAudioRMS": audioEvidence?.rootMeanSquare ?? 0,
                "minimumSystemAudioWindowRMS": audioEvidence?
                    .minimumWindowRootMeanSquare ?? 0,
                "systemAudioWindowRMS": audioEvidence?.windowRootMeanSquares ?? [],
                "manifestStateAfterRecovery": saved.manifest.state.rawValue,
                "checks": [
                    "candidateDiscoveryMatchedFaultMode":
                        candidateDiscoveryPassed,
                    "fragmentedMP4Playable": !videoTracks.isEmpty,
                    "fragmentLossBoundaryApplicable": configuration
                        .enforcesFragmentLossBoundary,
                    "durationLossWithinFragmentBoundary":
                        durationLossWithinBoundary,
                    "physicalTracksVerified": health?.rawTrackIntegrity?.isVerified == true,
                    "systemAudioNonSilent": (audioEvidence?.rootMeanSquare ?? 0) > 0.000_05,
                    "systemAudioContinuous": (audioEvidence?
                        .minimumWindowRootMeanSquare ?? 0) > 0.000_05,
                    "projectAdvancedToProcessing": saved.manifest.state == .processing
                ],
                "privacy": "Only aggregate recovery metrics are retained. Crash-test media is deleted after reporting."
            ], to: configuration.reportURL)
            try? FileManager.default.removeItem(at: configuration.workRootURL)
            return passed ? 0 : 1
        } catch {
            writeReport([
                "schemaVersion": 1,
                "generatedAt": generatedAt,
                "gate": "G2",
                "result": "failed",
                "fault": configuration.fault,
                "reason": stableFailureCode(error),
                "errorType": String(reflecting: type(of: error)),
                "errorDescription": error.localizedDescription,
                "callerOwnedRecoveryRootPreserved": true
            ], to: configuration.reportURL)
            return 1
        }
    }

    private static let minimumRecoverableDurationSeconds = 1.5

    private static func evidenceLevel(fault: String) -> String {
        let suffix = fault == "ENOSPC" ? "enospc" : "sigkill"
        return Bundle.main.bundleURL.standardizedFileURL.path
            .hasPrefix("/Applications/")
            ? "E4-installed-native-app-\(suffix)"
            : "E2-native-app-bundle-\(suffix)"
    }

    private static func stableFailureCode(_ error: Error) -> String {
        if case let G2RecordingRecoveryError.unexpectedCandidateCount(count) = error {
            return "unexpectedCandidateCount:\(count)"
        }
        if error is ScreenRecordingError { return "recordingRecoveryFailed" }
        if error is TraceProjectStoreError { return "projectRecoveryFailed" }
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
                Data("Unable to write G2 recovery report.\n".utf8)
            )
        }
    }
}

private enum G2RecordingRecoveryError: Error {
    case unexpectedCandidateCount(Int)
}

@MainActor
private final class G2EnduranceToneGenerator {
    private var process: Process?
    private var audioURL: URL?
    private var isActive = false
    private var startedAtUptime: TimeInterval?
    private var stoppedDurationSeconds: Double = 0

    var renderedDurationSeconds: Double {
        if let startedAtUptime, isActive {
            return max(0, ProcessInfo.processInfo.systemUptime - startedAtUptime)
        }
        return stoppedDurationSeconds
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenTrace-G2-tone-\(UUID().uuidString).caf"
        )
        try Self.writeToneFile(to: url)
        audioURL = url
        isActive = true
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        try launchPlayer()
    }

    func stop() {
        if let startedAtUptime {
            stoppedDurationSeconds = max(
                0,
                ProcessInfo.processInfo.systemUptime - startedAtUptime
            )
        }
        isActive = false
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        startedAtUptime = nil
    }

    private func launchPlayer() throws {
        guard isActive, let audioURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [audioURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                try? self.launchPlayer()
            }
        }
        try process.run()
        self.process = process
    }

    private nonisolated static func writeToneFile(to url: URL) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!
        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frameCount: AVAudioFrameCount = 48_000
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.003
            }
        }
        // Thirty seconds keeps disk usage small while making relaunch gaps
        // negligible even during the one-hour gate.
        for _ in 0..<30 {
            buffer.frameLength = frameCount
            try file.write(from: buffer)
        }
    }
}
