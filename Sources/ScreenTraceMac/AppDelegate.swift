import AppKit
import AVFoundation
import ScreenTraceCore

private struct RecordingRecoveryScan: Sendable {
    let interrupted: [RecordingRecoveryCandidate]
    let pendingProcessing: [SavedTrace]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let buildIdentity = BuildIdentity.current
    private let model = AppModel()
    private let store = TraceProjectStore(rootDirectory: TraceProjectStore.defaultRootDirectory)
    private let quickAccess = QuickAccessWindowController()
    private let pinnedImages = PinnedImageWindowController()
    private let pointerRecorder = PointerEventRecorder()
    private let recordingControl = RecordingControlWindowController()
    private let previewRenderer = AutoPreviewRenderer()
    private let audioMixdownRenderer = AudioMixdownRenderer()
    private lazy var renderedEffectVerifier = RenderedEffectVerifier(
        renderer: previewRenderer
    )
    private let transcriptionService = LocalSpeechTranscriptionService()
    private let toast = ToastWindowController()
    private let diagnostics = LocalDiagnosticLog()
    private let launchHealth = LaunchHealthMonitor()
    private let crashReportScanner = ScreenTraceCrashReportScanner()
    private lazy var instanceCoordinator = ApplicationInstanceCoordinator(
        currentIdentity: buildIdentity
    )
    private lazy var permissionCenter = PermissionCenterWindowController(
        appModel: model,
        onShortcutsChanged: { [weak self] in self?.restartHotKeys() },
        diagnosticSummaryProvider: { [weak self] in
            await self?.makeDiagnosticSummary() ?? "ScreenTrace 诊断摘要\n应用尚未完成启动。"
        }
    )
    private lazy var onboarding = OnboardingWindowController(
        appModel: model,
        onQuitRequested: { NSApp.terminate(nil) },
        onFinished: { [weak self] in self?.actionCenter.show() }
    )
    private lazy var annotationEditor = ScreenshotAnnotationEditorWindowController(store: store)
    private lazy var traceLibrary = TraceLibraryWindowController(store: store)
    private lazy var videoEditor = VideoEditorWindowController(store: store)

    private lazy var captureCoordinator = CaptureCoordinator(
        store: store,
        model: model,
        quickAccess: quickAccess,
        onTraceChanged: { [weak self] in
            self?.traceLibrary.reloadIfVisible()
        },
        onRecordingSourceSelected: { [weak self] source in
            self?.startRecording(source: source)
        },
        onOCRCompleted: { [weak self] document, trace in
            self?.handleOCRCompleted(document, trace: trace)
        },
        onAutomaticOCRCompleted: { [weak self] document, trace in
            self?.beginOrganization(trace: trace, ocr: document)
        },
        onOCRFailed: { [weak self] error, trace in
            self?.handleOCRFailed(error, trace: trace)
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
        onPerformanceMeasured: { [weak self] code, metadata in
            self?.logDiagnostic(code, metadata: metadata)
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
        switch request {
        case let .action(action):
            self?.handle(action)
        case let .source(source):
            self?.startRecording(source: source)
        }
    }
    private var hotKeyManager: GlobalHotKeyManager?
    private var processingRecordingPackages: Set<URL> = []
    private var transcribingRecordingPackages: Set<URL> = []
    private var organizingTracePackages: Set<URL> = []
    private var pendingAutomaticTranscriptions: [TraceLibraryEntry] = []
    private var launchHealthSessionStarted = false
    private var didCompleteApplicationLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        ProcessInfo.processInfo.disableAutomaticTermination("ScreenTrace remains ready in the menu bar.")
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
        } else {
            actionCenter.show()
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
            alert.messageText = "正在运行的屏迹尚未退出"
            alert.informativeText = "请先停止该版本中的录屏并正常退出，然后重新打开当前版本。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if launchHealthSessionStarted {
            launchHealth.completeSession()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Permissions are granted over in System Settings and TCC sends no change
    /// notification, so the guide rechecks whenever the user comes back.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didCompleteApplicationLaunch else { return }
        onboarding.refresh()
    }

    func applicationShouldHandleReopen(
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
            model.restoreRecentTraceIfAbsent(entry, thumbnail: image)
        }
    }

