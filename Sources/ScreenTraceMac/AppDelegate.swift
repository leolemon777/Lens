import AppKit
import AVFoundation
import ScreenTraceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model = AppModel()
    private let store = TraceProjectStore(rootDirectory: TraceProjectStore.defaultRootDirectory)
    private let quickAccess = QuickAccessWindowController()
    private let pinnedImages = PinnedImageWindowController()
    private let pointerRecorder = PointerEventRecorder()
    private let recordingControl = RecordingControlWindowController()
    private let previewRenderer = AutoPreviewRenderer()
    private let toast = ToastWindowController()
    private let permissionCenter = PermissionCenterWindowController()
    private lazy var annotationEditor = ScreenshotAnnotationEditorWindowController(store: store)
    private lazy var traceLibrary = TraceLibraryWindowController(store: store)

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
        onOCRFailed: { [weak self] error, trace in
            self?.handleOCRFailed(error, trace: trace)
        }
    )
    private lazy var recordingService = ScreenRecordingService(
        store: store,
        pointerRecorder: pointerRecorder
    )
    private lazy var actionCenter = ActionCenterWindowController(model: model) { [weak self] action in
        self?.handle(action)
    }
    private var hotKeyManager: GlobalHotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("ScreenTrace remains ready in the menu bar.")
        configureStatusItem()
        wireControllers()
        recoverInterruptedRecordings()
        startHotKeys()
        actionCenter.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func wireControllers() {
        quickAccess.onPinRequested = { [weak self] trace, image in
            self?.pinnedImages.pin(trace: trace, image: image)
            self?.toast.show(title: "已贴在桌面", detail: "双击或按 Esc 关闭贴图", symbol: "pin.fill")
        }
        quickAccess.onAnnotateRequested = { [weak self] trace, image in
            self?.annotationEditor.show(trace: trace, fallbackImage: image)
        }
        annotationEditor.onSaved = { [weak self] trace, image in
            guard let self else { return }
            model.setRecentTrace(trace, thumbnail: image)
            quickAccess.show(trace: trace, image: image)
            traceLibrary.reloadIfVisible()
            toast.show(
                title: "标注已复制",
                detail: "对象与原图均已保留，可继续修改",
                symbol: "checkmark.circle.fill"
            )
        }
        annotationEditor.onFailure = { [weak self] error in
            self?.toast.show(
                title: "原图与标注计划仍然安全",
                detail: error.localizedDescription,
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
        recordingControl.onStop = { [weak self] in
            self?.stopRecording()
        }
        recordingControl.onPauseToggle = { [weak self] in
            self?.toggleRecordingPause()
        }
        traceLibrary.onAnnotateRequested = { [weak self] trace, image in
            self?.annotationEditor.show(trace: trace, fallbackImage: image)
        }
    }

    private func recoverInterruptedRecordings() {
        let recovered = store.recoverInterruptedRecordings()
        guard !recovered.isEmpty else { return }
        toast.show(
            title: "发现并保留了 \(recovered.count) 条中断录屏",
            detail: "原始分片未被删除，可在屏迹目录中恢复",
            symbol: "arrow.counterclockwise.circle.fill"
        )
    }

    private func startHotKeys() {
        let manager = GlobalHotKeyManager { [weak self] intent in
            switch intent {
            case .quickScreenshot:
                self?.actionCenter.hide()
                self?.captureCoordinator.beginRegionCapture()
            case .toggleActionCenter:
                if self?.recordingService.isRecording == true {
                    self?.recordingControl.showExisting()
                } else {
                    self?.actionCenter.toggle()
                }
            }
        }
        manager.start()
        hotKeyManager = manager
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = statusIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "屏迹 ScreenTrace"
        }

        let menu = NSMenu()
        menu.addItem(menuItem("打开操作中心  (fn + space)", action: #selector(toggleActionCenter)))
        menu.addItem(menuItem("区域截图  (fn + control)", action: #selector(beginScreenshot)))
        menu.addItem(menuItem("窗口截图", action: #selector(beginWindowScreenshot)))
        menu.addItem(menuItem("当前屏幕截图", action: #selector(beginDisplayScreenshot)))
        menu.addItem(menuItem("选区 OCR", action: #selector(beginOCR)))
        menu.addItem(menuItem("录制区域", action: #selector(beginRegionRecording)))
        menu.addItem(menuItem("录制窗口", action: #selector(beginWindowRecording)))
        menu.addItem(menuItem("录制当前屏幕", action: #selector(beginRecording)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开屏迹库", action: #selector(showTraceLibrary)))
        menu.addItem(menuItem("在 Finder 中打开屏迹目录", action: #selector(openTraceDirectory)))
        menu.addItem(menuItem("设置与权限", action: #selector(openSettingsAndPermissions)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出屏迹", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
        case .displayScreenshot:
            actionCenter.hide()
            captureCoordinator.beginDisplayCapture()
        case .recording:
            actionCenter.hide()
            startDisplayRecording()
        case .regionRecording:
            actionCenter.hide()
            captureCoordinator.beginRegionRecordingSelection()
        case .windowRecording:
            actionCenter.hide()
            captureCoordinator.beginWindowRecordingSelection()
        case .ocr:
            actionCenter.hide()
            captureCoordinator.beginOCRCapture()
        case .scrollingCapture:
            actionCenter.hide()
            toast.show(title: "长截图已进入 M3", detail: "将支持浏览器与普通滚动视图", symbol: "arrow.up.and.down")
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

    @objc private func beginDisplayScreenshot() {
        actionCenter.hide()
        captureCoordinator.beginDisplayCapture()
    }

    @objc private func beginOCR() {
        actionCenter.hide()
        captureCoordinator.beginOCRCapture()
    }

    @objc private func beginRecording() {
        actionCenter.hide()
        startDisplayRecording()
    }

    @objc private func beginRegionRecording() {
        actionCenter.hide()
        captureCoordinator.beginRegionRecordingSelection()
    }

    @objc private func beginWindowRecording() {
        actionCenter.hide()
        captureCoordinator.beginWindowRecordingSelection()
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
        toast.show(
            title: "原图已安全保存",
            detail: "文字识别未完成：\(error.localizedDescription)",
            symbol: "exclamationmark.arrow.triangle.2.circlepath"
        )
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
            ScreenPermission.requestOrExplain()
            return
        }
        guard !recordingService.isRecording else {
            recordingControl.showExisting()
            return
        }
        let audioSummary: String
        switch (model.capturesSystemAudio, model.capturesMicrophone) {
        case (true, true): audioSummary = "系统声音 + 麦克风分轨"
        case (true, false): audioSummary = "系统声音"
        case (false, true): audioSummary = "麦克风分轨"
        case (false, false): audioSummary = "无音频"
        }
        toast.show(
            title: "正在准备\(source.mode.presentationTitle)",
            detail: "60 FPS · \(audioSummary) · \(model.capturesCamera ? "摄像头分轨 · " : "")事件分轨",
            symbol: "record.circle"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            if model.capturesMicrophone, !(await microphoneAccessGranted()) {
                toast.show(
                    title: "麦克风尚未授权",
                    detail: "已打开权限中心；关闭麦克风后仍可继续录屏",
                    symbol: "mic.slash.fill"
                )
                permissionCenter.show()
                return
            }
            if model.capturesCamera, !(await cameraAccessGranted()) {
                toast.show(
                    title: "摄像头尚未授权",
                    detail: "已打开权限中心；关闭摄像头后仍可继续录屏",
                    symbol: "video.slash.fill"
                )
                permissionCenter.show()
                return
            }
            let options = ScreenRecordingOptions(
                framesPerSecond: 60,
                capturesSystemAudio: model.capturesSystemAudio,
                capturesMicrophone: model.capturesMicrophone,
                capturesCamera: model.capturesCamera
            )
            do {
                _ = try await recordingService.start(source: source, options: options)
                recordingControl.begin(
                    sourceTitle: source.mode.presentationTitle,
                    capturesSystemAudio: options.capturesSystemAudio,
                    capturesMicrophone: options.capturesMicrophone,
                    capturesCamera: options.capturesCamera
                )
            } catch {
                recordingControl.hide()
                showRecordingError(error)
            }
        }
    }

    private func stopRecording() {
        guard recordingService.isRecording else { return }
        toast.show(title: "正在完成原始视频", detail: "事件轨道同时写入", symbol: "hourglass")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let saved = try await recordingService.stop()
                let seconds = saved.manifest.durationSeconds ?? 0
                let trackWarnings = [
                    recordingService.lastMicrophoneError == nil ? nil : "麦克风轨道异常",
                    recordingService.lastCameraError == nil ? nil : "摄像头轨道异常"
                ].compactMap { $0 }
                let completionDetail = trackWarnings.isEmpty
                    ? "正在后台生成自然模式"
                    : "\(trackWarnings.joined(separator: "、"))；屏幕原始轨仍已保留"
                toast.show(
                    title: "录屏已安全保存",
                    detail: String(format: "%.1f 秒 · %@", seconds, completionDetail),
                    symbol: "checkmark.circle.fill"
                )
                traceLibrary.reloadIfVisible()
                await processRecording(saved)
            } catch {
                if recordingService.isRecording {
                    recordingControl.showExisting()
                } else {
                    recordingControl.hide()
                }
                showRecordingError(error)
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
                    recordingControl.setPaused(true)
                    toast.show(
                        title: "录制已暂停",
                        detail: "当前分片已安全写盘；继续时会创建新分片",
                        symbol: "pause.circle.fill"
                    )
                } else {
                    try await recordingService.resume()
                    recordingControl.setPaused(false)
                    toast.show(
                        title: "继续录制",
                        detail: "时间轴会自动跳过暂停区间",
                        symbol: "play.circle.fill"
                    )
                }
            } catch {
                recordingControl.setPaused(recordingService.isPaused)
                showRecordingError(error)
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

    private func showRecordingError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏迹无法完成录屏"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func processRecording(_ saved: SavedTrace) async {
        do {
            let plan = try store.loadAutoEditPlan(from: saved.packageURL)
            let outputURL = saved.packageURL.appendingPathComponent("previews/auto.mp4")
            let cameraURL = saved.manifest.assets.first(where: { $0.role == .camera })
                .map { saved.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            _ = try await previewRenderer.render(
                inputURL: saved.rawAssetURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                plan: plan
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
            toast.show(
                title: "自然模式预览已就绪",
                detail: {
                    if presenterWasRendered {
                        return "摄像头画中画已自动合成，原始轨仍完整保留"
                    }
                    if includesCamera {
                        return "屏幕预览已完成；摄像头原始轨仍已保留"
                    }
                    return "原始视频和自动效果均已保留"
                }(),
                symbol: "sparkles"
            )
        } catch {
            toast.show(
                title: "原始录屏已保留",
                detail: "自动成片暂未完成，稍后可以重新处理",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
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
