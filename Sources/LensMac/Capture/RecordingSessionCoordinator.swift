import AppKit
import Foundation
import LensCore

/// Explicit recording lifecycle so AppDelegate no longer infers phase from
/// `isRecording` plus a handful of boolean flags.
@MainActor
enum RecordingSessionPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
}

@MainActor
protocol RecordingSessionHost: AnyObject {
    func microphoneAccessGranted() async -> Bool
    func cameraAccessGranted() async -> Bool
    func showRecordingError(_ error: Error, phase: String)
    func logDiagnostic(
        _ code: String,
        level: DiagnosticLevel,
        metadata: [String: String]
    )
    func deliveryImage(for lens: SavedLens) -> NSImage
    func libraryEntry(for lens: SavedLens) -> LensLibraryEntry?
    func processRecording(_ saved: SavedLens) async -> AutoEditPlan?
    func trackProcessingTask(_ task: Task<Void, Never>, for packageURL: URL)
    func beginAutomaticTranscription(for saved: SavedLens)
    func startNextPendingAutomaticTranscriptionIfIdle()
}

/// Owns start / stop / pause / discard orchestration. AppDelegate remains the
/// host for permissions, diagnostics, and post-stop processing.
@MainActor
final class RecordingSessionCoordinator {
    struct StartPlan: Equatable, Sendable {
        let framesPerSecond: Int
        let capturesSystemAudio: Bool
        let capturesMicrophone: Bool
        let capturesCamera: Bool
        let experienceTitle: String
        let audioSummary: String
        let sourceTitle: String
        let toastTitle: String
        let toastDetail: String
    }

    private(set) var phase: RecordingSessionPhase = .idle

    var isIdle: Bool { phase == .idle }
    var isStarting: Bool { phase == .starting }
    var isRecording: Bool { phase == .recording }
    var isStopping: Bool { phase == .stopping }

    private var model: AppModel?
    private var store: LensProjectStore?
    private var recordingService: ScreenRecordingService?
    private var recordingControl: RecordingControlWindowController?
    private var recordingCountdown: RecordingCountdownWindowController?
    private var toast: ToastWindowController?
    private var permissionCenter: PermissionCenterWindowController?
    private var quickAccess: QuickAccessWindowController?
    private var lensLibrary: LensLibraryWindowController?
    private var videoEditor: VideoEditorWindowController?
    private weak var host: RecordingSessionHost?
    private let storageMonitor = RecordingStorageMonitor()

    func attach(
        model: AppModel,
        store: LensProjectStore,
        recordingService: ScreenRecordingService,
        recordingControl: RecordingControlWindowController,
        recordingCountdown: RecordingCountdownWindowController,
        toast: ToastWindowController,
        permissionCenter: PermissionCenterWindowController,
        quickAccess: QuickAccessWindowController,
        lensLibrary: LensLibraryWindowController,
        videoEditor: VideoEditorWindowController,
        host: RecordingSessionHost
    ) {
        self.model = model
        self.store = store
        self.recordingService = recordingService
        self.recordingControl = recordingControl
        self.recordingCountdown = recordingCountdown
        self.toast = toast
        self.permissionCenter = permissionCenter
        self.quickAccess = quickAccess
        self.lensLibrary = lensLibrary
        self.videoEditor = videoEditor
        self.host = host
        storageMonitor.onAvailableBytes = { [weak self] bytes in
            self?.recordingControl?.applyAvailableStorageBytes(bytes)
        }
        storageMonitor.onCriticalStorage = { [weak self] availableBytes in
            self?.stopForCriticalStorage(availableBytes)
        }
    }

    @discardableResult
    func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    func cancelStart() {
        if phase == .starting {
            phase = .idle
        }
    }

    func markRecording() {
        phase = .recording
    }

    func abortStop() {
        if phase == .stopping {
            phase = .recording
        }
    }

    @discardableResult
    func beginStop() -> Bool {
        guard phase == .recording else { return false }
        phase = .stopping
        return true
    }

