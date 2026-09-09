import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import LensCore

private struct RecordingRecoveryScan: Sendable {
    let interrupted: [RecordingRecoveryCandidate]
    let pendingProcessing: [SavedLens]
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let buildIdentity = BuildIdentity.current
    private let model = AppModel()
    private let store = LensProjectStore(
        rootDirectory: AppModel.storedLensStorageRootDirectory()
    )
    private let quickAccess = QuickAccessWindowController()
    private let pinnedImages = PinnedImageWindowController()
    private let ocrResults = OCRResultWindowController()
    private let pointerRecorder = PointerEventRecorder()
    private let recordingControl = RecordingControlWindowController()
    private let recordingCountdown = RecordingCountdownWindowController()
    private let previewRenderer = AutoPreviewRenderer()
    private let audioMixdownRenderer = AudioMixdownRenderer()
    private lazy var renderedEffectVerifier = RenderedEffectVerifier(
        renderer: previewRenderer
    )
    private let transcriptionService = LocalSpeechTranscriptionService()
    private let toast = ToastWindowController()
    private let diagnostics = LocalDiagnosticLog()
    private let launchHealth = LaunchHealthMonitor()
    private let crashReportScanner = LensCrashReportScanner()
    private lazy var instanceCoordinator = ApplicationInstanceCoordinator(
        currentIdentity: buildIdentity
    )
    private lazy var permissionCenter = PermissionCenterWindowController(
        appModel: model,
        onShortcutsChanged: { [weak self] in self?.restartHotKeys() },
        onShortcutCaptureActiveChange: { [weak self] active in
            self?.setShortcutCaptureActive(active)
        },
        onManageStorage: { [weak self] in
            self?.manageLensStorage()
        },
        onCancelStorageMigration: { [weak self] in
            self?.cancelLensStorageMigration()
        },
        activityStateProvider: { [weak self] in
            self?.currentLensUpdateActivityState ?? LensUpdateActivityState()
        },
        diagnosticSummaryProvider: { [weak self] in
            await self?.makeDiagnosticSummary() ?? "Lens 诊断摘要\n应用尚未完成启动。"
        }
    )
    private lazy var onboarding = OnboardingWindowController(
        appModel: model,
        onQuitRequested: { NSApp.terminate(nil) },
        onFinished: { [weak self] in self?.actionCenter.show() }
    )
    private lazy var annotationEditor = ScreenshotAnnotationEditorWindowController(
        store: store,
        onStorageActivityChanged: { [weak self] in
            self?.startPendingLensStorageMigrationIfReady()
        }
    )
    private lazy var lensLibrary = LensLibraryWindowController(
        store: store,
        onStorageActivityChanged: { [weak self] in
            self?.startPendingLensStorageMigrationIfReady()
        }
    )
    private lazy var videoEditor = VideoEditorWindowController(
        store: store,
        onStorageActivityChanged: { [weak self] in
            self?.startPendingLensStorageMigrationIfReady()
        }
    )

    private var currentLensUpdateActivityState: LensUpdateActivityState {
        LensUpdateActivityState(
            isRecording: recordingSession.isRecording || recordingService.isRecording,
            isRendering: !recordingRenderTaskRegistry.activePackageURLs.isEmpty
                || videoEditor.isProcessing,
            hasUnsavedEdits: videoEditor.hasUnsavedEdits
        )
    }