    private func wireControllers() {
        quickAccess.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        pinnedImages.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        quickAccess.onPinRequested = { [weak self] trace, image in
            self?.pinnedImages.pin(trace: trace, image: image)
            self?.toast.show(
                title: "已贴在桌面",
                detail: "移入显示工具栏，右键查看更多操作，Esc 关闭",
                symbol: "pin.fill"
            )
        }
        quickAccess.onAnnotateRequested = { [weak self] trace, image in
            self?.annotationEditor.show(trace: trace, fallbackImage: image)
        }
        annotationEditor.onSaved = { [weak self] trace, image, clipboardStatus in
            guard let self else { return }
            model.setRecentTrace(trace, thumbnail: image)
            traceLibrary.reloadIfVisible()
            switch clipboardStatus {
            case .copied:
                quickAccess.show(
                    trace: trace,
                    image: image,
                    confirmationTitle: "标注已保存并复制"
                )
                showClipboardFeedback(succeeded: true, prefix: "标注已保存")
            case .copyFailed:
                quickAccess.show(
                    trace: trace,
                    image: image,
                    confirmationTitle: "标注已保存"
                )
                showClipboardFeedback(succeeded: false, prefix: "标注已保存")
            case .notRequested:
                quickAccess.show(
                    trace: trace,
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
            self?.stopRecording()
        }
        recordingControl.onPauseToggle = { [weak self] in
            self?.toggleRecordingPause()
        }
        recordingControl.onDiscardAndRestart = { [weak self] in
            self?.requestDiscardAndRestart()
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
        recordingControl.onCriticalStorage = { [weak self] availableBytes in
            guard let self, recordingService.isRecording else { return }
            logDiagnostic(
                "storage.critical",
                level: .error,
                metadata: ["storageLevel": "critical"]
            )
            let remaining = availableBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "不足 1 GB"
            recordingControl.hide()
            stopRecording(
                startTitle: "磁盘空间不足，正在安全停止",
                startDetail: "当前可用 \(remaining)；已写入的媒体分片会继续保留"
            )
        }
        traceLibrary.onAnnotateRequested = { [weak self] trace, image in
            self?.annotationEditor.show(trace: trace, fallbackImage: image)
        }
        traceLibrary.onCopyResult = { [weak self] in
            self?.showClipboardFeedback(succeeded: $0)
        }
        traceLibrary.onEditRecordingRequested = { [weak self] entry in
            self?.videoEditor.show(entry: entry)
        }
        traceLibrary.onTranscriptionRequested = { [weak self] entry in
            self?.beginTranscription(for: entry)
        }
        traceLibrary.onOrganizationRequested = { [weak self] entry in
            self?.beginOrganization(for: entry)
        }
        traceLibrary.onInsightsCustomizationRequested = { [weak self] entry, customization in
            self?.saveInsightsCustomization(for: entry, customization: customization)
        }
        traceLibrary.onRecordingRepaired = { [weak self] entry, rebuilt in
            self?.completeRecordingRepair(entry, rebuilt: rebuilt)
        }
        videoEditor.onSaved = { [weak self] saved in
            guard let self else { return }
            traceLibrary.reloadIfVisible()
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
                    traceLibrary.reloadIfVisible()
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
        traceLibrary.reloadIfVisible()
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
        if !report.issues.isEmpty {
            logDiagnostic(
                "hotkey.registration_fallback",
                level: .warning,
                metadata: ["count": String(report.issues.count)]
            )
            toast.show(
                title: "部分主快捷键被占用",
                detail: "屏迹已启用事件监听回退；Control + Option + 1/2 备用组合仍会尝试保持可用",
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

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = statusIcon()
            button.imagePosition = .imageOnly
            button.contentTintColor = recordingService.isRecording ? .systemRed : nil
            button.toolTip = recordingService.isRecording
                ? "屏迹正在录制"
                : "屏迹 ScreenTrace"
        }

        let menu = NSMenu()
        menu.addItem(menuItem(
            "打开操作中心  (\(model.actionCenterShortcut.displayName))",
            action: #selector(toggleActionCenter)
        ))
        menu.addItem(menuItem(
            "区域截图  (\(model.quickScreenshotShortcut.displayName))",
            action: #selector(beginScreenshot)
        ))
        menu.addItem(menuItem("窗口截图", action: #selector(beginWindowScreenshot)))
        menu.addItem(menuItem("多窗口截图", action: #selector(beginMultiWindowScreenshot)))
        menu.addItem(menuItem("当前屏幕截图", action: #selector(beginDisplayScreenshot)))
        menu.addItem(menuItem("选区 OCR", action: #selector(beginOCR)))
        menu.addItem(menuItem("滚动长截图", action: #selector(beginScrollingCapture)))
        let recordingWorkspaceTitle: String
        if recordingService.isRecording {
            recordingWorkspaceTitle = recordingControl.isVisible
                ? "置前录屏浮标（正在录制）"
                : "显示录屏浮标（正在录制）"
        } else {
            recordingWorkspaceTitle = "录屏工作台…"
        }
        menu.addItem(menuItem(recordingWorkspaceTitle, action: #selector(showRecordingSetup)))
        menu.addItem(menuItem("快速录制区域", action: #selector(beginRegionRecording)))
        menu.addItem(menuItem("快速录制窗口", action: #selector(beginWindowRecording)))
        menu.addItem(menuItem("快速录制当前屏幕", action: #selector(beginRecording)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开屏迹库", action: #selector(showTraceLibrary)))
        menu.addItem(menuItem("在 Finder 中打开屏迹目录", action: #selector(openTraceDirectory)))
        menu.addItem(menuItem("设置与权限", action: #selector(openSettingsAndPermissions)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出屏迹", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureApplicationMenu() {
        NSApp.mainMenu = Self.makeApplicationMainMenu(target: self)
    }

    static func makeApplicationMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu(title: "屏迹")
        let applicationMenuItem = NSMenuItem(title: "屏迹", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "屏迹")

        let aboutItem = NSMenuItem(
            title: "关于屏迹",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏屏迹",
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
            title: "退出屏迹",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = target
        applicationMenu.addItem(quitItem)

        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)
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
            accessibilityDescription: "屏迹"
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
            if let recent = model.recentTrace {
                let manifest = TraceManifest(
                    id: recent.id,
                    kind: .screenshot,
                    title: recent.title,
                    dimensions: recent.dimensions,
                    assets: [TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
                )
                pinnedImages.pin(
                    trace: SavedTrace(
                        packageURL: recent.packageURL,
                        rawAssetURL: recent.imageURL,
                        manifest: manifest
                    ),
                    image: recent.thumbnail
                )
            } else {
                toast.show(title: "还没有可贴的截图", detail: "先完成一次截图", symbol: "pin")
            }
        case .openLibrary:
            actionCenter.hide()
            traceLibrary.show()
        case .openSettings:
            actionCenter.hide()
            permissionCenter.show()
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

    @objc private func beginOCR() {
        actionCenter.hide()
        captureCoordinator.beginOCRCapture()
    }

    @objc private func beginScrollingCapture() {
        actionCenter.hide()
        captureCoordinator.beginScrollingCapture()
    }

    @objc private func beginRecording() {
        model.capturesCamera = false
        actionCenter.hide()
        startDisplayRecording()
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
        model.capturesCamera = false
        actionCenter.hide()
        captureCoordinator.beginRegionRecordingSelection()
    }

    @objc private func beginWindowRecording() {
        model.capturesCamera = false
        actionCenter.hide()
        recordingSetup.show(initialSource: .window)
    }

    @objc private func openTraceDirectory() {
        try? FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.rootDirectory)
    }

    @objc private func showTraceLibrary() {
        actionCenter.hide()
        traceLibrary.show()
    }

    @objc private func openSettingsAndPermissions() {
        actionCenter.hide()
        permissionCenter.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handleOCRCompleted(_ document: OCRDocument, trace: SavedTrace) {
        beginOrganization(trace: trace, ocr: document, announcesResult: false)
        let text = document.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            toast.show(
                title: "没有识别到文字",
                detail: "原图已保存在屏迹项目中",
                symbol: "text.magnifyingglass"
            )
            return
        }

        let firstLine = text.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? text
        let preview = firstLine.count > 42 ? String(firstLine.prefix(41)) + "…" : firstLine
        toast.show(
            title: "文字已复制",
            detail: "\(document.blocks.count) 段 · \(preview)",
            symbol: "doc.on.clipboard.fill"
        )
    }

    private func handleOCRFailed(_ error: Error, trace: SavedTrace) {
        logDiagnosticFailure("ocr.failed", error: error)
        toast.show(
            title: "原图已安全保存",
            detail: "文字识别未完成：\(error.localizedDescription)",
            symbol: "exclamationmark.arrow.triangle.2.circlepath"
        )
    }

    private func beginTranscription(
        for entry: TraceLibraryEntry,
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
                    detail: "完成后即可继续；结果会自动进入屏迹索引",
                    symbol: "waveform.badge.magnifyingglass"
                )
            }
            return
        }
        transcribingRecordingPackages.insert(packageKey)
        traceLibrary.setTranscribing(true, traceID: entry.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                transcribingRecordingPackages.remove(packageKey)
                traceLibrary.setTranscribing(false, traceID: entry.id)
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
                let saved = SavedTrace(
                    packageURL: entry.packageURL,
                    rawAssetURL: entry.primaryAssetURL,
                    manifest: entry.manifest
                )
                var updatedTrace = try store.attachTranscript(document, to: saved)
                logDiagnostic(
                    "transcription.completed",
                    metadata: ["count": String(document.segments.count)]
                )
                traceLibrary.reloadIfVisible()
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
                        updatedTrace = try store.writeAutoEditPlan(
                            plan,
                            to: entry.packageURL
                        )
                    }
                    beginOrganization(trace: updatedTrace, transcript: document)
                    if plan.captions?.isEnabled == true {
                        await processRecording(updatedTrace)
                    }
                } else {
                    beginOrganization(trace: updatedTrace, transcript: document)
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

    private func beginOrganization(for entry: TraceLibraryEntry) {
        beginOrganization(trace: SavedTrace(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        ), announcesResult: true)
    }

    private func beginOrganization(
        trace: SavedTrace,
        ocr suppliedOCR: OCRDocument? = nil,
        transcript suppliedTranscript: TranscriptDocument? = nil,
        announcesResult: Bool = false
    ) {
        let packageKey = trace.packageURL.standardizedFileURL
        guard organizingTracePackages.insert(packageKey).inserted else {
            if announcesResult {
                toast.show(
                    title: "这条屏迹正在整理",
                    detail: "完成后会自动更新标题、摘要、标签和章节",
                    symbol: "sparkles"
                )
            }
            return
        }
        traceLibrary.setOrganizing(true, traceID: trace.manifest.id)
        let store = store

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                organizingTracePackages.remove(packageKey)
                traceLibrary.setOrganizing(false, traceID: trace.manifest.id)
            }
            do {
                let insights = try await Task.detached(priority: .userInitiated) {
                    let manifest = try store.loadManifest(from: trace.packageURL)
                    let ocr = suppliedOCR ?? (try? store.loadOCR(from: trace.packageURL))
                    let transcript = suppliedTranscript
                        ?? (try? store.loadTranscript(from: trace.packageURL))
                    let previous = try? store.loadInsights(from: trace.packageURL)
                    return LocalTraceOrganizer.organize(
                        manifest: manifest,
                        ocr: ocr,
                        transcript: transcript,
                        tokenizer: NaturalLanguageTokenizer()
                    ).replacingCustomization(previous?.customization)
                }.value
                _ = try store.attachInsights(insights, to: trace)
                logDiagnostic(
                    "organization.completed",
                    metadata: ["count": String(insights.chapters.count)]
                )
                traceLibrary.reloadIfVisible()

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
        for entry: TraceLibraryEntry,
        customization: TraceInsightsCustomization?
    ) {
        do {
            let current = try store.loadInsights(from: entry.packageURL)
            let updated = current.replacingCustomization(customization)
            let saved = SavedTrace(
                packageURL: entry.packageURL,
                rawAssetURL: entry.primaryAssetURL,
                manifest: entry.manifest
            )
            _ = try store.attachInsights(updated, to: saved)
            traceLibrary.reloadIfVisible()
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
        for entry: TraceLibraryEntry
    ) throws -> (url: URL, role: TraceAsset.Role) {
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

    private func beginAutomaticTranscription(for trace: SavedTrace) {
        guard let entry = libraryEntry(for: trace) else { return }
        beginTranscription(for: entry, automatic: true)
    }

    private func libraryEntry(for trace: SavedTrace) -> TraceLibraryEntry? {
        guard let manifest = try? store.loadManifest(from: trace.packageURL),
              let primaryAsset = manifest.assets.first(where: { $0.role == .screenVideo }) else {
            return nil
        }
        let primaryURL = trace.packageURL.appendingPathComponent(primaryAsset.relativePath)
        guard FileManager.default.fileExists(atPath: primaryURL.path) else { return nil }
        let displayURL = manifest.assets
            .first(where: { $0.role == .renderedVideo })
            .map { trace.packageURL.appendingPathComponent($0.relativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? primaryURL
        let transcript = try? store.loadTranscript(from: trace.packageURL)
        let insights = try? store.loadInsights(from: trace.packageURL)
        return TraceLibraryEntry(
            packageURL: trace.packageURL,
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

    private func startDisplayRecording() {
        guard let displayID = activeDisplayID() else {
            toast.show(title: "找不到显示器", symbol: "exclamationmark.triangle")
            return
        }
        startRecording(
            source: CaptureGeometry.displayRecordingSource(
                displayID: displayID,
                displayBounds: CGDisplayBounds(displayID)
            )
        )
    }

    private func startRecording(source: RecordingCaptureSource) {
        guard ScreenPermission.hasAccess else {
            model.capturesCamera = false
            ScreenPermission.requestOrExplain()
            return
        }
        guard !recordingService.isRecording else {
            model.capturesCamera = false
            recordingControl.showExisting()
            return
        }
        let experiencePreset = model.recordingExperiencePreset
        let options = ScreenRecordingOptions(
            framesPerSecond: model.recordingFrameRate.rawValue,
            capturesSystemAudio: model.capturesSystemAudio,
            capturesMicrophone: model.capturesMicrophone,
            capturesCamera: model.capturesCamera,
            initialEditPlan: experiencePreset.makeEditPlan(
                includesCamera: model.capturesCamera
            )
        )
        // Camera is an opt-in for one recording attempt. These immutable
        // options retain the choice while every later entry starts safely off.
        model.capturesCamera = false
        let audioSummary: String
        switch (options.capturesSystemAudio, options.capturesMicrophone) {
        case (true, true): audioSummary = "系统声音 + 麦克风分轨"
        case (true, false): audioSummary = "系统声音"
        case (false, true): audioSummary = "麦克风分轨"
        case (false, false): audioSummary = "无音频"
        }
        toast.show(
            title: "正在准备\(source.mode.presentationTitle)",
            detail: "\(experiencePreset.title) · \(options.framesPerSecond) FPS · \(audioSummary) · \(options.capturesCamera ? "摄像头分轨 · " : "")正在检查智能跟踪",
            symbol: "record.circle"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            if options.capturesMicrophone, !(await microphoneAccessGranted()) {
                toast.show(
                    title: "麦克风尚未授权",
                    detail: "已打开权限中心；关闭麦克风后仍可继续录屏",
                    symbol: "mic.slash.fill"
                )
                permissionCenter.show()
                return
            }
            if options.capturesCamera, !(await cameraAccessGranted()) {
                toast.show(
                    title: "摄像头尚未授权",
                    detail: "已打开权限中心；关闭摄像头后仍可继续录屏",
                    symbol: "video.slash.fill"
                )
                permissionCenter.show()
                return
            }
            do {
                _ = try await recordingService.start(source: source, options: options)
                logDiagnostic(
                    "recording.started",
                    metadata: [
                        "captureMode": source.mode.rawValue,
                        "frameRate": String(options.framesPerSecond),
                        "eventCaptureMode": recordingService.usesEmbeddedCursorFallback
                            ? "embeddedCursorFallback"
                            : "editableEventTracks"
                    ]
                )
                recordingControl.begin(
                    sourceTitle: "\(source.mode.presentationTitle) · \(experiencePreset.title) · \(options.framesPerSecond) FPS",
                    capturesSystemAudio: options.capturesSystemAudio,
                    capturesMicrophone: options.capturesMicrophone,
                    capturesCamera: options.capturesCamera,
                    storageURL: store.rootDirectory,
                    levelProvider: { [weak self] in
                        self?.recordingService.audioLevels ?? (0, 0)
                    },
                    eventCaptureHealthProvider: { [weak self] in
                        self?.recordingService.eventCaptureSnapshot.health ?? .checking
                    },
                    capturePerformanceProvider: { [weak self] in
                        self?.recordingService.capturePerformanceSnapshot
                    }
                )
                if recordingService.usesEmbeddedCursorFallback {
                    toast.show(
                        title: "原始光标已保留",
                        detail: "输入监控当前不可用；本次不会伪造自动跟踪效果",
                        symbol: "cursorarrow.slash"
                    )
                }
            } catch {
                recordingControl.hide()
                showRecordingError(error, phase: "start")
            }
        }
    }

    private func handleUnexpectedCaptureStop(_ error: Error) {
        guard recordingService.isRecording else { return }
        logDiagnosticFailure(
            "recording.capture_stream_interrupted",
            error: error,
            metadata: ["recovery": "automaticSafeFinalize"]
        )
        stopRecording(
            startTitle: "录屏来源已中断，正在安全保存",
            startDetail: "已写入的屏幕、声音和事件分片会保留"
        )
    }

    private func handleOptionalTrackInterruption(
        _ track: RecordingOptionalTrack,
        error: Error
    ) {
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
        logDiagnosticFailure(code, error: error, metadata: ["screenCapture": "continued"])
        toast.show(title: title, detail: detail, symbol: "cable.connector.slash")
    }

    private func stopRecording(
        startTitle: String = "正在完成原始视频",
        startDetail: String = "事件轨道同时写入"
    ) {
        guard recordingService.isRecording else { return }
        let stopRequestedAt = ProcessInfo.processInfo.systemUptime
        toast.show(title: startTitle, detail: startDetail, symbol: "hourglass")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let saved = try await recordingService.stop()
                recordingControl.hide()
                let healthReport = recordingService.lastRecordingHealthReport
                    ?? (try? store.loadRecordingHealthReport(from: saved.packageURL))
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
                logDiagnostic("recording.stopped", metadata: stopMetadata)
                let shouldAutomaticallyTranscribe = model.automaticallyTranscribesRecordings
                    && saved.manifest.assets.contains {
                        $0.role == .microphone || $0.role == .systemAudio
                    }
                let seconds = saved.manifest.durationSeconds ?? 0
                let trackWarnings = [
                    recordingService.lastMicrophoneError == nil ? nil : "麦克风轨道异常",
                    recordingService.lastCameraError == nil ? nil : "摄像头轨道异常"
                ].compactMap { $0 }
                let savedPlan = try? store.loadAutoEditPlan(from: saved.packageURL)
                let presetTitle = savedPlan.flatMap {
                    RecordingExperiencePreset(rawValue: $0.preset)?.title
                } ?? "自然成片"
                var completionNotes = trackWarnings
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
                }
                if healthReport?.warnings.contains(
                    .cameraMotionMayCauseDiscomfort
                ) == true {
                    completionNotes.append("运镜舒适度需复核")
                }
                let completionDetail = completionNotes.isEmpty
                    ? "原片现在可播放 · 正在后台生成\(presetTitle)"
                    : "\(completionNotes.joined(separator: "、"))；原始录屏已保留"
                toast.show(
                    title: "录屏已安全保存",
                    detail: String(format: "%.1f 秒 · %@", seconds, completionDetail),
                    symbol: "checkmark.circle.fill"
                )
                traceLibrary.reloadIfVisible()
                let rawPreviewStartedAt = ProcessInfo.processInfo.systemUptime
                if let entry = libraryEntry(for: saved) {
                    videoEditor.show(entry: entry)
                    logDiagnostic(
                        "editor.raw_preview_opened",
                        metadata: [
                            "durationMilliseconds": Self.performanceMilliseconds(
                                since: rawPreviewStartedAt
                            )
                        ]
                    )
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let renderedPlan = await processRecording(saved)
                    if let renderedPlan,
                       let entry = libraryEntry(for: saved) {
                        _ = videoEditor.adoptBackgroundPreview(
                            entry: entry,
                            renderedPlan: renderedPlan
                        )
                    }
                    if shouldAutomaticallyTranscribe {
                        beginAutomaticTranscription(for: saved)
                    }
                }
            } catch {
                if recordingService.isRecording {
                    recordingControl.setTransitioning(false)
                    recordingControl.showExisting()
                } else {
                    recordingControl.hide()
                }
                showRecordingError(error, phase: "stop")
            }
        }
    }

    private func toggleRecordingPause() {
        guard recordingService.isRecording else { return }
        let shouldPause = !recordingService.isPaused
        recordingControl.setTransitioning(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { recordingControl.setTransitioning(false) }
            do {
                if shouldPause {
                    try await recordingService.pause()
                    logDiagnostic("recording.paused")
                    recordingControl.setPaused(true)
                    toast.show(
                        title: "录制已暂停",
                        detail: "当前分片已安全写盘；继续时会创建新分片",
                        symbol: "pause.circle.fill"
                    )
                } else {
                    try await recordingService.resume()
                    logDiagnostic("recording.resumed")
                    recordingControl.setPaused(false)
                    toast.show(
                        title: "继续录制",
                        detail: "时间轴会自动跳过暂停区间",
                        symbol: "play.circle.fill"
                    )
                }
            } catch {
                recordingControl.setPaused(recordingService.isPaused)
                showRecordingError(error, phase: shouldPause ? "pause" : "resume")
            }
        }
    }

    private func requestDiscardAndRestart() {
        guard recordingService.isRecording else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "丢弃并重新录制？"
        alert.informativeText = "屏迹会先安全停止当前录制，再把整个项目移入废纸篓。文件不会被永久删除。"
        alert.addButton(withTitle: "移到废纸篓并重录")
        alert.addButton(withTitle: "继续录制")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        recordingControl.setTransitioning(true)
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
                try FileManager.default.trashItem(
                    at: discarded.packageURL,
                    resultingItemURL: nil
                )
                traceLibrary.reloadIfVisible()
                toast.show(
                    title: "旧录制已移到废纸篓",
                    detail: "正在按相同来源重新准备录制",
                    symbol: "arrow.counterclockwise.circle.fill"
                )
                startRecording(source: discarded.source)
            } catch {
                logDiagnosticFailure(
                    "recording.discard_restart_failed",
                    error: error,
                    metadata: ["phase": "discard"]
                )
                recordingControl.hide()
                traceLibrary.reloadIfVisible()
                toast.show(
                    title: "没有删除录制项目",
                    detail: "录制已停止并尽量保留为可恢复项目：\(error.localizedDescription)",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath"
                )
            }
        }
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

    private func microphoneAccessGranted() async -> Bool {
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

    private func cameraAccessGranted() async -> Bool {
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

    private func logDiagnostic(
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

    private func showRecordingError(_ error: Error, phase: String) {
        logDiagnosticFailure(
            "recording.failed",
            error: error,
            metadata: ["phase": phase]
        )
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏迹无法完成录屏"
        alert.informativeText = StorageRecoveryGuidance.detail(for: error)
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// A rebuilt recording is longer than the plan and preview that were
    /// generated for it, so both are regenerated from the merged media before
    /// the user opens it.
    private func completeRecordingRepair(
        _ entry: TraceLibraryEntry,
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
        Task { @MainActor [weak self] in
            guard let self,
                  let manifest = try? store.loadManifest(from: rebuilt.packageURL)
            else { return }
            let saved = SavedTrace(
                packageURL: rebuilt.packageURL,
                rawAssetURL: rebuilt.packageURL
                    .appendingPathComponent("raw/screen.mp4"),
                manifest: manifest
            )
            _ = await processRecording(saved)
            traceLibrary.reloadIfVisible()
        }
    }

    @discardableResult
    private func processRecording(_ saved: SavedTrace) async -> AutoEditPlan? {
        let processingStartedAt = ProcessInfo.processInfo.systemUptime
        let packageKey = saved.packageURL.standardizedFileURL
        while processingRecordingPackages.contains(packageKey) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
            } catch {
                return nil
            }
        }
        processingRecordingPackages.insert(packageKey)
        defer { processingRecordingPackages.remove(packageKey) }
        do {
            let plan = try store.loadAutoEditPlan(from: saved.packageURL)
            var healthReport = try? store.loadRecordingHealthReport(from: saved.packageURL)
            let outputURL = saved.packageURL.appendingPathComponent("previews/auto.mp4")
            let cameraURL = saved.manifest.assets.first(where: { $0.role == .camera })
                .map { saved.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let transcript = plan.captions?.isEnabled == true
                ? try? store.loadTranscript(from: saved.packageURL)
                : nil
            _ = try await previewRenderer.render(
                inputURL: saved.rawAssetURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                plan: plan,
                transcript: transcript
            )
            let microphoneURL = saved.manifest.assets.first(where: { $0.role == .microphone })
                .map { saved.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            var audioMixError: Error?
            var microphoneWasMixed = false
            var voiceProcessingFellBack = false
            if let audioPlan = plan.audio,
               AudioMixdownRenderer.requiresMixdown(
                   microphoneURL: microphoneURL,
                   plan: audioPlan
               ) {
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
            _ = try? store.writeRecordingHealthReport(
                verifiedHealthReport,
                to: saved.packageURL
            )
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
            _ = try store.completeProcessing(
                packageURL: saved.packageURL,
                renderedVideoURL: outputURL
            )
            traceLibrary.reloadIfVisible()
            let includesCamera = saved.manifest.assets.contains { $0.role == .camera }
            let presenterWasRendered = plan.presenterCamera?.isEnabled == true
                && cameraURL != nil
                && previewRenderer.lastPresenterCameraError == nil
            let includesMicrophone = saved.manifest.assets.contains { $0.role == .microphone }
            let presetTitle = RecordingExperiencePreset(rawValue: plan.preset)?.title
                ?? "自然成片"
            toast.show(
                title: renderedEffectVerification.isVerified
                    ? "\(presetTitle)预览已验证"
                    : "\(presetTitle)预览需复核",
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
                symbol: renderedEffectVerification.isVerified
                    ? "checkmark.seal.fill"
                    : "exclamationmark.magnifyingglass"
            )
            logDiagnostic(
                "preview.completed",
                metadata: [
                    "durationMilliseconds": Self.performanceMilliseconds(
                        since: processingStartedAt
                    )
                ]
            )
            return plan
        } catch {
            logDiagnosticFailure("preview.failed", error: error)
            toast.show(
                title: "原始录屏已保留",
                detail: "自动成片暂未完成，稍后可以重新处理",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
            return nil
        }
    }
}

private extension RecordingCaptureMode {
    var presentationTitle: String {
        switch self {
        case .region: "区域录制"
        case .window: "窗口录制"
        case .display: "屏幕录制"
        }
    }
}
