import AppKit
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

    private lazy var captureCoordinator = CaptureCoordinator(
        store: store,
        model: model,
        quickAccess: quickAccess,
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
        recordingControl.onStop = { [weak self] in
            self?.stopRecording()
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
        menu.addItem(menuItem("开始屏幕录制", action: #selector(beginRecording)))
        menu.addItem(.separator())
        menu.addItem(menuItem("打开屏迹目录", action: #selector(openTraceDirectory)))
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
            startRecording()
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
            openTraceDirectory()
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
        startRecording()
    }

    @objc private func openTraceDirectory() {
        try? FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.rootDirectory)
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

    private func startRecording() {
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return
        }
        guard !recordingService.isRecording else {
            recordingControl.showExisting()
            return
        }
        guard let displayID = activeDisplayID() else {
            toast.show(title: "找不到显示器", symbol: "exclamationmark.triangle")
            return
        }

        toast.show(title: "正在准备录制", detail: "60 FPS · 系统声音 · 事件分轨", symbol: "record.circle")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await recordingService.start(displayID: displayID)
                recordingControl.begin()
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
                toast.show(
                    title: "录屏已安全保存",
                    detail: String(format: "%.1f 秒 · 正在后台生成自然模式", seconds),
                    symbol: "checkmark.circle.fill"
                )
                await processRecording(saved)
            } catch {
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
            _ = try await previewRenderer.render(
                inputURL: saved.rawAssetURL,
                outputURL: outputURL,
                plan: plan
            )
            _ = try store.completeProcessing(
                packageURL: saved.packageURL,
                renderedVideoURL: outputURL
            )
            toast.show(
                title: "自然模式成片已就绪",
                detail: "原始视频和自动效果均已保留",
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