    private lazy var captureCoordinator = CaptureCoordinator(
        store: store,
        model: model,
        quickAccess: quickAccess,
        onLensChanged: { [weak self] in
            self?.lensLibrary.reloadIfVisible()
            self?.startPendingLensStorageMigrationIfReady()
        },
        onRecordingSourceSelected: { [weak self] source, capturesCamera in
            self?.startRecording(source: source, capturesCamera: capturesCamera)
        },
        onOCRStarted: { [weak self] lens, thumbnail in
            // The waiting card must use the in-memory bitmap from this capture.
            // Reading the PNG back from disk stalls the floating panel on retina shots.
            self?.ocrResults.beginRecognizing(
                lensID: lens.manifest.id,
                thumbnail: thumbnail
            )
        },
        onOCRCompleted: { [weak self] document, lens in
            self?.handleOCRCompleted(document, lens: lens)
        },
        onAutomaticOCRCompleted: { [weak self] document, lens in
            self?.beginOrganization(lens: lens, ocr: document)
        },
        onOCRFailed: { [weak self] error, lens in
            self?.handleOCRFailed(error, lens: lens)
        },
        onScrollingCaptureCompleted: { [weak self] frameCount, height, warning in
            self?.handleScrollingCaptureCompleted(
                frameCount: frameCount,
                height: height,
                warning: warning
            )
        },
        onScrollingCaptureFailed: { [weak self] error in
            self?.logDiagnosticFailure("scrolling_capture.failed", error: error)
            self?.toast.show(
                title: "长截图未完成",
                detail: StorageRecoveryGuidance.detail(for: error),
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        },
        onConversationInboxSaved: { [weak self] snapshot, copied in
            self?.showConversationInboxFeedback(snapshot: snapshot, copied: copied)
        },
        onPerformanceMeasured: { [weak self] code, metadata in
            self?.logDiagnostic(code, metadata: metadata)
        },
        onCaptureFailed: { [weak self] message in
            self?.toast.show(
                title: "Lens 无法完成截图",
                detail: message,
                symbol: "exclamationmark.triangle.fill"
            )
        },
        onMagnifierHexCopied: { [weak self] hex in
            self?.toast.show(title: "已复制 \(hex)", symbol: "eyedropper")
        },
        storageWritesAllowed: { [weak self] in
            self?.storageWritesAllowed ?? true
        }
    )
    private lazy var recordingService: ScreenRecordingService = {
        let service = ScreenRecordingService(
            store: store,
            pointerRecorder: pointerRecorder
        )
        service.onUnexpectedCaptureStop = { [weak self] error in
            self?.handleUnexpectedCaptureStop(error)
        }
        service.onOptionalTrackInterruption = { [weak self] track, error in
            self?.handleOptionalTrackInterruption(track, error: error)
        }
        return service
    }()
    private lazy var actionCenter = ActionCenterWindowController(model: model) { [weak self] action in
        self?.handle(action)
    }
    private lazy var recordingSetup = RecordingSetupWindowController(model: model) {
        [weak self] request in
        guard let self else { return }
        let capturesCamera = model.capturesCamera
        model.capturesCamera = false
        switch request {
        case .action(.recording):
            startDisplayRecording(capturesCamera: capturesCamera)
        case .action(.regionRecording):
            captureCoordinator.beginRegionRecordingSelection(capturesCamera: capturesCamera)
        case let .action(action):
            handle(action)
        case let .source(source):
            startRecording(source: source, capturesCamera: capturesCamera)
        }
    }
    private var hotKeyManager: GlobalHotKeyManager?
    private var hotKeysBlockedByAccessibility = false
    private var suspendHotKeysForShortcutCapture = false
    private var shortcutCaptureDepth = 0
    private let recordingTaskCoordinator = RecordingTaskCoordinator()
    private let recordingContentTaskRegistry = RecordingContentTaskRegistry()
    private let pendingAutomaticTranscriptions = RecordingContentTaskQueue()
    private var launchHealthSessionStarted = false
    private var didCompleteApplicationLaunch = false
    private let recordingSession = RecordingSessionCoordinator()
    private let recordingProcessingTaskRegistry = RecordingProcessingTaskRegistry()
    private let recordingRenderTaskRegistry = RecordingRenderTaskRegistry()
    private lazy var recordingContentTaskExecution = RecordingContentTaskExecution(
        coordinator: recordingTaskCoordinator
    )
    private lazy var recordingRenderPipeline = makeRecordingRenderPipeline()
    private lazy var recordingRenderExecution = makeRecordingRenderExecution()
    private lazy var recordingRenderPresentation = makeRecordingRenderPresentation()
    private lazy var recordingContentTaskPresentation = makeRecordingContentTaskPresentation()
    private lazy var recordingTaskMetricsReporter = makeRecordingTaskMetricsReporter()
    private lazy var recordingContentTaskFinalizer = makeRecordingContentTaskFinalizer()
    private lazy var recordingOrganizationTaskCoordinator =
        makeRecordingOrganizationTaskCoordinator()
    private lazy var recordingTranscriptionTaskCoordinator =
        makeRecordingTranscriptionTaskCoordinator()
    private lazy var recordingRenderTaskCoordinator =
        makeRecordingRenderTaskCoordinator()
    private let storageMigrationQueue = LensStorageMigrationQueue()
    private var storageMigrationTask: Task<Void, Never>?
    private var cancelStorageMigrationWorker: (() -> Void)?

    /// Once a migration has started, every new package-producing entry point
    /// must stop admitting work. Existing work is drained before the queue
    /// starts; the app exits after publish so all stores are rebound together
    /// on the next launch.
    private var storageWritesAllowed: Bool {
        !storageMigrationQueue.isRunning && storageMigrationTask == nil
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        switch instanceCoordinator.resolveLaunch() {
        case .continueLaunch:
            completeApplicationLaunch()
        case .terminateCurrent:
            NSApp.terminate(nil)
        case let .waitForOtherApplicationToTerminate(application):
            waitForOtherApplicationToTerminate(application)
        }
    }

    private func completeApplicationLaunch() {
        guard !didCompleteApplicationLaunch else { return }
        didCompleteApplicationLaunch = true
        let recoveryCutoff = Date()
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Lens remains ready in the menu bar.")
        let version = appVersionMetadata
        let previousSessionWasUnclean = launchHealth.beginSession(
            appVersion: version["appVersion"] ?? "development",
            build: version["build"] ?? "development"
        )
        launchHealthSessionStarted = true
        configureApplicationMenu()
        configureStatusItem()
        wireControllers()
        resumePendingAutomaticTranscriptions()
        startHotKeys()
        // The shipped shortcuts are modifier-only, so they are delivered by a
        // global event monitor that stays silent until accessibility is
        // granted. A first run that opened straight into the action center
        // left the primary way into the app looking broken.
        if onboarding.shouldPresentOnLaunch {
            onboarding.show()
            logDiagnostic("onboarding.presented", metadata: ["reason": "first_launch"])
        }
        restoreRecentScreenshot()
        scheduleRecordingRecovery(startedBefore: recoveryCutoff)
        logDiagnostic("app.launched", metadata: version)
        if previousSessionWasUnclean {
            logDiagnostic(
                "app.previous_session_unclean",
                level: .warning,
                metadata: ["status": "detected"]
            )
        }
        let crashReports = crashReportScanner.recentReports()
        if !crashReports.isEmpty {
            logDiagnostic(
                "crash_reports.available",
                level: .warning,
                metadata: ["count": String(crashReports.count)]
            )
        }
    }

    private func waitForOtherApplicationToTerminate(_ application: NSRunningApplication) {
        Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard let self else { return }
                if application.isTerminated {
                    completeApplicationLaunch()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }

            application.activate(options: [.activateAllWindows])
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "正在运行的 Lens 尚未退出"
            alert.informativeText = "请先停止该版本中的录屏并正常退出，然后重新打开当前版本。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if launchHealthSessionStarted {
            launchHealth.completeSession()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Permissions are granted over in System Settings and TCC sends no change
    /// notification, so the guide rechecks whenever the user comes back.
    public func applicationDidBecomeActive(_ notification: Notification) {
        guard didCompleteApplicationLaunch else { return }
        onboarding.refresh()
        if hotKeysBlockedByAccessibility, AXIsProcessTrusted() {
            restartHotKeys()
        }
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if didCompleteApplicationLaunch {
            actionCenter.show()
        }
        return true
    }

    private func restoreRecentScreenshot() {
        let store = store
        Task { @MainActor [weak self] in
            let entry = await Task.detached(priority: .utility) {
                store.libraryEntries().first {
                    $0.manifest.kind == .screenshot
                        && $0.manifest.state == .ready
                        && FileManager.default.fileExists(atPath: $0.displayAssetURL.path)
                }
            }.value
            guard let entry else { return }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: entry.displayAssetURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled,
                  let self,
                  let data,
                  let image = NSImage(data: data) else { return }
            model.restoreRecentLensIfAbsent(entry, thumbnail: image)
        }
    }

    private func wireControllers() {
        recordingSession.attach(
            model: model,
            store: store,
            recordingService: recordingService,
            recordingControl: recordingControl,
            recordingCountdown: recordingCountdown,
            toast: toast,
            permissionCenter: permissionCenter,
            quickAccess: quickAccess,
            lensLibrary: lensLibrary,
            videoEditor: videoEditor,
            host: self
        )
        videoEditor.onCancelBackgroundProcessing = { [weak self] packageURL in
            self?.cancelRecordingProcessing(for: packageURL)
        }
        quickAccess.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        pinnedImages.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        ocrResults.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0, prefix: "OCR")
        }
        quickAccess.onPinRequested = { [weak self] lens, image in
            self?.pinnedImages.pin(lens: lens, image: image)
            self?.toast.show(
                title: "已贴在桌面",
                detail: "拖动可挪位置，滚轮缩放，Option + 滚轮调透明",
                symbol: "pin.fill"
            )
        }
        quickAccess.onAnnotateRequested = { [weak self] lens, image in
            self?.annotationEditor.show(lens: lens, fallbackImage: image)
        }
        quickAccess.onEditRequested = { [weak self] lens in
            guard let entry = self?.libraryEntry(for: lens) else { return }
            self?.videoEditor.show(entry: entry)
        }
        quickAccess.onConversationInboxRequested = { [weak self] pngData in
            self?.exportPNGToConversationInbox(pngData)
        }
        quickAccess.onRetryRequested = { [weak self] lens in
            guard let self else { return }
            quickAccess.show(
                lens: lens,
                image: deliveryImage(for: lens),
                confirmationTitle: "原始录屏已保存 · 成片生成中",
                deliveryState: .processing
            )
            let retry = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await processRecording(lens)
            }
            trackProcessingTask(retry, for: lens.packageURL)
        }
        annotationEditor.onSaved = { [weak self] lens, image, clipboardStatus in
            guard let self else { return }
            model.setRecentLens(lens, thumbnail: image)
            lensLibrary.reloadIfVisible()
            switch clipboardStatus {
            case .copied:
                quickAccess.show(
                    lens: lens,
                    image: image,
                    confirmationTitle: "标注已保存并复制"
                )
                showClipboardFeedback(succeeded: true, prefix: "标注已保存")
            case .copyFailed:
                quickAccess.show(
                    lens: lens,
                    image: image,
                    confirmationTitle: "标注已保存"
                )
                showClipboardFeedback(succeeded: false, prefix: "标注已保存")
            case .notRequested:
                quickAccess.show(
                    lens: lens,
                    image: image,
                    confirmationTitle: "标注已保存"
                )
                toast.show(
                    title: "标注已保存",
                    detail: "导出文件已生成，对象与原图仍可继续修改",
                    symbol: "checkmark.circle.fill"
                )
            }
        }
        annotationEditor.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        annotationEditor.onFailure = { [weak self] error in
            self?.toast.show(
                title: "原图与标注计划仍然安全",
                detail: StorageRecoveryGuidance.detail(for: error),
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
        recordingControl.onStop = { [weak self] in
            self?.recordingSession.stop()
        }
        recordingControl.onPauseToggle = { [weak self] in
            self?.recordingSession.togglePause()
        }
        recordingControl.onDiscardAndRestart = { [weak self] in
            self?.recordingSession.requestDiscardAndRestart()
        }
        recordingControl.onHide = { [weak self] in
            guard let self else { return }
            logDiagnostic("recording.control_hidden")
            toast.show(
                title: "录屏浮标已隐藏",
                detail: "录制仍在继续；按 \(model.actionCenterShortcut.displayName) 或从菜单栏恢复",
                symbol: "eye.slash.fill"
            )
        }
        recordingControl.onVisibilityChange = { [weak self] _ in
            self?.configureStatusItem()
        }
        lensLibrary.onAnnotateRequested = { [weak self] lens, image in
            self?.annotationEditor.show(lens: lens, fallbackImage: image)
        }
        lensLibrary.onOCRRequested = { [weak self] entry in
            self?.showOCRResult(for: entry)
        }
        lensLibrary.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        lensLibrary.onStartCapture = { [weak self] in
            guard let self else { return }
            lensLibrary.hide()
            actionCenter.show()
        }
        lensLibrary.onEditRecordingRequested = { [weak self] entry in
            self?.videoEditor.show(entry: entry)
        }
        lensLibrary.onTranscriptionRequested = { [weak self] entry in
            self?.beginTranscription(for: entry)
        }
        lensLibrary.onOrganizationRequested = { [weak self] entry in
            self?.beginOrganization(for: entry)
        }
        lensLibrary.onInsightsCustomizationRequested = { [weak self] entry, customization in
            self?.saveInsightsCustomization(for: entry, customization: customization)
        }
        lensLibrary.onRecordingRepaired = { [weak self] entry, rebuilt in
            self?.completeRecordingRepair(entry, rebuilt: rebuilt)
        }
        videoEditor.onSaved = { [weak self] saved in
            guard let self else { return }
            lensLibrary.reloadIfVisible()
            toast.show(
                title: "编辑方案已保存",
                detail: "正在按新时间线和效果重新生成预览；原始轨道保持不变",
                symbol: "timeline.selection"
            )
            await processRecording(saved)
        }
        videoEditor.onFailure = { [weak self] error in
            self?.toast.show(
                title: "编辑方案未保存",
                detail: StorageRecoveryGuidance.detail(for: error),
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
    }

    private func showClipboardFeedback(
        succeeded: Bool,
        prefix: String? = nil
    ) {
        if succeeded {
            toast.show(
                title: prefix.map { "\($0)·已复制到剪贴板" }
                    ?? "已复制到剪贴板",
                detail: "可在目标 App 中按 Command-V 粘贴",
                symbol: "doc.on.clipboard.fill"
            )
        } else {
            toast.show(
                title: prefix.map { "\($0)·复制未完成" }
                    ?? "复制未完成",
                detail: "请再试一次；原图和标注仍安全保留",
                symbol: "exclamationmark.triangle.fill"
            )
        }
    }

    private func exportPNGToConversationInbox(_ pngData: Data) {
        do {
            try captureCoordinator.exportPNGToConversationInbox(pngData)
        } catch {
            logDiagnosticFailure("conversation_inbox.failed", error: error)
            toast.show(
                title: "对话文件夹未保存",
                detail: StorageRecoveryGuidance.detail(for: error),
                symbol: "exclamationmark.triangle.fill"
            )
        }
    }

    private func showConversationInboxFeedback(
        snapshot: ConversationInboxSnapshot,
        copied: Bool
    ) {
        toast.show(
            title: copied ? "路径已复制" : "已存到对话文件夹",
            detail: snapshot.latestURL.path,
            symbol: "terminal"
        )
    }

    private func scheduleRecordingRecovery(startedBefore cutoff: Date) {
        let store = store
        Task { @MainActor [weak self] in
            let scan = await Task.detached(priority: .utility) {
                _ = store.recoverInterruptedRecordings(startedBefore: cutoff)
                return RecordingRecoveryScan(
                    interrupted: store.interruptedRecordingCandidates(
                        startedBefore: cutoff
                    ),
                    pendingProcessing: store.recordingsPendingProcessing(
                        startedBefore: cutoff
                    )
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            await resumeRecordingRecovery(scan)
        }
    }

    private func resumePendingAutomaticTranscriptions() {
        let discarded = pendingAutomaticTranscriptions.discardExhaustedRecords()
        if discarded > 0 {
            logDiagnostic(
                "transcription.queue_retry_limit_reached",
                level: .warning,
                metadata: ["count": String(discarded)]
            )
        }

        var resumed = 0
        for record in pendingAutomaticTranscriptions.recoverableRecords {
            do {
                let manifest = try store.loadManifest(from: record.packageURL)
                guard let primaryAsset = manifest.assets.first(where: { $0.role == .screenVideo }) else {
                    pendingAutomaticTranscriptions.complete(lensID: record.lensID)
                    continue
                }
                let saved = SavedLens(
                    packageURL: record.packageURL,
                    rawAssetURL: record.packageURL.appendingPathComponent(primaryAsset.relativePath),
                    manifest: manifest
                )
                guard let entry = libraryEntry(for: saved),
                      pendingAutomaticTranscriptions.restore(entry) else {
                    pendingAutomaticTranscriptions.complete(lensID: record.lensID)
                    continue
                }
                resumed += 1
            } catch {
                pendingAutomaticTranscriptions.complete(lensID: record.lensID)
                logDiagnosticFailure(
                    "transcription.queue_resume_failed",
                    error: error,
                    metadata: ["lensID": record.lensID.uuidString]
                )
            }
        }
        if resumed > 0 {
            logDiagnostic(
                "transcription.queue_resumed",
                metadata: ["count": String(resumed)]
            )
        }
        startNextPendingAutomaticTranscriptionIfIdle()
    }

    func startNextPendingAutomaticTranscriptionIfIdle() {
        guard !recordingSession.isRecording,
              recordingContentTaskRegistry.count(kind: .transcription)
                < RecordingTaskSchedulingPolicy.maximumConcurrentTranscriptions,
              let next = pendingAutomaticTranscriptions.dequeue() else {
            return
        }
        beginTranscription(for: next, automatic: true)
    }

    private func resumeRecordingRecovery(_ scan: RecordingRecoveryScan) async {
        let store = self.store
        let recovered = scan.interrupted
        let pendingProcessing = scan.pendingProcessing
        guard !recovered.isEmpty || !pendingProcessing.isEmpty else {
            resumePendingLensStorageMigrationIfNeeded()
            return
        }
        if !recovered.isEmpty {
            logDiagnostic(
                "recording.recovery_detected",
                level: .warning,
                metadata: ["count": String(recovered.count)]
            )
        }
        if !pendingProcessing.isEmpty {
            logDiagnostic(
                "recording.processing_resume_detected",
                level: .warning,
                metadata: ["count": String(pendingProcessing.count)]
            )
        }
        if !recovered.isEmpty {
            toast.show(
                title: "正在恢复 \(recovered.count) 条中断录屏",
                detail: "正在校验原始分片并生成可编辑预览",
                symbol: "arrow.counterclockwise.circle.fill"
            )
        }
        var completedCount = 0
        for candidate in recovered {
            do {
                let saved = try await recordingService.recoverInterruptedRecording(candidate)
                completedCount += 1
                await processRecording(saved)
            } catch {
                logDiagnosticFailure(
                    "recording.recovery_failed",
                    error: error,
                    metadata: ["phase": "interrupted"]
                )
            }
        }
        for saved in pendingProcessing {
            let outputURL = saved.packageURL.appendingPathComponent("previews/auto.mp4")
            do {
                let outputSize = await Task.detached(priority: .utility) {
                    (try? FileManager.default.attributesOfItem(
                        atPath: outputURL.path
                    )[.size] as? NSNumber)?.int64Value ?? 0
                }.value
                if outputSize > 0 {
                    _ = try await Task.detached(priority: .utility) {
                        try store.completeProcessing(
                            packageURL: saved.packageURL,
                            renderedVideoURL: outputURL
                        )
                    }.value
                    lensLibrary.reloadIfVisible()
                } else {
                    await processRecording(saved)
                }
            } catch {
                logDiagnosticFailure(
                    "recording.processing_resume_failed",
                    error: error,
                    metadata: ["phase": "processing"]
                )
            }
        }
        lensLibrary.reloadIfVisible()
        if !recovered.isEmpty, completedCount == recovered.count {
            toast.show(
                title: "中断录屏已恢复",
                detail: "\(completedCount) 条原始录屏已恢复为可编辑项目",
                symbol: "checkmark.circle.fill"
            )
        } else if !recovered.isEmpty {
            toast.show(
                title: "部分中断录屏仍需保留",
                detail: "已恢复 \(completedCount) 条；无法校验的原始分片没有被删除",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
        resumePendingLensStorageMigrationIfNeeded()
    }

    private func startHotKeys() {
        let manager = GlobalHotKeyManager(configuration: model.hotKeyConfiguration) { [weak self] intent in
            switch intent {
            case .quickScreenshot:
                self?.actionCenter.hide()
                self?.captureCoordinator.beginRegionCapture()
            case .conversationInbox:
                self?.actionCenter.hide()
                self?.captureCoordinator.beginConversationInboxCapture()
            case .stopRecording:
                self?.stopRecordingFromMenu()
            case .toggleActionCenter:
                if self?.recordingService.isRecording == true {
                    self?.recordingControl.showExisting()
                } else if self?.captureCoordinator.showScrollingCaptureControlIfActive() == true {
                    return
                } else {
                    self?.actionCenter.toggle()
                }
            }
        }
        let report = manager.start()
        hotKeyManager = manager
        applyHotKeySuspension()
        hotKeysBlockedByAccessibility = !AXIsProcessTrusted()
        if hotKeysBlockedByAccessibility {
            return
        }
        if !report.issues.isEmpty {
            logDiagnostic(
                "hotkey.registration_fallback",
                level: .warning,
                metadata: ["count": String(report.issues.count)]
            )
            toast.show(
                title: "部分主快捷键被占用",
                detail: "Lens 已启用事件监听回退；Control + Option + 1/2/3/4 备用组合仍会尝试保持可用",
                symbol: "keyboard.badge.ellipsis"
            )
        }
    }

    private func restartHotKeys() {
        hotKeyManager?.stop()
        hotKeyManager = nil
        startHotKeys()
        configureStatusItem()
    }

    private func setShortcutCaptureActive(_ active: Bool) {
        if active {
            shortcutCaptureDepth += 1
        } else {
            shortcutCaptureDepth = 0
        }
        suspendHotKeysForShortcutCapture = shortcutCaptureDepth > 0
        applyHotKeySuspension()
    }

    private func applyHotKeySuspension() {
        if suspendHotKeysForShortcutCapture {
            hotKeyManager?.suspend()
        } else {
            hotKeyManager?.resume()
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = statusIcon()
            button.imagePosition = .imageOnly
            button.contentTintColor = recordingService.isRecording ? .systemRed : nil
            button.toolTip = recordingService.isRecording
                ? "Lens 正在录制"
                : "Lens"
        }

        let menu = NSMenu()
        if recordingService.isRecording {
            menu.addItem(menuItem(
                "停止录制  (\(model.stopRecordingShortcut.displayName))",
                action: #selector(stopRecordingFromMenu)
            ))
        }
        menu.addItem(menuItem(ActionCenterAction.enableHotKeys.menuTitle, action: #selector(enableHotKeysFromMenu)))
        menu.addItem(menuItem(
            "打开操作中心  (\(model.actionCenterShortcut.displayName))",
            action: #selector(toggleActionCenter)
        ))
        menu.addItem(menuItem(
            "区域截图  (\(model.quickScreenshotShortcut.displayName))",
            action: #selector(beginScreenshot)
        ))
        let recordingWorkspaceTitle: String
        if recordingService.isRecording {
            recordingWorkspaceTitle = recordingControl.isVisible
                ? "置前录屏浮标（正在录制）"
                : "显示录屏浮标（正在录制）"
        } else {
            recordingWorkspaceTitle = "录屏…"
        }
        menu.addItem(menuItem(recordingWorkspaceTitle, action: #selector(showRecordingSetup)))
        menu.addItem(.separator())

        let moreMenu = NSMenu(title: "更多")
        moreMenu.addItem(menuItem(ActionCenterAction.windowScreenshot.menuTitle, action: #selector(beginWindowScreenshot)))
        moreMenu.addItem(menuItem(ActionCenterAction.multiWindowScreenshot.menuTitle, action: #selector(beginMultiWindowScreenshot)))
        moreMenu.addItem(menuItem(ActionCenterAction.displayScreenshot.menuTitle, action: #selector(beginDisplayScreenshot)))
        moreMenu.addItem(menuItem(
            "\(ActionCenterAction.conversationInbox.menuTitle)  (\(model.conversationInboxShortcut.displayName))",
            action: #selector(beginConversationInboxCapture)
        ))
        moreMenu.addItem(menuItem(ActionCenterAction.ocr.menuTitle, action: #selector(beginOCR)))
        moreMenu.addItem(menuItem(ActionCenterAction.scrollingCapture.menuTitle, action: #selector(beginScrollingCapture)))
        moreMenu.addItem(.separator())
        moreMenu.addItem(menuItem(ActionCenterAction.regionRecording.menuTitle, action: #selector(beginRegionRecording)))
        moreMenu.addItem(menuItem(ActionCenterAction.windowRecording.menuTitle, action: #selector(beginWindowRecording)))
        moreMenu.addItem(menuItem(ActionCenterAction.recording.menuTitle, action: #selector(beginRecording)))
        moreMenu.addItem(.separator())
        moreMenu.addItem(menuItem(ActionCenterAction.pin.menuTitle, action: #selector(pinFromClipboard)))
        moreMenu.addItem(menuItem("隐藏全部贴图", action: #selector(togglePinnedImagesHidden)))
        moreMenu.addItem(menuItem("关闭全部贴图", action: #selector(closeAllPinnedImages)))
        moreMenu.addItem(menuItem("关闭全部 OCR", action: #selector(closeAllOCRResults)))
        let moreItem = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)

        menu.addItem(menuItem(ActionCenterAction.openLibrary.menuTitle, action: #selector(showLensLibrary)))
        menu.addItem(menuItem("管理 Lens 存储…", action: #selector(manageLensStorage)))
        menu.addItem(menuItem("在 Finder 中打开 Lens 目录", action: #selector(openLensDirectory)))
        menu.addItem(menuItem("在 Finder 中打开对话文件夹", action: #selector(openConversationInbox)))
        menu.addItem(menuItem(ActionCenterAction.openSettings.menuTitle, action: #selector(openSettingsAndPermissions)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Lens", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureApplicationMenu() {
        NSApp.mainMenu = Self.makeApplicationMainMenu(target: self)
    }

    static func makeApplicationMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu(title: "Lens")
        let applicationMenuItem = NSMenuItem(title: "Lens", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Lens")

        let aboutItem = NSMenuItem(
            title: "关于 Lens",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettingsAndPermissions),
            keyEquivalent: ","
        )
        settingsItem.target = target
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 Lens",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Lens",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = target
        applicationMenu.addItem(quitItem)

        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(
            title: "撤销",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = NSMenuItem(
            title: "重做",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func statusIcon() -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: "camera.aperture",
            accessibilityDescription: "Lens"
        ) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = true
        return configured
    }

    private func handle(_ action: ActionCenterAction) {
        switch action {
        case .screenshot:
            actionCenter.hide()
            captureCoordinator.beginRegionCapture()
        case .windowScreenshot:
            actionCenter.hide()
            captureCoordinator.beginWindowCapture()
        case .multiWindowScreenshot:
            actionCenter.hide()
            captureCoordinator.beginMultiWindowCapture()
        case .displayScreenshot:
            actionCenter.hide()
            captureCoordinator.beginDisplayCapture()
        case .conversationInbox:
            actionCenter.hide()
            captureCoordinator.beginConversationInboxCapture()
        case .recordingSetup:
            actionCenter.hide()
            showRecordingSetup()
        case .recording:
            actionCenter.hide()
            startDisplayRecording()
        case .regionRecording:
            actionCenter.hide()
            captureCoordinator.beginRegionRecordingSelection()
        case .windowRecording:
            actionCenter.hide()
            recordingSetup.show(initialSource: .window)
        case .ocr:
            actionCenter.hide()
            captureCoordinator.beginOCRCapture()
        case .scrollingCapture:
            actionCenter.hide()
            captureCoordinator.beginScrollingCapture()
        case .pin:
            actionCenter.hide()
            pinClipboardOrRecent()
        case .openLibrary:
            actionCenter.hide()
            showLensLibrary()
        case .openSettings:
            actionCenter.hide()
            permissionCenter.show()
        case .enableHotKeys:
            actionCenter.hide()
            promptAccessibilityAndShowSettings()
        }
    }

    @objc private func toggleActionCenter() {
        actionCenter.toggle()
    }

    @objc private func beginScreenshot() {
        actionCenter.hide()
        captureCoordinator.beginRegionCapture()
    }

    @objc private func beginWindowScreenshot() {
        actionCenter.hide()
        captureCoordinator.beginWindowCapture()
    }

    @objc private func beginMultiWindowScreenshot() {
        actionCenter.hide()
        captureCoordinator.beginMultiWindowCapture()
    }

    @objc private func beginDisplayScreenshot() {
        actionCenter.hide()
        captureCoordinator.beginDisplayCapture()
    }

    @objc private func beginConversationInboxCapture() {
        actionCenter.hide()
        captureCoordinator.beginConversationInboxCapture()
    }

    @objc private func beginOCR() {
        actionCenter.hide()
        captureCoordinator.beginOCRCapture()
    }

    @objc private func beginScrollingCapture() {
        actionCenter.hide()
        captureCoordinator.beginScrollingCapture()
    }

    @objc private func beginRecording() {
        actionCenter.hide()
        startDisplayRecording()
    }

    @objc private func stopRecordingFromMenu() {
        recordingControl.beginFinalizing()
        recordingSession.stop()
    }

    @objc private func showRecordingSetup() {
        actionCenter.hide()
        if recordingService.isRecording {
            recordingControl.showExisting()
            toast.show(
                title: "录屏浮标已显示",
                detail: "浮标会跨窗口和桌面保持置前",
                symbol: "record.circle.fill"
            )
            return
        }
        recordingSetup.show()
    }

    @objc private func beginRegionRecording() {
        actionCenter.hide()
        captureCoordinator.beginRegionRecordingSelection()
    }

    @objc private func beginWindowRecording() {
        actionCenter.hide()
        recordingSetup.show(initialSource: .window)
    }

    @objc private func openLensDirectory() {
        try? FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.rootDirectory)
    }

    private func activeStoragePackages() -> Set<URL> {
        ActiveStoragePackagePolicy.resolve(
            rootDirectory: store.rootDirectory,
            taskPackageURLs: recordingProcessingTaskRegistry.activePackageURLs
                + recordingRenderTaskRegistry.activePackageURLs
                + recordingContentTaskRegistry.activePackageURLs,
            editingPackageURLs: [
                videoEditor.activeStoragePackageURL,
                annotationEditor.activeStoragePackageURL
            ],
            hasUnnamedWrite: recordingSession.isStarting
                || recordingSession.isRecording
                || recordingSession.isStopping
                || recordingService.isRecording
                || captureCoordinator.hasActiveStorageWrite
                || lensLibrary.blocksStorageMigration
        )
    }

    @objc private func manageLensStorage() {
        let manager = LensStorageManager(rootDirectory: store.rootDirectory)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .utility) {
                Result { try manager.inventory() }
            }.value
            guard case let .success(inventory) = result else {
                toast.show(
                    title: "暂时无法读取 Lens 存储",
                    detail: "原始素材不会受到影响，请稍后再试",
                    symbol: "externaldrive.badge.xmark"
                )
                return
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let total = formatter.string(fromByteCount: inventory.totalBytes)
            let source = formatter.string(
                fromByteCount: inventory.bytesByCategory[.source] ?? 0
            )
            let rendered = formatter.string(
                fromByteCount: inventory.bytesByCategory[.rendered] ?? 0
            )
            let derived = formatter.string(
                fromByteCount: inventory.bytesByCategory[.derived] ?? 0
            )
            let index = formatter.string(
                fromByteCount: inventory.bytesByCategory[.index] ?? 0
            )
            let rebuildable = formatter.string(
                fromByteCount: inventory.bytesByCategory[.rebuildable] ?? 0
            )
            let temporary = formatter.string(
                fromByteCount: inventory.bytesByCategory[.temporary] ?? 0
            )
            let pendingMigration: LensStoragePendingMigration?
            do {
                pendingMigration = try manager.pendingMigration()
            } catch {
                toast.show(
                    title: "迁移记录需要复核",
                    detail: error.localizedDescription,
                    symbol: "externaldrive.badge.xmark"
                )
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Lens 存储"
            let migrationHint = pendingMigration.map {
                "\n上次迁移尚未完成（\($0.phase)），选择新的位置可继续校验。"
            } ?? ""
            let queuedHint = storageMigrationQueue.pendingDestination.map {
                "\n已有迁移请求排队，任务结束后将复制到 \($0.path)。"
            } ?? ""
            alert.informativeText = "项目 \(inventory.packageCount) 个 · 总占用 \(total)\n原始素材 \(source) · 成片 \(rendered) · 派生数据 \(derived)\n索引 \(index) · 可重建缓存 \(rebuildable) · 可清理临时文件 \(temporary)\(migrationHint)\(queuedHint)"
            alert.addButton(withTitle: "更改存储位置…")
            alert.addButton(withTitle: "清理临时文件")
            alert.addButton(withTitle: "在 Finder 中打开")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                changeLensStorageLocation()
            case .alertSecondButtonReturn:
                let protectedPackages = activeStoragePackages()
                let cleanupResult = await Task.detached(priority: .utility) {
                    Result {
                        try manager.cleanupTemporaryFiles(protecting: protectedPackages)
                    }
                }.value
                guard case let .success(report) = cleanupResult else {
                    toast.show(
                        title: "临时文件未清理",
                        detail: "正在使用的录制文件会保留，原始素材不会受到影响",
                        symbol: "externaldrive.badge.xmark"
                    )
                    return
                }
                if report.removedItems.isEmpty {
                    toast.show(
                        title: "没有可清理的临时文件",
                        detail: report.skippedItems.isEmpty
                            ? "当前 Lens 存储已经是干净状态"
                            : "正在使用的录制任务仍保留其临时文件",
                        symbol: "checkmark.circle"
                    )
                } else {
                    let removed = formatter.string(fromByteCount: report.removedBytes)
                    toast.show(
                        title: "已清理临时文件",
                        detail: "释放 \(removed)；原始素材和成片均未删除",
                        symbol: "checkmark.circle.fill"
                    )
                }
            case .alertThirdButtonReturn:
                openLensDirectory()
            default:
                break
            }
        }
    }

    private func changeLensStorageLocation() {
        let panel = NSSavePanel()
        panel.title = "选择新的 Lens 存储目录"
        panel.message = "Lens 会先复制并校验全部项目；原目录会保留，完成后会自动退出并在重新打开后切换到新目录。"
        panel.nameFieldStringValue = "Lens"
        panel.canCreateDirectories = true
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        guard storageMigrationQueue.request(
            destination: destination,
            activePackages: activeStoragePackages()
        ) else {
            toast.show(
                title: "存储迁移已排队",
                detail: "当前有录制、转写、整理或另一项迁移正在进行；任务结束后会自动复制并校验，原目录会继续保留",
                symbol: "externaldrive.badge.exclamationmark"
            )
            return
        }
        startLensStorageMigration(to: destination)
    }

    private func startLensStorageMigration(to destination: URL) {
        let manager = LensStorageManager(rootDirectory: store.rootDirectory)
        storageMigrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let (progressStream, progressContinuation) = AsyncStream.makeStream(
                of: LensStorageMigrationProgress.self
            )
            let migrationTask = Task.detached(priority: .utility) {
                defer { progressContinuation.finish() }
                return Result {
                    let receipt = try manager.migrate(
                        to: destination,
                        progress: { progress in
                            progressContinuation.yield(progress)
                        }
                    )
                    // Build the destination index from the copied project
                    // facts before the preference points the next launch at
                    // it. A stale source index can never become authoritative
                    // just because the directory was copied.
                    _ = LensProjectStore(rootDirectory: destination).libraryEntries()
                    return receipt
                }
            }
            cancelStorageMigrationWorker = { migrationTask.cancel() }
            var lastToastPhase: LensStorageMigrationPhase?
            for await progress in progressStream {
                model.storageMigrationProgress = progress
                guard progress.phase != lastToastPhase else { continue }
                lastToastPhase = progress.phase
                let title: String
                let symbol: String
                switch progress.phase {
                case .copying:
                    title = "正在迁移 Lens 存储"
                    symbol = "externaldrive.fill"
                case .verifying:
                    title = "正在校验 Lens 存储"
                    symbol = "checkmark.shield"
                case .publishing:
                    title = "正在切换 Lens 存储"
                    symbol = "arrow.triangle.2.circlepath"
                case .completed:
                    title = "Lens 存储迁移完成"
                    symbol = "checkmark.circle.fill"
                }
                toast.show(
                    title: title,
                    detail: "已完成 \(progress.completedChildren)/\(progress.totalChildren)",
                    symbol: symbol
                )
            }
            let result = await migrationTask.value
            model.storageMigrationProgress = nil
            cancelStorageMigrationWorker = nil
            switch result {
            case let .success(receipt):
                model.lensStorageRootDirectory = destination.standardizedFileURL
                let verified = ByteCountFormatter.string(
                    fromByteCount: receipt.copiedBytes,
                    countStyle: .file
                )
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Lens 存储已迁移"
                alert.informativeText = "已校验 \(receipt.verifiedFileCount) 个文件（\(verified)）。原目录仍保留。Lens 将退出，请重新打开应用以从新位置读写。"
                alert.addButton(withTitle: "退出并重新打开")
                alert.runModal()
                NSApp.terminate(nil)
            case let .failure(error) where error is CancellationError:
                toast.show(
                    title: "已取消存储迁移",
                    detail: "原目录和已复制的暂存内容均保留，可稍后继续",
                    symbol: "xmark.circle"
                )
            case let .failure(error):
                toast.show(
                    title: "存储迁移未完成",
                    detail: "原目录未删除；下次可从同一入口继续。\n\(error.localizedDescription)",
                    symbol: "externaldrive.badge.xmark"
                )
            }
            storageMigrationQueue.finish()
            storageMigrationTask = nil
            startPendingLensStorageMigrationIfReady()
        }
    }

    private func cancelLensStorageMigration() {
        guard storageMigrationTask != nil else { return }
        cancelStorageMigrationWorker?()
        storageMigrationTask?.cancel()
        toast.show(
            title: "正在取消存储迁移",
            detail: "原目录不会删除，已复制内容会保留以便继续",
            symbol: "xmark.circle"
        )
    }

    private func startPendingLensStorageMigrationIfReady() {
        guard let destination = storageMigrationQueue.takeNextIfReady(
            activePackages: activeStoragePackages()
        ) else { return }
        startLensStorageMigration(to: destination)
    }

    /// A forced quit or power loss leaves a migration journal beside the
    /// current root. Resume it after launch instead of requiring the user to
    /// rediscover the destination in the storage dialog. Recording recovery
    /// runs first; an active package writer keeps the destination queued until
    /// its task finishes.
    private func resumePendingLensStorageMigrationIfNeeded() {
        let manager = LensStorageManager(rootDirectory: store.rootDirectory)
        do {
            if let recovered = try manager.recoverPublishedMigrationIfNeeded() {
                let destination = URL(
                    fileURLWithPath: recovered.destinationPath,
                    isDirectory: true
                ).standardizedFileURL
                model.lensStorageRootDirectory = destination
                logDiagnostic(
                    "storage.migration.resume_published",
                    metadata: ["destination": destination.path]
                )
                toast.show(
                    title: "Lens 存储迁移已完成",
                    detail: "上次迁移已完成校验，Lens 将退出；重新打开后从新位置读写",
                    symbol: "checkmark.circle.fill"
                )
                NSApp.terminate(nil)
                return
            }
        } catch {
            logDiagnostic(
                "storage.migration.resume_verification_failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            toast.show(
                title: "Lens 存储迁移需要复核",
                detail: "迁移记录仍保留，原目录没有被删除",
                symbol: "externaldrive.badge.xmark"
            )
            return
        }
        let pending: LensStoragePendingMigration
        do {
            guard let value = try manager.pendingMigration() else { return }
            pending = value
        } catch {
            logDiagnostic(
                "storage.migration.resume_journal_failed",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            toast.show(
                title: "Lens 存储迁移需要复核",
                detail: error.localizedDescription,
                symbol: "externaldrive.badge.xmark"
            )
            return
        }
        let destination = URL(
            fileURLWithPath: pending.plan.destinationPath,
            isDirectory: true
        )
        let canStart = storageMigrationQueue.request(
            destination: destination,
            activePackages: activeStoragePackages()
        )
        guard canStart else {
            logDiagnostic(
                "storage.migration.resume_queued",
                level: .warning,
                metadata: ["phase": pending.phase]
            )
            return
        }
        logDiagnostic(
            "storage.migration.resume_started",
            metadata: [
                "phase": pending.phase,
                "destination": destination.path
            ]
        )
        toast.show(
            title: "正在继续 Lens 存储迁移",
            detail: "上次迁移未完成，Lens 将继续复制并校验",
            symbol: "arrow.counterclockwise.circle.fill"
        )
        startLensStorageMigration(to: destination)
    }

    @objc private func openConversationInbox() {
        let directory = model.conversationInboxDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func pinFromClipboard() {
        actionCenter.hide()
        pinClipboardOrRecent()
    }

    @objc private func togglePinnedImagesHidden() {
        pinnedImages.toggleHidden()
    }

    @objc private func closeAllPinnedImages() {
        pinnedImages.closeAll()
    }

    @objc private func closeAllOCRResults() {
        ocrResults.closeAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(enableHotKeysFromMenu):
            menuItem.isHidden = AXIsProcessTrusted()
            return !menuItem.isHidden
        case #selector(togglePinnedImagesHidden):
            menuItem.title = pinnedImages.areHidden ? "显示全部贴图" : "隐藏全部贴图"
            return pinnedImages.hasPins
        case #selector(closeAllPinnedImages):
            return pinnedImages.hasPins
        case #selector(closeAllOCRResults):
            return ocrResults.hasVisibleResults
        default:
            return true
        }
    }

    private func pinClipboardOrRecent() {
        if pinnedImages.pinClipboard() {
            toast.show(
                title: "已贴上剪贴板",
                detail: "图像、文字或色值会浮在桌面上",
                symbol: "pin.fill"
            )
            return
        }
        if let recent = model.recentLens {
            let manifest = LensManifest(
                id: recent.id,
                kind: .screenshot,
                title: recent.title,
                dimensions: recent.dimensions,
                assets: [LensAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
            pinnedImages.pin(
                lens: SavedLens(
                    packageURL: recent.packageURL,
                    rawAssetURL: recent.imageURL,
                    manifest: manifest
                ),
                image: recent.thumbnail
            )
            return
        }
        toast.show(
            title: "没有可贴的内容",
            detail: "先复制图像、文字或色值，或完成一次截图",
            symbol: "pin"
        )
    }

    @objc private func showLensLibrary() {
        guard storageWritesAllowed else {
            showStorageMigrationBlockedToast()
            return
        }
        actionCenter.hide()
        lensLibrary.show()
    }

    private func showStorageMigrationBlockedToast() {
        toast.show(
            title: "素材库正在迁移",
            detail: "迁移完成后才能开始新的录制、截图或编辑",
            symbol: "externaldrive.badge.arrow.right"
        )
    }

    private func showOCRResult(for entry: LensLibraryEntry) {
        do {
            let document = try store.loadOCR(from: entry.packageURL)
            let draft = OCRResultDraft(document: document)
            guard draft.hasText else {
                toast.show(
                    title: "没有识别到文字",
                    detail: "这条记录里没有可编辑的 OCR 结果",
                    symbol: "text.magnifyingglass"
                )
                return
            }
            ocrResults.show(
                document: document,
                thumbnail: NSImage(contentsOf: entry.displayAssetURL)
            )
        } catch {
            logDiagnosticFailure("ocr.reopen.failed", error: error)
            toast.show(
                title: "无法打开识别文字",
                detail: StorageRecoveryGuidance.detail(for: error),
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
    }

    @objc private func openSettingsAndPermissions() {
        actionCenter.hide()
        permissionCenter.show()
    }

    @objc private func enableHotKeysFromMenu() {
        promptAccessibilityAndShowSettings()
    }

    private func promptAccessibilityAndShowSettings() {
        permissionCenter.show()
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleOCRCompleted(_ document: OCRDocument, lens: SavedLens) {
        beginOrganization(lens: lens, ocr: document, announcesResult: false)
        switch ocrResults.fulfill(lensID: lens.manifest.id, document: document) {
        case .ready:
            break
        case .empty:
            toast.show(
                title: "没有识别到文字",
                detail: "原图已保存在 Lens 项目中",
                symbol: "text.magnifyingglass"
            )
        case .dismissed:
            break
        }
    }

    private func handleOCRFailed(_ error: Error, lens: SavedLens) {
        ocrResults.fail(lensID: lens.manifest.id)
        logDiagnosticFailure("ocr.failed", error: error)
        toast.show(
            title: "原图已安全保存",
            detail: "文字识别未完成：\(error.localizedDescription)",
            symbol: "exclamationmark.arrow.triangle.2.circlepath"
        )
    }

    private func makeRecordingTranscriptionWorker() -> RecordingTranscriptionWorker {
        RecordingTranscriptionWorker(
            authorizationStatus: {
                LocalSpeechTranscriptionService.authorizationState
            },
            requestAuthorization: {
                await LocalSpeechTranscriptionService.requestAuthorizationState()
            },
            source: { [weak self] entry in
                guard let self else { throw CancellationError() }
                let source = try self.transcriptionSource(for: entry)
                return RecordingTranscriptionSource(url: source.url, role: source.role)
            },
            presentPermission: { [weak self] in
                self?.permissionCenter.show()
            },
            presentToast: { [weak self] title, detail, symbol in
                self?.toast.show(title: title, detail: detail, symbol: symbol)
            },
            reportProgress: { [weak self] lensID, completed, total in
                self?.lensLibrary.setTranscriptionProgress(
                    LensLibraryTranscriptionProgress(
                        completed: completed,
                        total: total
                    ),
                    lensID: lensID
                )
            },
            localeIdentifier: { [weak self] in
                self?.model.transcriptionLanguage.localeIdentifier ?? "zh-Hans"
            },
            transcribe: { [weak self] audioURL, localeIdentifier, sourceRole, progress in
                guard let self else { throw CancellationError() }
                return try await self.transcriptionService.transcribe(
                    audioURL: audioURL,
                    localeIdentifier: localeIdentifier,
                    sourceRole: sourceRole,
                    progress: progress
                )
            }
        )
    }

    private func beginTranscription(
        for entry: LensLibraryEntry,
        automatic: Bool = false
    ) {
        guard storageWritesAllowed else {
            if !automatic { showStorageMigrationBlockedToast() }
            return
        }
        let packageKey = entry.packageURL.standardizedFileURL
        let isActive = recordingContentTaskRegistry.contains(
            packageURL: packageKey,
            kind: .transcription
        )
        let isPending = pendingAutomaticTranscriptions.contains(lensID: entry.id)
        let admission = RecordingTaskSchedulingPolicy.admission(
            // Manual requests remain user-visible and may start while a new
            // recording is active; only automatic background work yields.
            priority: automatic ? .background : .recordingFinalization,
            whileRecording: recordingSession.isRecording,
            isActive: isActive,
            isPending: isPending,
            activeCount: recordingContentTaskRegistry.count(kind: .transcription)
        )
        switch admission {
        case .start:
            break
        case .deferredWhileRecording:
            guard pendingAutomaticTranscriptions.enqueue(entry) else { return }
            logDiagnostic(
                "transcription.queued_while_recording",
                metadata: ["queueDepth": String(pendingAutomaticTranscriptions.count)]
            )
            return
        case .alreadyQueued:
            if !automatic {
                toast.show(
                    title: "这条录屏已经在转写队列中",
                    detail: "完成后会自动生成字幕与整理结果",
                    symbol: "waveform.badge.magnifyingglass"
                )
            }
            return
        case .atCapacity:
            if automatic {
                _ = pendingAutomaticTranscriptions.enqueue(entry)
            } else {
                toast.show(
                    title: "另一条本机转写仍在进行",
                    detail: "完成后即可继续；结果会自动进入 Lens 索引",
                    symbol: "waveform.badge.magnifyingglass"
                )
            }
            return
        }
        if automatic, !pendingAutomaticTranscriptions.claim(entry) {
            logDiagnostic(
                "transcription.queue_retry_limit_reached",
                level: .warning,
                metadata: ["count": "1", "lensID": entry.id.uuidString]
            )
            return
        }
        let startedTask = recordingTranscriptionTaskCoordinator.start(
            entry: entry,
            automatic: automatic
        ) { [weak self] in
            guard let self else { return }
            pendingAutomaticTranscriptions.complete(lensID: entry.id)
            startNextPendingAutomaticTranscriptionIfIdle()
        }
        guard startedTask != nil else {
            if automatic {
                _ = pendingAutomaticTranscriptions.requeueFront(entry)
            }
            return
        }
    }

    private func makeRecordingOrganizationWorker(
        store: LensProjectStore,
        diagnostics: LocalDiagnosticLog
    ) -> RecordingOrganizationWorker {
        RecordingOrganizationWorker(
            loadManifest: { packageURL in
                try store.loadManifest(from: packageURL)
            },
            loadOCR: { packageURL in
                try store.loadOCR(from: packageURL)
            },
            loadTranscript: { packageURL in
                try store.loadTranscript(from: packageURL)
            },
            loadInsights: { packageURL in
                try store.loadInsights(from: packageURL)
            },
            recordDiagnostic: { event, metadata in
                await diagnostics.record(
                    event,
                    level: .warning,
                    metadata: metadata
                )
            }
        )
    }

    private func beginOrganization(for entry: LensLibraryEntry) {
        beginOrganization(lens: SavedLens(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        ), announcesResult: true)
    }

    private func beginOrganization(
        lens: SavedLens,
        ocr suppliedOCR: OCRDocument? = nil,
        transcript suppliedTranscript: TranscriptDocument? = nil,
        announcesResult: Bool = false
    ) {
        guard storageWritesAllowed else {
            if announcesResult { showStorageMigrationBlockedToast() }
            return
        }
        recordingOrganizationTaskCoordinator.begin(
            lens: lens,
            suppliedOCR: suppliedOCR,
            suppliedTranscript: suppliedTranscript,
            announcesResult: announcesResult
        )
    }

    private func saveInsightsCustomization(
        for entry: LensLibraryEntry,
        customization: LensInsightsCustomization?
    ) {
        guard storageWritesAllowed else {
            showStorageMigrationBlockedToast()
            return
        }
        do {
            let current = try store.loadInsights(from: entry.packageURL)
            let updated = current.replacingCustomization(customization)
            let saved = SavedLens(
                packageURL: entry.packageURL,
                rawAssetURL: entry.primaryAssetURL,
                manifest: entry.manifest
            )
            _ = try store.attachInsights(updated, to: saved)
            lensLibrary.reloadIfVisible()
            toast.show(
                title: customization == nil ? "已恢复自动整理" : "人工校正已保存",
                detail: "OCR、转写和原始媒体均未改变",
                symbol: customization == nil
                    ? "arrow.uturn.backward.circle.fill"
                    : "checkmark.circle.fill"
            )
        } catch {
            toast.show(
                title: "校正尚未保存",
                detail: error.localizedDescription,
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
    }

    private func transcriptionSource(
        for entry: LensLibraryEntry
    ) throws -> (url: URL, role: LensAsset.Role) {
        if let microphone = entry.manifest.assets.first(where: { $0.role == .microphone }) {
            let url = entry.packageURL.appendingPathComponent(microphone.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, .microphone)
            }
        }
        guard FileManager.default.fileExists(atPath: entry.primaryAssetURL.path) else {
            throw LocalSpeechTranscriptionError.missingSource
        }
        return (entry.primaryAssetURL, .screenVideo)
    }

    func beginAutomaticTranscription(for lens: SavedLens) {
        guard let entry = libraryEntry(for: lens) else { return }
        beginTranscription(for: entry, automatic: true)
    }

    func deliveryImage(for lens: SavedLens) -> NSImage {
        if let thumbnail = lens.manifest.assets.first(where: { $0.role == .thumbnail }) {
            let url = lens.packageURL.appendingPathComponent(thumbnail.relativePath)
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        if lens.manifest.kind == .screenshot,
           let image = NSImage(contentsOf: lens.rawAssetURL) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: lens.rawAssetURL.path)
    }

    func libraryEntry(for lens: SavedLens) -> LensLibraryEntry? {
        let manifest: LensManifest
        do {
            manifest = try store.loadManifest(from: lens.packageURL)
        } catch {
            logDiagnosticFailure("library.manifest_load_failed", error: error)
            return nil
        }
        guard let primaryAsset = manifest.assets.first(where: { $0.role == .screenVideo }) else {
            return nil
        }
        let primaryURL = lens.packageURL.appendingPathComponent(primaryAsset.relativePath)
        guard FileManager.default.fileExists(atPath: primaryURL.path) else { return nil }
        let displayURL = manifest.assets
            .first(where: { $0.role == .renderedVideo })
            .map { lens.packageURL.appendingPathComponent($0.relativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? primaryURL
        let transcript: TranscriptDocument?
        do {
            transcript = try store.loadTranscript(from: lens.packageURL)
        } catch {
            logDiagnostic(
                "library.transcript_load_failed",
                level: .warning,
                metadata: DiagnosticEvent.errorMetadata(error)
            )
            transcript = nil
        }
        let insights: LensInsightsDocument?
        do {
            insights = try store.loadInsights(from: lens.packageURL)
        } catch {
            logDiagnostic(
                "library.insights_load_failed",
                level: .warning,
                metadata: DiagnosticEvent.errorMetadata(error)
            )
            insights = nil
        }
        return LensLibraryEntry(
            packageURL: lens.packageURL,
            manifest: manifest,
            primaryAssetURL: primaryURL,
            displayAssetURL: displayURL,
            ocrText: nil,
            transcriptText: transcript?.fullText,
            insights: insights
        )
    }

    private func handleScrollingCaptureCompleted(
        frameCount: Int,
        height: Int,
        warning: Error?
    ) {
        if let warning {
            toast.show(
                title: "长截图已复制",
                detail: "\(frameCount) 帧 · \(height) px；部分源数据保留受限：\(warning.localizedDescription)",
                symbol: "checkmark.circle"
            )
        } else {
            toast.show(
                title: "长截图已拼接并复制",
                detail: "\(frameCount) 帧 · \(height) px · 原始帧与拼接计划均已保留",
                symbol: "arrow.up.and.down.text.horizontal"
            )
        }
    }

    private func startDisplayRecording(capturesCamera: Bool = false) {
        guard let displayID = activeDisplayID() else {
            toast.show(title: "找不到显示器", symbol: "exclamationmark.triangle")
            return
        }
        startRecording(
            source: CaptureGeometry.displayRecordingSource(
                displayID: displayID,
                displayBounds: CGDisplayBounds(displayID)
            ),
            capturesCamera: capturesCamera
        )
    }

    private func startRecording(
        source: RecordingCaptureSource,
        capturesCamera: Bool = false
    ) {
        guard storageWritesAllowed else {
            showStorageMigrationBlockedToast()
            return
        }
        recordingSession.start(source: source, capturesCamera: capturesCamera)
    }

    private func handleUnexpectedCaptureStop(_ error: Error) {
        recordingSession.handleUnexpectedCaptureStop(error)
    }

    private func handleOptionalTrackInterruption(
        _ track: RecordingOptionalTrack,
        error: Error
    ) {
        recordingSession.handleOptionalTrackInterruption(track, error: error)
    }

    private func activeDisplayID() -> CGDirectDisplayID? {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    func cameraAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private var appVersionMetadata: [String: String] {
        buildIdentity.diagnosticMetadata
    }

    func logDiagnostic(
        _ code: String,
        level: DiagnosticLevel = .info,
        metadata: [String: String] = [:]
    ) {
        let diagnostics = diagnostics
        Task {
            await diagnostics.record(code, level: level, metadata: metadata)
        }
    }

    private func logDiagnosticFailure(
        _ code: String,
        error: Error,
        metadata: [String: String] = [:]
    ) {
        logDiagnostic(
            code,
            level: .error,
            metadata: metadata.merging(DiagnosticEvent.errorMetadata(error)) { current, _ in current }
        )
    }

    private func makeDiagnosticSummary() async -> String {
        let version = appVersionMetadata
        let permissions = PermissionCenterModel.currentStates().reduce(into: [:]) {
            result, pair in
            result[pair.key.rawValue] = pair.value.rawValue
        }
        return await diagnostics.makeSummary(
            appVersion: version["appVersion"] ?? "development",
            build: version["build"] ?? "development",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architectureName,
            permissions: permissions,
            crashReports: crashReportScanner.recentReports()
        )
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    func showRecordingError(_ error: Error, phase: String) {
        logDiagnosticFailure(
            "recording.failed",
            error: error,
            metadata: ["phase": phase]
        )
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Lens 无法完成录屏"
        alert.informativeText = StorageRecoveryGuidance.detail(for: error)
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// A rebuilt recording is longer than the plan and preview that were
    /// generated for it, so both are regenerated from the merged media before
    /// the user opens it.
    private func completeRecordingRepair(
        _ entry: LensLibraryEntry,
        rebuilt: RebuiltRecording
    ) {
        logDiagnostic(
            "recording.repair_completed",
            metadata: [
                "addedMilliseconds": String(Int(rebuilt.addedSeconds * 1_000)),
                "durationMilliseconds": String(Int(rebuilt.durationSeconds * 1_000))
            ]
        )
        toast.show(
            title: "已并入 \(String(format: "%.1f", rebuilt.addedSeconds)) 秒画面",
            detail: "原始分片仍保留；正在按新时长重新生成预览",
            symbol: "arrow.clockwise.circle.fill"
        )
        let repair = Task { @MainActor [weak self] in
            guard let self else { return }
            let manifest: LensManifest
            do {
                manifest = try store.loadManifest(from: rebuilt.packageURL)
            } catch {
                logDiagnosticFailure("recording.repair_manifest_load_failed", error: error)
                return
            }
            let saved = SavedLens(
                packageURL: rebuilt.packageURL,
                rawAssetURL: rebuilt.packageURL
                    .appendingPathComponent("raw/screen.mp4"),
                manifest: manifest
            )
            _ = await processRecording(saved)
            lensLibrary.reloadIfVisible()
        }
        trackProcessingTask(repair, for: rebuilt.packageURL)
    }

    @discardableResult
    func processRecording(_ saved: SavedLens) async -> AutoEditPlan? {
        await recordingRenderTaskCoordinator.process(saved)
    }

    func trackProcessingTask(_ task: Task<Void, Never>, for packageURL: URL) {
        recordingProcessingTaskRegistry.track(
            task,
            for: packageURL,
            onCompletion: { [weak self] in
                self?.startPendingLensStorageMigrationIfReady()
            }
        )
    }

    func cancelRecordingProcessing(for packageURL: URL) {
        let packageKey = packageURL.standardizedFileURL
        recordingProcessingTaskRegistry.cancel(for: packageKey)
        recordingRenderTaskRegistry.cancel(for: packageKey)
    }

    private func makeRecordingRenderPipeline() -> RecordingRenderPipeline {
        RecordingRenderPipeline(
            audioMixdownRenderer: audioMixdownRenderer,
            previewRenderer: previewRenderer,
            renderedEffectVerifier: renderedEffectVerifier,
            advancePhase: { [weak self] taskToken, phase in
                guard let self else { return }
                await self.recordingTaskCoordinator.advance(
                    taskToken,
                    to: phase,
                    now: Date()
                )
            },
            reportProgress: { [weak self] fraction, saved in
                self?.quickAccess.updateProgress(fraction, for: saved)
                self?.videoEditor.updateProcessingProgress(
                    fraction,
                    packageURL: saved.packageURL
                )
            },
            recordDiagnostic: { [weak self] code, level, metadata in
                self?.logDiagnostic(code, level: level, metadata: metadata)
            }
        )
    }

    private func makeRecordingRenderPresentation() -> RecordingRenderPresentation {
        RecordingRenderPresentation(
            reloadLibrary: { [weak self] in
                self?.lensLibrary.reloadIfVisible()
            },
            deliveryImage: { [weak self] lens in
                self?.deliveryImage(for: lens)
                    ?? NSWorkspace.shared.icon(forFile: lens.rawAssetURL.path)
            },
            updateQuickAccess: { [weak self] lens, image, title, state in
                self?.quickAccess.updateIfShowing(
                    lens,
                    thumbnail: image,
                    confirmationTitle: title,
                    deliveryState: state
                )
            },
            showToast: { [weak self] title, detail, symbol in
                self?.toast.show(title: title, detail: detail, symbol: symbol)
            },
            recordDiagnostic: { [weak self] code, level, metadata in
                self?.logDiagnostic(code, level: level, metadata: metadata)
            }
        )
    }

    private func makeRecordingContentTaskPresentation() -> RecordingContentTaskPresentation {
        RecordingContentTaskPresentation(
            reloadLibrary: { [weak self] in
                self?.lensLibrary.reloadIfVisible()
            },
            showToast: { [weak self] title, detail, symbol in
                self?.toast.show(title: title, detail: detail, symbol: symbol)
            },
            recordDiagnostic: { [weak self] code, level, metadata in
                self?.logDiagnostic(code, level: level, metadata: metadata)
            },
            recordFailure: { [weak self] code, metadata in
                self?.logDiagnostic(code, level: .error, metadata: metadata)
            }
        )
    }

    private func makeRecordingTaskMetricsReporter() -> RecordingTaskMetricsReporter {
        let coordinator = recordingTaskCoordinator
        return RecordingTaskMetricsReporter(
            loadSnapshot: { packageURL, kind, version in
                await coordinator.snapshot(
                    packageURL: packageURL,
                    kind: kind,
                    version: version
                )
            },
            recordDiagnostic: { [weak self] code, level, metadata in
                self?.logDiagnostic(code, level: level, metadata: metadata)
            }
        )
    }

    private func makeRecordingContentTaskFinalizer() -> RecordingContentTaskFinalizer {
        RecordingContentTaskFinalizer(
            recordMetrics: { [weak self] packageURL, kind, version in
                await self?.recordingTaskMetricsReporter.record(
                    packageURL: packageURL,
                    kind: kind,
                    version: version
                )
            },
            finishRegistry: { [weak self] packageURL, kind in
                self?.recordingContentTaskRegistry.finish(
                    packageURL: packageURL,
                    kind: kind
                )
            },
            setTranscribing: { [weak self] lensID, active in
                self?.lensLibrary.setTranscribing(active, lensID: lensID)
            },
            setOrganizing: { [weak self] lensID, active in
                self?.lensLibrary.setOrganizing(active, lensID: lensID)
            },
            startMigration: { [weak self] in
                self?.startPendingLensStorageMigrationIfReady()
            }
        )
    }

    private func makeRecordingOrganizationTaskCoordinator()
        -> RecordingOrganizationTaskCoordinator {
        RecordingOrganizationTaskCoordinator(
            registry: recordingContentTaskRegistry,
            execution: recordingContentTaskExecution,
            finalizer: recordingContentTaskFinalizer,
            presentation: recordingContentTaskPresentation,
            workerFactory: { [weak self] in
                guard let self else { return nil }
                return self.makeRecordingOrganizationWorker(
                    store: self.store,
                    diagnostics: self.diagnostics
                )
            },
            attachInsights: { [weak self] insights, lens in
                guard let self else { throw CancellationError() }
                _ = try self.store.attachInsights(insights, to: lens)
            },
            setOrganizing: { [weak self] lensID, active in
                self?.lensLibrary.setOrganizing(active, lensID: lensID)
            }
        )
    }

    private func makeRecordingTranscriptionTaskCoordinator()
        -> RecordingTranscriptionTaskCoordinator {
        RecordingTranscriptionTaskCoordinator(
            registry: recordingContentTaskRegistry,
            execution: recordingContentTaskExecution,
            finalizer: recordingContentTaskFinalizer,
            presentation: recordingContentTaskPresentation,
            workerFactory: { [weak self] in
                self?.makeRecordingTranscriptionWorker()
            },
            attachTranscript: { [weak self] document, saved in
                guard let self else { throw CancellationError() }
                return try self.store.attachTranscript(document, to: saved)
            },
            loadPlan: { [weak self] packageURL in
                guard let self else { throw CancellationError() }
                return try self.store.loadAutoEditPlan(from: packageURL)
            },
            writePlan: { [weak self] plan, packageURL in
                guard let self else { throw CancellationError() }
                return try self.store.writeAutoEditPlan(plan, to: packageURL)
            },
            startOrganization: { [weak self] lens, document in
                self?.beginOrganization(lens: lens, transcript: document)
            },
            render: { [weak self] lens in
                guard let self else { return nil }
                return await self.processRecording(lens)
            },
            loadManifest: { [weak self] packageURL in
                guard let self else { throw CancellationError() }
                return try self.store.loadManifest(from: packageURL)
            },
            setTranscribing: { [weak self] lensID, active in
                self?.lensLibrary.setTranscribing(active, lensID: lensID)
            }
        )
    }

    private func makeRecordingRenderExecution() -> RecordingRenderExecution {
        RecordingRenderExecution(
            store: store,
            pipeline: recordingRenderPipeline,
            isCurrent: { [weak self] packageURL, generation in
                self?.recordingRenderTaskRegistry.isCurrent(
                    packageURL: packageURL,
                    generation: generation
                ) ?? false
            },
            advancePhase: { [weak self] taskToken, phase in
                await self?.recordingTaskCoordinator.advance(
                    taskToken,
                    to: phase,
                    now: Date()
                )
            },
            recordDiagnostic: { [weak self] code, level, metadata in
                self?.logDiagnostic(code, level: level, metadata: metadata)
            }
        )
    }

    private func makeRecordingRenderTaskCoordinator()
        -> RecordingRenderTaskCoordinator {
        RecordingRenderTaskCoordinator(
            taskCoordinator: recordingTaskCoordinator,
            registry: recordingRenderTaskRegistry,
            execution: recordingRenderExecution,
            presentation: recordingRenderPresentation,
            metrics: recordingTaskMetricsReporter,
            startMigration: { [weak self] in
                self?.startPendingLensStorageMigrationIfReady()
            }
        )
    }

}

extension AppDelegate: RecordingSessionHost {}
