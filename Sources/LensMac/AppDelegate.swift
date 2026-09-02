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
    private let store = LensProjectStore(rootDirectory: LensProjectStore.defaultRootDirectory)
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
        diagnosticSummaryProvider: { [weak self] in
            await self?.makeDiagnosticSummary() ?? "Lens 诊断摘要\n应用尚未完成启动。"
        }
    )
    private lazy var onboarding = OnboardingWindowController(
        appModel: model,
        onQuitRequested: { NSApp.terminate(nil) },
        onFinished: { [weak self] in self?.actionCenter.show() }
    )
    private lazy var annotationEditor = ScreenshotAnnotationEditorWindowController(store: store)
    private lazy var lensLibrary = LensLibraryWindowController(store: store)
    private lazy var videoEditor = VideoEditorWindowController(store: store)

    private lazy var captureCoordinator = CaptureCoordinator(
        store: store,
        model: model,
        quickAccess: quickAccess,
        onLensChanged: { [weak self] in
            self?.lensLibrary.reloadIfVisible()
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
    private let recordingProcessingGate = RecordingProcessingGate()
    private var transcribingRecordingPackages: Set<URL> = []
    private var organizingLensPackages: Set<URL> = []
    private var pendingAutomaticTranscriptions: [LensLibraryEntry] = []
    private var launchHealthSessionStarted = false
    private var didCompleteApplicationLaunch = false
    private let recordingSession = RecordingSessionCoordinator()
    private var recordingProcessingTasks: [URL: Task<Void, Never>] = [:]
    private var recordingRenderTasks: [URL: Task<AutoEditPlan?, Never>] = [:]

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

    private func resumeRecordingRecovery(_ scan: RecordingRecoveryScan) async {
        let store = self.store
        let recovered = scan.interrupted
        let pendingProcessing = scan.pendingProcessing
        guard !recovered.isEmpty || !pendingProcessing.isEmpty else { return }
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
            lensLibrary.show()
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
        actionCenter.hide()
        lensLibrary.show()
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

    private func beginTranscription(
        for entry: LensLibraryEntry,
        automatic: Bool = false
    ) {
        let packageKey = entry.packageURL.standardizedFileURL
        guard !transcribingRecordingPackages.contains(packageKey),
              !pendingAutomaticTranscriptions.contains(where: { $0.id == entry.id }) else {
            if !automatic {
                toast.show(
                    title: "这条录屏已经在转写队列中",
                    detail: "完成后会自动生成字幕与整理结果",
                    symbol: "waveform.badge.magnifyingglass"
                )
            }
            return
        }
        guard transcribingRecordingPackages.isEmpty else {
            if automatic {
                pendingAutomaticTranscriptions.append(entry)
            } else {
                toast.show(
                    title: "另一条本机转写仍在进行",
                    detail: "完成后即可继续；结果会自动进入 Lens 索引",
                    symbol: "waveform.badge.magnifyingglass"
                )
            }
            return
        }
        transcribingRecordingPackages.insert(packageKey)
        lensLibrary.setTranscribing(true, lensID: entry.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                transcribingRecordingPackages.remove(packageKey)
                lensLibrary.setTranscribing(false, lensID: entry.id)
                if !pendingAutomaticTranscriptions.isEmpty {
                    let next = pendingAutomaticTranscriptions.removeFirst()
                    beginTranscription(for: next, automatic: true)
                }
            }
            do {
                var status = LocalSpeechTranscriptionService.authorizationStatus
                if status == .notDetermined {
                    status = await LocalSpeechTranscriptionService.requestAuthorization()
                }
                switch status {
                case .authorized:
                    break
                case .denied, .notDetermined:
                    permissionCenter.show()
                    throw LocalSpeechTranscriptionError.authorizationDenied
                case .restricted:
                    permissionCenter.show()
                    throw LocalSpeechTranscriptionError.authorizationRestricted
                @unknown default:
                    throw LocalSpeechTranscriptionError.authorizationRestricted
                }

                let source = try transcriptionSource(for: entry)
                toast.show(
                    title: "正在本机生成转写",
                    detail: "不会上传录屏或声音；完成后可直接搜索文字",
                    symbol: "waveform.badge.magnifyingglass"
                )
                let document = try await transcriptionService.transcribe(
                    audioURL: source.url,
                    localeIdentifier: model.transcriptionLanguage.localeIdentifier,
                    sourceRole: source.role
                )
                let saved = SavedLens(
                    packageURL: entry.packageURL,
                    rawAssetURL: entry.primaryAssetURL,
                    manifest: entry.manifest
                )
                var updatedLens = try store.attachTranscript(document, to: saved)
                logDiagnostic(
                    "transcription.completed",
                    metadata: ["count": String(document.segments.count)]
                )
                lensLibrary.reloadIfVisible()
                let trimmed = document.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                toast.show(
                    title: trimmed.isEmpty ? "没有识别到讲解" : "本机转写已完成",
                    detail: trimmed.isEmpty
                        ? "录屏与原始音轨保持不变"
                        : "\(document.segments.count) 个时间片段 · 已加入本地搜索",
                    symbol: trimmed.isEmpty ? "text.magnifyingglass" : "captions.bubble.fill"
                )
                if !trimmed.isEmpty {
                    var plan = try store.loadAutoEditPlan(from: entry.packageURL)
                    let isFirstTranscript = entry.transcriptText?.isEmpty != false
                    if isFirstTranscript {
                        if plan.captions == nil { plan.captions = .init() }
                        plan.captions?.isEnabled = true
                        updatedLens = try store.writeAutoEditPlan(
                            plan,
                            to: entry.packageURL
                        )
                    }
                    beginOrganization(lens: updatedLens, transcript: document)
                    if plan.captions?.isEnabled == true {
                        await processRecording(updatedLens)
                    }
                } else {
                    beginOrganization(lens: updatedLens, transcript: document)
                }
            } catch is CancellationError {
                logDiagnostic("transcription.cancelled", level: .warning)
                toast.show(
                    title: "转写已取消",
                    detail: "录屏与原始音轨保持不变",
                    symbol: "xmark.circle"
                )
            } catch {
                logDiagnosticFailure("transcription.failed", error: error)
                toast.show(
                    title: "原始录屏仍然安全",
                    detail: "本机转写未完成：\(error.localizedDescription)",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath"
                )
            }
        }
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
        let packageKey = lens.packageURL.standardizedFileURL
        guard organizingLensPackages.insert(packageKey).inserted else {
            if announcesResult {
                toast.show(
                    title: "这条 Lens 正在整理",
                    detail: "完成后会自动更新标题、摘要、标签和章节",
                    symbol: "sparkles"
                )
            }
            return
        }
        lensLibrary.setOrganizing(true, lensID: lens.manifest.id)
        let store = store
        let diagnostics = diagnostics

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                organizingLensPackages.remove(packageKey)
                lensLibrary.setOrganizing(false, lensID: lens.manifest.id)
            }
            do {
                let insights = try await Task.detached(priority: .userInitiated) {
                    let manifest = try store.loadManifest(from: lens.packageURL)
                    let ocr: OCRDocument?
                    if let suppliedOCR {
                        ocr = suppliedOCR
                    } else {
                        do {
                            ocr = try store.loadOCR(from: lens.packageURL)
                        } catch {
                            await diagnostics.record(
                                "organization.ocr_load_failed",
                                level: .warning,
                                metadata: DiagnosticEvent.errorMetadata(error)
                            )
                            ocr = nil
                        }
                    }
                    let transcript: TranscriptDocument?
                    if let suppliedTranscript {
                        transcript = suppliedTranscript
                    } else {
                        do {
                            transcript = try store.loadTranscript(from: lens.packageURL)
                        } catch {
                            await diagnostics.record(
                                "organization.transcript_load_failed",
                                level: .warning,
                                metadata: DiagnosticEvent.errorMetadata(error)
                            )
                            transcript = nil
                        }
                    }
                    let previous: LensInsightsDocument?
                    do {
                        previous = try store.loadInsights(from: lens.packageURL)
                    } catch {
                        await diagnostics.record(
                            "organization.insights_load_failed",
                            level: .warning,
                            metadata: DiagnosticEvent.errorMetadata(error)
                        )
                        previous = nil
                    }
                    return LocalLensOrganizer.organize(
                        manifest: manifest,
                        ocr: ocr,
                        transcript: transcript,
                        tokenizer: NaturalLanguageTokenizer()
                    ).replacingCustomization(previous?.customization)
                }.value
                _ = try store.attachInsights(insights, to: lens)
                logDiagnostic(
                    "organization.completed",
                    metadata: ["count": String(insights.chapters.count)]
                )
                lensLibrary.reloadIfVisible()

                var details: [String] = []
                if !insights.tags.isEmpty {
                    details.append(insights.tags.prefix(3).joined(separator: "、"))
                }
                if !insights.chapters.isEmpty {
                    details.append("\(insights.chapters.count) 个章节")
                }
                if !insights.sensitiveFindings.isEmpty {
                    details.append("\(insights.sensitiveFindings.count) 项敏感信息提示")
                }
                if announcesResult {
                    toast.show(
                        title: "本地整理已完成",
                        detail: details.isEmpty
                            ? "标题与内容索引已更新"
                            : details.joined(separator: " · "),
                        symbol: "sparkles.rectangle.stack.fill"
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                logDiagnosticFailure("organization.failed", error: error)
                if announcesResult {
                    toast.show(
                        title: "原始内容仍然安全",
                        detail: "本地整理未完成：\(error.localizedDescription)",
                        symbol: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                }
            }
        }
    }

    private func saveInsightsCustomization(
        for entry: LensLibraryEntry,
        customization: LensInsightsCustomization?
    ) {
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

    private static func performanceMilliseconds(since startedAt: TimeInterval) -> String {
        String(format: "%.3f", max(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            0
        ))
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
        let packageKey = saved.packageURL.standardizedFileURL
        recordingRenderTasks[packageKey]?.cancel()
        let task = Task { @MainActor [weak self] in
            await self?.performProcessRecording(saved)
        }
        recordingRenderTasks[packageKey] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if recordingRenderTasks[packageKey] == task {
            recordingRenderTasks[packageKey] = nil
        }
        return result
    }

    func trackProcessingTask(_ task: Task<Void, Never>, for packageURL: URL) {
        let packageKey = packageURL.standardizedFileURL
        recordingProcessingTasks[packageKey]?.cancel()
        recordingProcessingTasks[packageKey] = task
        Task { @MainActor [weak self] in
            await task.value
            if self?.recordingProcessingTasks[packageKey] == task {
                self?.recordingProcessingTasks[packageKey] = nil
            }
        }
    }

    func cancelRecordingProcessing(for packageURL: URL) {
        let packageKey = packageURL.standardizedFileURL
        recordingProcessingTasks[packageKey]?.cancel()
        recordingRenderTasks[packageKey]?.cancel()
    }

    @discardableResult
    private func performProcessRecording(_ saved: SavedLens) async -> AutoEditPlan? {
        let processingStartedAt = ProcessInfo.processInfo.systemUptime
        let packageKey = saved.packageURL.standardizedFileURL
        await recordingProcessingGate.acquire(packageKey)
        defer { Task { await recordingProcessingGate.release(packageKey) } }
        do {
            let plan = try store.loadAutoEditPlan(from: saved.packageURL)
            try Task.checkCancellation()
            var healthReport: RecordingHealthReport?
            do {
                healthReport = try store.loadRecordingHealthReport(from: saved.packageURL)
            } catch {
                logDiagnostic(
                    "preview.health_report_load_failed",
                    level: .warning,
                    metadata: DiagnosticEvent.errorMetadata(error)
                )
            }
            let outputURL = saved.packageURL.appendingPathComponent("previews/auto.mp4")
            let cameraURL = saved.manifest.assets.first(where: { $0.role == .camera })
                .map { saved.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let transcript: TranscriptDocument?
            if plan.captions?.isEnabled == true {
                do {
                    transcript = try store.loadTranscript(from: saved.packageURL)
                } catch {
                    logDiagnostic(
                        "preview.transcript_load_failed",
                        level: .warning,
                        metadata: DiagnosticEvent.errorMetadata(error)
                    )
                    transcript = nil
                }
            } else {
                transcript = nil
            }
            let microphoneURL = saved.manifest.assets.first(where: { $0.role == .microphone })
                .map { saved.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            var audioMixError: Error?
            var microphoneWasMixed = false
            var voiceProcessingFellBack = false
            let requiresAudioMixdown = plan.audio.map { audioPlan in
                AudioMixdownRenderer.requiresMixdown(
                    microphoneURL: microphoneURL,
                    plan: audioPlan
                )
            } ?? false
            // Single pass: prepare the narration/system mix as audio only,
            // then the effects render embeds it during its only video encode.
            // A sidecar failure falls back to the legacy two-pass mix below
            // rather than failing the preview.
            let mixedAudioSidecarURL = requiresAudioMixdown
                ? saved.packageURL.appendingPathComponent(
                    "previews/.audio-mix-\(UUID().uuidString).caf"
                )
                : nil
            var mixedAudioReady = false
            // Two-segment overall progress (audio 0–15%, video 15–100%,
            // or a plain 0–100% when no mixdown runs at all) so the panel
            // reflects one continuous number across both renderers instead
            // of restarting when the video pass begins.
            if let mixedAudioSidecarURL, let audioPlan = plan.audio {
                defer { try? FileManager.default.removeItem(at: mixedAudioSidecarURL) }
                do {
                    let mixReport = try await audioMixdownRenderer.prepareMixedAudioSidecar(
                        sourceURL: saved.rawAssetURL,
                        microphoneURL: microphoneURL,
                        outputURL: mixedAudioSidecarURL,
                        plan: audioPlan,
                        timeline: plan.timeline,
                        progress: { [weak self] fraction in
                            Task { @MainActor in
                                self?.quickAccess.updateProgress(fraction * 0.15, for: saved)
                                self?.videoEditor.updateProcessingProgress(
                                    fraction * 0.15,
                                    packageURL: saved.packageURL
                                )
                            }
                        }
                    )
                    voiceProcessingFellBack = mixReport
                        .voiceProcessingErrorDescription != nil
                    microphoneWasMixed = microphoneURL != nil
                    mixedAudioReady = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    audioMixError = error
                }
            }
            let videoProgressBase = requiresAudioMixdown ? 0.15 : 0.0
            let videoProgressScale = requiresAudioMixdown ? 0.85 : 1.0
            try Task.checkCancellation()
            _ = try await previewRenderer.render(
                inputURL: saved.rawAssetURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                plan: plan,
                transcript: transcript,
                mixedAudioURL: mixedAudioReady ? mixedAudioSidecarURL : nil,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.quickAccess.updateProgress(
                            videoProgressBase + fraction * videoProgressScale,
                            for: saved
                        )
                        self?.videoEditor.updateProcessingProgress(
                            videoProgressBase + fraction * videoProgressScale,
                            packageURL: saved.packageURL
                        )
                    }
                }
            )
            if requiresAudioMixdown, !mixedAudioReady, let audioPlan = plan.audio {
                let mixedURL = saved.packageURL.appendingPathComponent(
                    "previews/.auto-mixed-\(UUID().uuidString).mp4"
                )
                defer { try? FileManager.default.removeItem(at: mixedURL) }
                do {
                    let mixReport = try await audioMixdownRenderer.renderWithReport(
                        inputURL: outputURL,
                        microphoneURL: microphoneURL,
                        outputURL: mixedURL,
                        plan: audioPlan,
                        timeline: plan.timeline,
                        export: plan.export
                    )
                    voiceProcessingFellBack = mixReport
                        .voiceProcessingErrorDescription != nil
                    _ = try FileManager.default.replaceItemAt(
                        outputURL,
                        withItemAt: mixedURL
                    )
                    microphoneWasMixed = microphoneURL != nil
                    audioMixError = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    audioMixError = error
                }
            }
            let renderedEffectVerification = await renderedEffectVerifier.validate(
                rawURL: saved.rawAssetURL,
                previewURL: outputURL,
                plan: plan,
                cameraURL: cameraURL,
                microphoneURL: microphoneURL,
                transcript: transcript
            )
            let renderedPlanDigest = try RenderedPlanIdentity.digest(
                for: plan,
                transcript: transcript
            )
            let baseHealthReport = healthReport ?? RecordingHealthReport(
                requestedFramesPerSecond: saved.manifest.captureSource?
                    .effectiveRequestedFramesPerSecond
                    ?? Int((renderedEffectVerification.rawMeasuredFramesPerSecond ?? 30).rounded()),
                measuredFramesPerSecond: renderedEffectVerification
                    .rawMeasuredFramesPerSecond,
                p95FrameIntervalMilliseconds: nil,
                droppedFrameCount: 0,
                videoStatus: renderedEffectVerification.rawMeasuredFramesPerSecond == nil
                    ? .notMeasured
                    : .healthy,
                eventStatus: .notMeasured,
                pointerEventCount: 0,
                clickEventCount: 0,
                keyboardEventCount: 0,
                windowEventCount: 0,
                effectiveCameraKeyframeCount: plan.camera.keyframes.filter {
                    $0.reason != .baseline
                }.count,
                cursorKeyframeCount: plan.cursor.keyframes.count,
                clickPulseCount: plan.interaction?.clickPulses.count ?? 0,
                warnings: []
            )
            let verifiedHealthReport = baseHealthReport
                .addingRenderedEffectVerification(
                    renderedEffectVerification,
                    renderedPlanDigest: renderedPlanDigest
                )
            healthReport = verifiedHealthReport
            do {
                _ = try store.writeRecordingHealthReport(
                    verifiedHealthReport,
                    to: saved.packageURL
                )
            } catch {
                logDiagnosticFailure("preview.health_report_write_failed", error: error)
            }
            logDiagnostic(
                "preview.effects_verified",
                level: renderedEffectVerification.isVerified ? .info : .warning,
                metadata: [
                    "status": renderedEffectVerification.isVerified
                        ? "verified"
                        : "needsReview",
                    "verifiedEffects": renderedEffectVerification.verifiedEffects
                        .map(\.rawValue)
                        .joined(separator: ","),
                    "previewFramesPerSecond": renderedEffectVerification
                        .previewMeasuredFramesPerSecond
                        .map { String(format: "%.2f", $0) } ?? "unavailable"
                ]
            )
            let updated = try store.completeProcessing(
                packageURL: saved.packageURL,
                renderedVideoURL: outputURL
            )
            lensLibrary.reloadIfVisible()
            // A completed render is the one moment worth surfacing actual
            // speed as a visible advantage rather than just a checkmark.
            let renderedSeconds = max(
                ProcessInfo.processInfo.systemUptime - processingStartedAt,
                0
            )
            let quickAccessConfirmation = renderedEffectVerification.isVerified
                ? String(format: "成片已可发送 · %.1f 秒", renderedSeconds)
                : "成片已生成 · 建议复核"
            quickAccess.updateIfShowing(
                updated,
                thumbnail: deliveryImage(for: updated),
                confirmationTitle: quickAccessConfirmation,
                deliveryState: renderedEffectVerification.isVerified
                    ? .ready
                    : .needsReview
            )
            let includesCamera = saved.manifest.assets.contains { $0.role == .camera }
            let presenterWasRendered = plan.presenterCamera?.isEnabled == true
                && cameraURL != nil
                && previewRenderer.lastPresenterCameraError == nil
            let includesMicrophone = saved.manifest.assets.contains { $0.role == .microphone }
            let presetTitle = RecordingExperiencePreset(rawValue: plan.preset)?.title
                ?? "自然成片"
            if !renderedEffectVerification.isVerified {
            toast.show(
                title: "\(presetTitle)预览需复核",
                detail: {
                    var completedEffects = healthReport?.completedSmartEffects ?? [
                        plan.camera.keyframes.contains { $0.reason != .baseline }
                            ? "自动运镜" : nil,
                        plan.cursor.keyframes.isEmpty ? nil : "平滑光标",
                        plan.interaction?.clickPulses.isEmpty == false ? "点击反馈" : nil
                    ].compactMap { $0 }
                    completedEffects = Array(NSOrderedSet(array: completedEffects))
                        .compactMap { $0 as? String }
                    let unverifiedEffects = renderedEffectVerification.effects.compactMap {
                        $0.state == .failed || $0.state == .inconclusive
                            ? $0.effect.title
                            : nil
                    }
                    var verificationNotes: [String] = []
                    if !unverifiedEffects.isEmpty {
                        verificationNotes.append(
                            "\(unverifiedEffects.joined(separator: "、"))未通过媒体验证"
                        )
                    }
                    if !renderedEffectVerification.isFrameRateVerified {
                        verificationNotes.append("成片帧率未达交付门槛")
                    }
                    if microphoneWasMixed, voiceProcessingFellBack {
                        verificationNotes.append("旁白降噪失败，已保留原声混音")
                    }
                    var preservedTracks: [String] = []
                    if includesCamera {
                        if cameraURL == nil {
                            verificationNotes.append("摄像头原始轨缺失")
                        } else if !presenterWasRendered {
                            preservedTracks.append("摄像头")
                        }
                    }
                    if includesMicrophone {
                        if microphoneURL == nil {
                            verificationNotes.append("麦克风原始轨缺失")
                        } else if !microphoneWasMixed {
                            preservedTracks.append("麦克风")
                        }
                    }
                    if !preservedTracks.isEmpty {
                        let reason = audioMixError == nil ? "未叠加" : "混音未完成"
                        let effects = completedEffects.isEmpty
                            ? "基础预览已完成"
                            : "\(completedEffects.joined(separator: "、"))已完成"
                        let notes = verificationNotes.isEmpty
                            ? ""
                            : "；\(verificationNotes.joined(separator: "、"))"
                        return "\(effects)；\(preservedTracks.joined(separator: "、"))原始轨已保留（\(reason)）\(notes)"
                    }
                    if completedEffects.isEmpty {
                        if !verificationNotes.isEmpty {
                            return "预览已生成；\(verificationNotes.joined(separator: "、"))，原始轨已保留"
                        }
                        return "基础预览已完成；本次未请求智能效果，原始轨已保留"
                    }
                    let notes = verificationNotes.isEmpty
                        ? ""
                        : "；\(verificationNotes.joined(separator: "、"))"
                    return "\(completedEffects.joined(separator: "、"))已完成，全部原始轨仍完整保留\(notes)"
                }(),
                symbol: "exclamationmark.magnifyingglass"
            )
            }
            logDiagnostic(
                "preview.completed",
                metadata: [
                    "durationMilliseconds": Self.performanceMilliseconds(
                        since: processingStartedAt
                    )
                ]
            )
            return plan
        } catch is CancellationError {
            logDiagnostic("preview.cancelled", level: .warning)
            quickAccess.updateIfShowing(
                saved,
                thumbnail: deliveryImage(for: saved),
                confirmationTitle: "成片生成已取消",
                deliveryState: .failed
            )
            return nil
        } catch {
            logDiagnosticFailure("preview.failed", error: error)
            quickAccess.updateIfShowing(
                saved,
                thumbnail: deliveryImage(for: saved),
                confirmationTitle: "原始录屏已保留 · 成片稍后重试",
                deliveryState: .failed
            )
            toast.show(
                title: "原始录屏已保留",
                detail: "自动成片暂未完成，稍后可以重新处理",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
            return nil
        }
    }
}

extension AppDelegate: RecordingSessionHost {}