    func markIdle() {
        phase = .idle
    }

    static func startPlan(
        source: RecordingCaptureSource,
        capturesCamera: Bool,
        experiencePreset: RecordingExperiencePreset,
        framesPerSecond: Int,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) -> StartPlan {
        let audioSummary: String
        switch (capturesSystemAudio, capturesMicrophone) {
        case (true, true): audioSummary = "系统声音 + 麦克风分轨"
        case (true, false): audioSummary = "系统声音"
        case (false, true): audioSummary = "麦克风分轨"
        case (false, false): audioSummary = "无音频"
        }
        let cameraNote = capturesCamera ? "摄像头分轨 · " : ""
        return StartPlan(
            framesPerSecond: framesPerSecond,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            capturesCamera: capturesCamera,
            experienceTitle: experiencePreset.title,
            audioSummary: audioSummary,
            sourceTitle: source.mode.presentationTitle,
            toastTitle: "正在准备\(source.mode.presentationTitle)",
            toastDetail: "\(experiencePreset.title) · \(framesPerSecond) FPS · \(audioSummary) · \(cameraNote)正在检查智能跟踪"
        )
    }

    func start(
        source: RecordingCaptureSource,
        capturesCamera: Bool = false
    ) {
        guard let model, let store, let recordingService, let recordingControl,
              let recordingCountdown, let toast, let permissionCenter else { return }
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return
        }
        guard !recordingService.isRecording else {
            recordingControl.showExisting()
            return
        }
        guard beginStart() else { return }
        let experiencePreset = model.recordingExperiencePreset
        let plan = Self.startPlan(
            source: source,
            capturesCamera: capturesCamera,
            experiencePreset: experiencePreset,
            framesPerSecond: model.recordingFrameRate.rawValue,
            capturesSystemAudio: model.capturesSystemAudio,
            capturesMicrophone: model.capturesMicrophone
        )
        let options = ScreenRecordingOptions(
            framesPerSecond: plan.framesPerSecond,
            capturesSystemAudio: plan.capturesSystemAudio,
            capturesMicrophone: plan.capturesMicrophone,
            capturesCamera: plan.capturesCamera,
            initialEditPlan: experiencePreset.makeEditPlan(
                includesCamera: capturesCamera,
                automaticZoomScale: model.automaticCameraZoomScale
            )
        )
        toast.show(
            title: plan.toastTitle,
            detail: plan.toastDetail,
            symbol: "record.circle"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { cancelStart() }
            if options.capturesMicrophone, !(await host?.microphoneAccessGranted() ?? false) {
                toast.show(
                    title: "麦克风尚未授权",
                    detail: "已打开权限中心；关闭麦克风后仍可继续录屏",
                    symbol: "mic.slash.fill"
                )
                permissionCenter.show()
                return
            }
            if options.capturesCamera, !(await host?.cameraAccessGranted() ?? false) {
                toast.show(
                    title: "摄像头尚未授权",
                    detail: "已打开权限中心；关闭摄像头后仍可继续录屏",
                    symbol: "video.slash.fill"
                )
                permissionCenter.show()
                return
            }
            let readyToRecord = await recordingCountdown.run(
                source: source,
                isEnabled: model.showsRecordingCountdown
            )
            guard readyToRecord else {
                toast.show(title: "已取消录制", symbol: "xmark.circle")
                return
            }
            do {
                _ = try await recordingService.start(source: source, options: options)
                markRecording()
                host?.logDiagnostic(
                    "recording.started",
                    level: .info,
                    metadata: [
                        "captureMode": source.mode.rawValue,
                        "frameRate": String(options.framesPerSecond),
                        "eventCaptureMode": recordingService.usesEmbeddedCursorFallback
                            ? "embeddedCursorFallback"
                            : "editableEventTracks"
                    ]
                )
                recordingControl.begin(
                    sourceTitle: "\(plan.sourceTitle) · \(plan.experienceTitle) · \(plan.framesPerSecond) FPS",
                    capturesSystemAudio: options.capturesSystemAudio,
                    capturesMicrophone: options.capturesMicrophone,
                    capturesCamera: options.capturesCamera,
                    levelProvider: { [weak self] in
                        self?.recordingService?.audioLevels ?? (0, 0)
                    },
                    eventCaptureHealthProvider: { [weak self] in
                        self?.recordingService?.eventCaptureSnapshot.health ?? .checking
                    },
                    capturePerformanceProvider: { [weak self] in
                        self?.recordingService?.capturePerformanceSnapshot
                    }
                )
                storageMonitor.start(storageURL: store.rootDirectory)
                if recordingService.usesEmbeddedCursorFallback {
                    toast.show(
                        title: "原始光标已保留",
                        detail: "输入监控当前不可用；本次不会伪造自动跟踪效果",
                        symbol: "cursorarrow.slash"
                    )
                }
            } catch {
                recordingControl.hide()
                endControlSession()
                host?.showRecordingError(error, phase: "start")
            }
        }
    }

    func handleUnexpectedCaptureStop(_ error: Error) {
        guard let recordingService, recordingService.isRecording else { return }
        host?.logDiagnostic(
            "recording.capture_stream_interrupted",
            level: .error,
            metadata: DiagnosticEvent.errorMetadata(error).merging(
                ["recovery": "automaticSafeFinalize"]
            ) { current, _ in current }
        )
        stop(
            startTitle: "录屏来源已中断，正在安全保存",
            startDetail: "已写入的屏幕、声音和事件分片会保留"
        )
    }

    func handleOptionalTrackInterruption(
        _ track: RecordingOptionalTrack,
        error: Error
    ) {
        guard let toast else { return }
        let title: String
        let detail: String
        let code: String
        switch track {
        case .microphone:
            title = "麦克风已断开，屏幕录制继续"
            detail = "结束后会保留断开前的有效声音"
            code = "recording.microphone_interrupted"
        case .camera:
            title = "摄像头已断开，屏幕录制继续"
            detail = "结束后会保留断开前的有效画面"
            code = "recording.camera_interrupted"
        }
        host?.logDiagnostic(
            code,
            level: .error,
            metadata: DiagnosticEvent.errorMetadata(error).merging(
                ["screenCapture": "continued"]
            ) { current, _ in current }
        )
        toast.show(title: title, detail: detail, symbol: "cable.connector.slash")
    }

    func stop(
        startTitle: String? = nil,
        startDetail: String? = nil
    ) {
        guard let model, let store, let recordingService, let recordingControl,
              let toast, let quickAccess, let lensLibrary, let videoEditor else { return }
        guard recordingService.isRecording else { return }
        guard beginStop() else { return }
        recordingControl.beginFinalizing()
        let stopRequestedAt = ProcessInfo.processInfo.systemUptime
        toast.show(
            title: startTitle ?? "正在保存录屏",
            detail: startDetail ?? "分片写入完成后即可打开原片",
            symbol: "hourglass"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let saved = try await recordingService.stop()
                let recordingControlWindow = recordingControl.currentWindow
                recordingControl.prepareForHandoff()
                endControlSession()
                markIdle()
                host?.startNextPendingAutomaticTranscriptionIfIdle()
                let healthReport = recordingService.lastRecordingHealthReport
                    ?? loadHealthReport(from: saved.packageURL)
                var stopMetadata = [
                    "status": "saved",
                    "durationMilliseconds": Self.performanceMilliseconds(
                        since: stopRequestedAt
                    )
                ]
                if let measured = healthReport?.measuredFramesPerSecond {
                    stopMetadata["measuredFrameRate"] = String(format: "%.2f", measured)
                }
                if let healthReport {
                    stopMetadata["videoStatus"] = healthReport.videoStatus.rawValue
                    stopMetadata["eventStatus"] = healthReport.eventStatus.rawValue
                }
                host?.logDiagnostic("recording.stopped", level: .info, metadata: stopMetadata)
                let shouldAutomaticallyTranscribe = model.automaticallyTranscribesRecordings
                    && saved.manifest.assets.contains {
                        $0.role == .microphone || $0.role == .systemAudio
                    }
                var completionNotes = [
                    recordingService.lastMicrophoneError == nil ? nil : "麦克风轨道异常",
                    recordingService.lastCameraError == nil ? nil : "摄像头轨道异常"
                ].compactMap { $0 }
                if let healthReport,
                   healthReport.videoStatus == .degraded,
                   let measured = healthReport.measuredFramesPerSecond {
                    completionNotes.append(String(format: "实测 %.1f FPS", measured))
                }
                if healthReport?.eventStatus == .degraded {
                    completionNotes.append("智能跟踪已降级")
                }
                if recordingService.lastCaptureInterruptionError != nil {
                    completionNotes.append("录屏来源中断，已保留中断前原片")
                }
                if let integrity = healthReport?.rawTrackIntegrity {
                    if !integrity.missingRequestedTracks.isEmpty {
                        completionNotes.append(
                            "\(integrity.missingRequestedTracks.map(\.title).joined(separator: "、"))原始轨缺失"
                        )
                    }
                    if !integrity.outOfSyncTracks.isEmpty {
                        completionNotes.append(
                            "\(integrity.outOfSyncTracks.map(\.title).joined(separator: "、"))时长偏差超过 150ms"
                        )
                    }
                    if !integrity.startOffsetTracks.isEmpty {
                        completionNotes.append(
                            "\(integrity.startOffsetTracks.map(\.title).joined(separator: "、"))起点偏移超过 150ms"
                        )
                    }
                }
                let image = host?.deliveryImage(for: saved)
                    ?? NSWorkspace.shared.icon(forFile: saved.rawAssetURL.path)
                quickAccess.show(
                    lens: saved,
                    image: image,
                    confirmationTitle: "原始录屏已保存 · 成片生成中",
                    deliveryState: .processing,
                    handoffFrom: recordingControlWindow
                )
                if !completionNotes.isEmpty {
                    toast.show(
                        title: "录屏已保存",
                        detail: completionNotes.joined(separator: "、"),
                        symbol: "exclamationmark.triangle.fill"
                    )
                }
                lensLibrary.reloadIfVisible()
                let captionsEnabledBeforeTranscription: Bool = {
                    guard shouldAutomaticallyTranscribe,
                          let plan = try? store.loadAutoEditPlan(from: saved.packageURL) else {
                        return false
                    }
                    return plan.captions?.isEnabled == true
                }()
                // A teaching recording needs its transcript before captions
                // are rendered. Starting the speech phase first avoids an
                // unnecessary encode that would immediately be discarded and
                // keeps the pipeline at one final video pass.
                if captionsEnabledBeforeTranscription {
                    host?.beginAutomaticTranscription(for: saved)
                    return
                }
                let processing = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let renderedPlan = await host?.processRecording(saved)
                    if let renderedPlan,
                       let entry = host?.libraryEntry(for: saved) {
                        _ = videoEditor.adoptBackgroundPreview(
                            entry: entry,
                            renderedPlan: renderedPlan
                        )
                    }
                    if shouldAutomaticallyTranscribe {
                        host?.beginAutomaticTranscription(for: saved)
                    }
                    host?.startNextPendingAutomaticTranscriptionIfIdle()
                }
                host?.trackProcessingTask(processing, for: saved.packageURL)
            } catch {
                if recordingService.isRecording {
                    abortStop()
                    recordingControl.setTransitioning(false)
                    recordingControl.showExisting()
                } else {
                    recordingControl.hide()
                    endControlSession()
                    markIdle()
                    host?.startNextPendingAutomaticTranscriptionIfIdle()
                }
                host?.showRecordingError(error, phase: "stop")
            }
        }
    }

    func togglePause() {
        guard let recordingService, let recordingControl, let toast else { return }
        guard recordingService.isRecording else { return }
        let shouldPause = !recordingService.isPaused
        recordingControl.setTransitioning(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { recordingControl.setTransitioning(false) }
            do {
                if shouldPause {
                    try await recordingService.pause()
                    host?.logDiagnostic("recording.paused", level: .info, metadata: [:])
                    recordingControl.setPaused(true)
                    toast.show(
                        title: "录制已暂停",
                        detail: "当前分片已安全写盘；继续时会创建新分片",
                        symbol: "pause.circle.fill"
                    )
                } else {
                    try await recordingService.resume()
                    host?.logDiagnostic("recording.resumed", level: .info, metadata: [:])
                    recordingControl.setPaused(false)
                    toast.show(
                        title: "继续录制",
                        detail: "时间轴会自动跳过暂停区间",
                        symbol: "play.circle.fill"
                    )
                }
            } catch {
                recordingControl.setPaused(recordingService.isPaused)
                host?.showRecordingError(error, phase: shouldPause ? "pause" : "resume")
            }
        }
    }

    func requestDiscardAndRestart() {
        guard let recordingService, let recordingControl, let toast, let lensLibrary else { return }
        guard recordingService.isRecording else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "丢弃并重新录制？"
        alert.informativeText = "Lens 会先安全停止当前录制，再把整个项目移入废纸篓。文件不会被永久删除。"
        alert.addButton(withTitle: "移到废纸篓并重录")
        alert.addButton(withTitle: "继续录制")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        recordingControl.setTransitioning(true)
        guard beginStop() else {
            recordingControl.setTransitioning(false)
            return
        }
        toast.show(
            title: "正在安全丢弃当前录制",
            detail: "完成所有媒体分片后会移入废纸篓",
            symbol: "trash.circle"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let discarded = try await recordingService.stopForDiscard()
                recordingControl.hide()
                endControlSession()
                markIdle()
                try FileManager.default.trashItem(
                    at: discarded.packageURL,
                    resultingItemURL: nil
                )
                lensLibrary.reloadIfVisible()
                toast.show(
                    title: "旧录制已移到废纸篓",
                    detail: "正在按相同来源重新准备录制",
                    symbol: "arrow.counterclockwise.circle.fill"
                )
                start(source: discarded.source)
            } catch {
                host?.logDiagnostic(
                    "recording.discard_restart_failed",
                    level: .error,
                    metadata: DiagnosticEvent.errorMetadata(error).merging(
                        ["phase": "discard"]
                    ) { current, _ in current }
                )
                recordingControl.hide()
                endControlSession()
                markIdle()
                lensLibrary.reloadIfVisible()
                toast.show(
                    title: "没有删除录制项目",
                    detail: "录制已停止并尽量保留为可恢复项目：\(error.localizedDescription)",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath"
                )
            }
        }
    }

    private func endControlSession() {
        recordingControl?.endSession()
        storageMonitor.stop()
    }

    private func stopForCriticalStorage(_ availableBytes: Int64?) {
        guard let recordingService, recordingService.isRecording else { return }
        host?.logDiagnostic(
            "storage.critical",
            level: .error,
            metadata: ["storageLevel": "critical"]
        )
        let remaining = availableBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "不足 1 GB"
        recordingControl?.hide()
        stop(
            startTitle: "磁盘空间不足，正在安全停止",
            startDetail: "当前可用 \(remaining)；已写入的媒体分片会继续保留"
        )
    }

    private func loadHealthReport(from packageURL: URL) -> RecordingHealthReport? {
        guard let store else { return nil }
        do {
            return try store.loadRecordingHealthReport(from: packageURL)
        } catch {
            host?.logDiagnostic(
                "recording.health_report_load_failed",
                level: .error,
                metadata: DiagnosticEvent.errorMetadata(error)
            )
            return nil
        }
    }

    private static func performanceMilliseconds(since startedAt: TimeInterval) -> String {
        String(format: "%.3f", max(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            0
        ))
    }
}

extension RecordingCaptureMode {
    var presentationTitle: String {
        switch self {
        case .region: "区域录制"
        case .window: "窗口录制"
        case .display: "屏幕录制"
        }
    }
}
