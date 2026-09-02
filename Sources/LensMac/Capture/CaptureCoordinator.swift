import AppKit
import CoreGraphics
import LensCore

@MainActor
final class CaptureCoordinator: CaptureOverlayViewDelegate {
    private enum CapturePurpose: Equatable {
        case screenshot
        case conversationInbox
        case multiWindowScreenshot
        case ocr
        case scrollingCapture
        case recordingRegion
        case recordingWindow
    }

    private enum OCRDelivery {
        case interactive
        case automatic
    }

    private let store: LensProjectStore
    private let model: AppModel
    private let quickAccess: QuickAccessWindowController
    private let onLensChanged: () -> Void
    private let onRecordingSourceSelected: (RecordingCaptureSource, Bool) -> Void
    private let onOCRStarted: (SavedLens, NSImage) -> Void
    private let onOCRCompleted: (OCRDocument, SavedLens) -> Void
    private let onAutomaticOCRCompleted: (OCRDocument, SavedLens) -> Void
    private let onOCRFailed: (Error, SavedLens) -> Void
    private let onScrollingCaptureCompleted: (Int, Int, Error?) -> Void
    private let onScrollingCaptureFailed: (Error) -> Void
    private let onConversationInboxSaved: (ConversationInboxSnapshot, Bool) -> Void
    private let onPerformanceMeasured: (String, [String: String]) -> Void
    private let onCaptureFailed: (String) -> Void
    private let onMagnifierHexCopied: (String) -> Void
    private let captureService = ScreenCaptureService()
    private let ocrService = VisionOCRService()
    private let scrollingCapture = ScrollingCaptureSessionController()
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var overlayGeneration: UInt64 = 0
    private var windowTargets: [CGWindowID: WindowCaptureTarget] = [:]
    private var selectedWindowIDs: Set<CGWindowID> = []
    private var pendingPurpose: CapturePurpose = .screenshot
    /// One-shot camera opt-in for the in-flight region/window recording
    /// selection. Cancel clears it so a later quick recording cannot inherit it.
    private var pendingRecordingCapturesCamera = false
    private var isPreparingCapture = false
    private var isFinishingCapture = false
    private var cachedRegionSnapRects: [CGRect] = []
    private var cachedRegionSnapRectsAt: TimeInterval = -.infinity
    private var isPrewarmingRegionSnapRects = false
    /// Only ever written on the main actor, and only read again by `deinit`,
    /// which by definition holds the last reference and cannot race with it.
    /// The token itself is not `Sendable`, so it needs the explicit opt out to
    /// be readable from a nonisolated `deinit`.
    private nonisolated(unsafe) var applicationActivationObserver: NSObjectProtocol?

    private static let regionSnapRectCachePolicy = RegionSnapRectCachePolicy.standard

    init(
        store: LensProjectStore,
        model: AppModel,
        quickAccess: QuickAccessWindowController,
        onLensChanged: @escaping () -> Void,
        onRecordingSourceSelected: @escaping (RecordingCaptureSource, Bool) -> Void,
        onOCRStarted: @escaping (SavedLens, NSImage) -> Void,
        onOCRCompleted: @escaping (OCRDocument, SavedLens) -> Void,
        onAutomaticOCRCompleted: @escaping (OCRDocument, SavedLens) -> Void,
        onOCRFailed: @escaping (Error, SavedLens) -> Void,
        onScrollingCaptureCompleted: @escaping (Int, Int, Error?) -> Void,
        onScrollingCaptureFailed: @escaping (Error) -> Void,
        onConversationInboxSaved: @escaping (ConversationInboxSnapshot, Bool) -> Void,
        onPerformanceMeasured: @escaping (String, [String: String]) -> Void,
        onCaptureFailed: @escaping (String) -> Void,
        onMagnifierHexCopied: @escaping (String) -> Void
    ) {
        self.store = store
        self.model = model
        self.quickAccess = quickAccess
        self.onLensChanged = onLensChanged
        self.onRecordingSourceSelected = onRecordingSourceSelected
        self.onOCRStarted = onOCRStarted
        self.onOCRCompleted = onOCRCompleted
        self.onAutomaticOCRCompleted = onAutomaticOCRCompleted
        self.onOCRFailed = onOCRFailed
        self.onScrollingCaptureCompleted = onScrollingCaptureCompleted
        self.onScrollingCaptureFailed = onScrollingCaptureFailed
        self.onConversationInboxSaved = onConversationInboxSaved
        self.onPerformanceMeasured = onPerformanceMeasured
        self.onCaptureFailed = onCaptureFailed
        self.onMagnifierHexCopied = onMagnifierHexCopied

        // Window enumeration can occasionally take several hundred milliseconds.
        // Warm it at utility priority so the first overlay can still snap instantly.
        prewarmRegionSnapRects()
        observeApplicationActivation()
    }

    deinit {
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                applicationActivationObserver
            )
        }
    }

    func beginRegionCapture() {
        beginRegionCapture(purpose: .screenshot)
    }

    func beginConversationInboxCapture() {
        beginRegionCapture(purpose: .conversationInbox)
    }

    func beginOCRCapture() {
        beginRegionCapture(purpose: .ocr)
    }

    func beginScrollingCapture() {
        beginRegionCapture(purpose: .scrollingCapture)
    }

    @discardableResult
    func showScrollingCaptureControlIfActive() -> Bool {
        guard scrollingCapture.isActive else { return false }
        scrollingCapture.showExisting()
        return true
    }

    private func beginRegionCapture(purpose: CapturePurpose) {
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = purpose
        let action: CaptureOverlayAction = switch purpose {
        case .recordingRegion: .recording
        case .scrollingCapture: .scrollingCapture
        case .conversationInbox: .conversationInbox
        case .ocr: .ocr
        default: .screenshot
        }
        showRegionOverlays(action: action, requestStartedAt: requestStartedAt)
    }

    func beginWindowCapture() {
        beginWindowSelection(purpose: .screenshot)
    }

    func beginMultiWindowCapture() {
        beginWindowSelection(purpose: .multiWindowScreenshot)
    }

    func beginRegionRecordingSelection(capturesCamera: Bool = false) {
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = .recordingRegion
        pendingRecordingCapturesCamera = capturesCamera
        showRegionOverlays(action: .recording, requestStartedAt: requestStartedAt)
    }

    func beginWindowRecordingSelection(capturesCamera: Bool = false) {
        pendingRecordingCapturesCamera = capturesCamera
        beginWindowSelection(purpose: .recordingWindow)
    }

    private func beginWindowSelection(purpose: CapturePurpose) {
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = purpose
        isPreparingCapture = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPreparingCapture = false }
            do {
                let targets = try await captureService.availableWindowTargets(
                    excludingProcessID: ProcessInfo.processInfo.processIdentifier,
                    excludingBundleIdentifier: Bundle.main.bundleIdentifier
                )
                windowTargets = Dictionary(
                    uniqueKeysWithValues: targets.map { ($0.candidate.id, $0) }
                )
                let candidates = targets.map(\.candidate)
                if purpose == .multiWindowScreenshot {
                    selectedWindowIDs.removeAll()
                    showOverlays(mode: .multiWindow(candidates: candidates))
                } else {
                    showOverlays(mode: .window(
                        candidates: candidates,
                        action: purpose == .recordingWindow ? .recording : .screenshot
                    ))
                }
            } catch {
                windowTargets.removeAll()
                pendingPurpose = .screenshot
                showError(error)
            }
        }
    }

    func exportPNGToConversationInbox(_ pngData: Data) throws {
        let snapshot = try ConversationInboxStore(
            directory: model.conversationInboxDirectory
        ).save(pngData: pngData)
        let copied = ConversationInboxPasteboard.copyPath(snapshot.latestURL)
        onConversationInboxSaved(snapshot, copied)
    }

    func beginDisplayCapture() {
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = .screenshot
        guard let screen = screenUnderPointer(), let displayID = screen.displayID else {
            showError(message: "没有找到可以捕获的显示器。")
            return
        }

        let displayBounds = CGDisplayBounds(displayID)
        let metadata = ScreenshotCaptureMetadata(
            mode: .display,
            displayID: displayID,
            globalBounds: displayBounds
        )
        finishCapture(purpose: .screenshot, captureSource: metadata) {
            try await self.captureService.capture(globalDisplayRect: displayBounds)
        }
    }

    private func showRegionOverlays(
        action: CaptureOverlayAction,
        requestStartedAt: TimeInterval
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let hasFreshSnapRects = Self.regionSnapRectCachePolicy.isUsable(
            cachedAt: cachedRegionSnapRectsAt,
            now: now
        )
        let initialSnapRects = hasFreshSnapRects ? cachedRegionSnapRects : []
        let generation = showOverlays(mode: .region(
            action: action,
            snapRects: initialSnapRects
        ))
        guard !overlayWindows.isEmpty else { return }

        onPerformanceMeasured(
            "capture.region_overlay_ready",
            [
                "count": String(overlayWindows.count),
                "durationMilliseconds": Self.performanceMilliseconds(since: requestStartedAt),
                "intent": action.diagnosticValue,
                "snapCacheHit": String(hasFreshSnapRects)
            ]
        )

        let processID = ProcessInfo.processInfo.processIdentifier
        let snapRectTask = Task.detached(priority: .utility) {
            ScreenCaptureService.loadRegionSnapRects(excludingProcessID: processID)
        }
        Task { @MainActor [weak self] in
            let snapRects = await snapRectTask.value
            guard let self else { return }
            cachedRegionSnapRects = snapRects
            cachedRegionSnapRectsAt = ProcessInfo.processInfo.systemUptime
            guard
                  overlayGeneration == generation,
                  !overlayWindows.isEmpty else { return }
            overlayWindows.forEach { window in
                (window.contentView as? CaptureOverlayView)?
                    .setRegionSnapRects(snapRects)
            }
            onPerformanceMeasured(
                "capture.region_snap_targets_ready",
                [
                    "count": String(snapRects.count),
                    "durationMilliseconds": Self.performanceMilliseconds(
                        since: requestStartedAt
                    ),
                    "intent": action.diagnosticValue
                ]
            )
        }
    }

    /// The window layout changes when the user switches applications, which is
    /// also the moment just before most captures start. Refreshing there keeps
    /// the cache warm without polling.
    private func observeApplicationActivation() {
        applicationActivationObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.prewarmRegionSnapRects()
                }
            }
    }

    private func prewarmRegionSnapRects() {
        guard Self.regionSnapRectCachePolicy.shouldRefresh(
            cachedAt: cachedRegionSnapRectsAt,
            now: ProcessInfo.processInfo.systemUptime,
            isRefreshing: isPrewarmingRegionSnapRects
        ) else { return }
        isPrewarmingRegionSnapRects = true
        let processID = ProcessInfo.processInfo.processIdentifier
        let task = Task.detached(priority: .utility) {
            ScreenCaptureService.loadRegionSnapRects(excludingProcessID: processID)
        }
        Task { @MainActor [weak self] in
            let snapRects = await task.value
            guard let self else { return }
            isPrewarmingRegionSnapRects = false
            cachedRegionSnapRects = snapRects
            cachedRegionSnapRectsAt = ProcessInfo.processInfo.systemUptime
        }
    }

    @discardableResult
    private func showOverlays(mode: CaptureOverlayMode) -> UInt64 {
        overlayGeneration &+= 1
        let generation = overlayGeneration
        overlayWindows = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return CaptureOverlayWindow(
                screen: screen,
                displayID: displayID,
                displayBounds: CGDisplayBounds(displayID),
                mode: mode,
                delegate: self
            )
        }
        guard !overlayWindows.isEmpty else {
            windowTargets.removeAll()
            showError(message: "没有找到可以捕获的显示器。")
            return generation
        }

        // Capture fires from a global hot key while another app owns the
        // keyboard: without activating, the overlay never receives keyDown
        // and Escape cannot cancel.
        NSApp.activate(ignoringOtherApps: true)
        // Deliberately no LensPanelPresenter here: the selection overlay must
        // appear on the exact frame the hot key was pressed, or the capture
        // itself starts to feel slow. This is the one glass surface that is
        // never allowed to fade or pop in.
        overlayWindows.forEach { $0.orderFrontRegardless() }
        if let pointerWindow = windowUnderPointer() ?? overlayWindows.first {
            pointerWindow.makeKeyAndOrderFront(nil)
            pointerWindow.makeFirstResponder(pointerWindow.contentView)
        }
        return generation
    }

    func captureOverlayDidCancel(_ view: CaptureOverlayView) {
        dismissOverlays()
        windowTargets.removeAll()
        selectedWindowIDs.removeAll()
        pendingPurpose = .screenshot
        pendingRecordingCapturesCamera = false
    }

    func captureOverlay(
        _ view: CaptureOverlayView,
        didSelect rect: CGRect,
        displayID: CGDirectDisplayID
    ) {
        let displayBounds = CGDisplayBounds(displayID)
        let globalRect = CaptureGeometry.globalRect(
            fromLocalRect: rect,
            displayBounds: displayBounds
        ).integral
        let purpose = pendingPurpose
        if case .recordingRegion = purpose {
            dismissOverlays()
            windowTargets.removeAll()
            pendingPurpose = .screenshot
            guard let source = CaptureGeometry.regionRecordingSource(
                displayID: displayID,
                localRect: rect,
                displayBounds: displayBounds
            ) else {
                showError(message: ScreenRecordingError.emptySelection.localizedDescription)
                return
            }
            let capturesCamera = pendingRecordingCapturesCamera
            pendingRecordingCapturesCamera = false
            onRecordingSourceSelected(source, capturesCamera)
            return
        }
        if case .scrollingCapture = purpose {
            dismissOverlays()
            windowTargets.removeAll()
            pendingPurpose = .screenshot
            startScrollingCapture(displayID: displayID, localRect: rect)
            return
        }
        let metadata = ScreenshotCaptureMetadata(
            mode: .region,
            displayID: displayID,
            globalBounds: globalRect,
            sourceRect: rect
        )
        finishCapture(purpose: purpose, captureSource: metadata) {
            try await self.captureService.capture(globalDisplayRect: globalRect)
        }
    }

    func captureOverlay(_ view: CaptureOverlayView, didSelectWindow windowID: CGWindowID) {
        guard let target = windowTargets[windowID] else {
            dismissOverlays()
            windowTargets.removeAll()
            showError(message: "所选窗口已经关闭，请重新选择。")
            return
        }
        if case .recordingWindow = pendingPurpose {
            dismissOverlays()
            windowTargets.removeAll()
            pendingPurpose = .screenshot
            let capturesCamera = pendingRecordingCapturesCamera
            pendingRecordingCapturesCamera = false
            onRecordingSourceSelected(
                CaptureGeometry.windowRecordingSource(target.candidate),
                capturesCamera
            )
            return
        }
        let metadata = ScreenshotCaptureMetadata(
            mode: .window,
            windowIDs: [target.candidate.id],
            globalBounds: target.candidate.globalFrame,
            windowTitle: target.candidate.title,
            applicationName: target.candidate.applicationName
        )
        finishCapture(purpose: .screenshot, captureSource: metadata) {
            try await self.captureService.capture(window: target.window)
        }
    }

    func captureOverlay(_ view: CaptureOverlayView, didToggleWindow windowID: CGWindowID) {
        guard pendingPurpose == .multiWindowScreenshot,
              windowTargets[windowID] != nil else { return }
        if !selectedWindowIDs.insert(windowID).inserted {
            selectedWindowIDs.remove(windowID)
        }
        overlayWindows.forEach { window in
            (window.contentView as? CaptureOverlayView)?
                .setSelectedWindowIDs(selectedWindowIDs)
        }
    }

    func captureOverlayDidConfirmWindows(_ view: CaptureOverlayView) {
        guard pendingPurpose == .multiWindowScreenshot else { return }
        let targets = selectedWindowIDs.compactMap { windowTargets[$0] }
        guard let layout = CaptureGeometry.multiWindowLayout(
            candidates: targets.map(\.candidate)
        ) else {
            showError(message: "请至少选择一个仍然可用的窗口。")
            return
        }
        let primary = targets.min(by: { $0.candidate.frontToBackOrder < $1.candidate.frontToBackOrder })
        let metadata = ScreenshotCaptureMetadata(
            mode: .multiWindow,
            windowIDs: targets.map { $0.candidate.id },
            globalBounds: layout.globalBounds,
            windowTitle: primary?.candidate.title,
            applicationName: primary?.candidate.applicationName
        )
        finishCapture(
            purpose: .multiWindowScreenshot,
            titlePrefix: "多窗口截图",
            captureSource: metadata
        ) {
            try await self.captureService.capture(windows: targets)
        }
    }

    func captureOverlay(
        _ view: CaptureOverlayView,
        didMeasureRegionDrag performance: CaptureOverlayDragPerformance
    ) {
        onPerformanceMeasured(
            "capture.region_drag_performance",
            [
                "averageMilliseconds": Self.formattedMilliseconds(
                    performance.averageUpdateMilliseconds
                ),
                "count": String(performance.eventCount),
                "maximumMilliseconds": Self.formattedMilliseconds(
                    performance.maximumUpdateMilliseconds
                ),
                "totalMilliseconds": Self.formattedMilliseconds(
                    performance.totalUpdateMilliseconds
                )
            ]
        )
    }

    /// Runs on the magnifier's own throttled loop, never from the drag hot
    /// path — a slow or failed sample only ever affects the magnifier's own
    /// freshness, never the measured drag-update performance.
    func captureOverlay(
        _ view: CaptureOverlayView,
        didRequestMagnifierSample globalRect: CGRect
    ) async -> CGImage? {
        try? await captureService.capture(globalDisplayRect: globalRect)
    }

    func captureOverlay(_ view: CaptureOverlayView, didCopyMagnifierHex hex: String) {
        onMagnifierHexCopied(hex)
    }

    private static func performanceMilliseconds(since startedAt: TimeInterval) -> String {
        formattedMilliseconds(
            max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        )
    }

    private static func formattedMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func finishCapture(
        purpose: CapturePurpose,
        titlePrefix: String = "截图",
        captureSource: ScreenshotCaptureMetadata? = nil,
        operation: @escaping @MainActor () async throws -> CGImage
    ) {
        switch purpose {
        case .screenshot, .conversationInbox, .multiWindowScreenshot, .ocr:
            break
        case .scrollingCapture, .recordingRegion, .recordingWindow:
            return
        }
        guard !isFinishingCapture else { return }
        isFinishingCapture = true
        dismissOverlays()
        windowTargets.removeAll()
        selectedWindowIDs.removeAll()
        pendingPurpose = .screenshot

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFinishingCapture = false }
            do {
                // Allow the action center or selection overlay to leave the compositor first.
                try await Task.sleep(for: .milliseconds(90))
                let cgImage = try await operation()
                if purpose == .conversationInbox {
                    try deliverConversationInbox(cgImage)
                    return
                }
                let (saved, image) = try saveCapturedImage(
                    cgImage,
                    titlePrefix: titlePrefix,
                    captureSource: captureSource
                )
                model.setRecentLens(saved, thumbnail: image)
                onLensChanged()
                switch purpose {
                case .screenshot, .multiWindowScreenshot:
                    let copied = copyImageToClipboard(image)
                    quickAccess.show(
                        lens: saved,
                        image: image,
                        confirmationTitle: copied
                            ? "截图已复制"
                            : "截图已保存，复制未完成"
                    )
                    scheduleAutomaticOCR(
                        cgImage: cgImage,
                        saved: saved,
                        thumbnail: image
                    )
                case .ocr:
                    onOCRStarted(saved, image)
                    await processOCR(
                        cgImage: cgImage,
                        saved: saved,
                        thumbnail: image,
                        delivery: .interactive
                    )
                case .conversationInbox, .scrollingCapture, .recordingRegion, .recordingWindow:
                    break
                }
            } catch {
                showError(error)
            }
        }
    }

    private func startScrollingCapture(
        displayID: CGDirectDisplayID,
        localRect: CGRect
    ) {
        let sourceRect = localRect.standardized.integral
        isPreparingCapture = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingCapture = false }
            do {
                let target = try await captureService.prepareScrollingRegion(
                    displayID: displayID,
                    localDisplayRect: sourceRect,
                    excludingProcessID: ProcessInfo.processInfo.processIdentifier
                )
                let capturedDisplayID = target.displayID
                let capturedSourceRect = target.sourceRect
                scrollingCapture.onCompleted = { [weak self] assembly, captureWarning in
                    self?.completeScrollingCapture(
                        assembly,
                        displayID: capturedDisplayID,
                        sourceRect: capturedSourceRect,
                        captureWarning: captureWarning
                    )
                }
                scrollingCapture.onFailed = { [weak self] error in
                    self?.onScrollingCaptureFailed(error)
                }
                scrollingCapture.begin { [captureService] in
                    try await captureService.captureScrollingRegion(target)
                }
            } catch {
                onScrollingCaptureFailed(error)
            }
        }
    }

    private func completeScrollingCapture(
        _ assembly: ScrollingCaptureAssembly,
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        captureWarning: Error?
    ) {
        do {
            let (saved, image) = try saveCapturedImage(
                assembly.image,
                titlePrefix: "长截图"
            )
            let plan = assembly.plan(displayID: displayID, sourceRect: sourceRect)
            var completed = saved
            var archiveWarning: Error?
            do {
                completed = try store.attachScrollingCapture(
                    plan,
                    framePNGs: assembly.framePNGs,
                    to: saved
                )
            } catch {
                // The assembled PNG is already safe and immediately usable.
                archiveWarning = error
            }
            model.setRecentLens(completed, thumbnail: image)
            onLensChanged()
            let copied = copyImageToClipboard(image)
            quickAccess.show(
                lens: completed,
                image: image,
                confirmationTitle: copied
                    ? "长截图已复制"
                    : "长截图已保存，复制未完成"
            )
            scheduleAutomaticOCR(
                cgImage: assembly.image,
                saved: completed,
                thumbnail: image
            )
            onScrollingCaptureCompleted(
                assembly.frames.count,
                assembly.image.height,
                captureWarning ?? archiveWarning
            )
        } catch {
            onScrollingCaptureFailed(error)
        }
    }

    private func deliverConversationInbox(_ cgImage: CGImage) throws {
        try exportPNGToConversationInbox(try ImageEncoding.pngData(from: cgImage))
    }

    private func saveCapturedImage(
        _ cgImage: CGImage,
        titlePrefix: String = "截图",
        captureSource: ScreenshotCaptureMetadata? = nil
    ) throws -> (SavedLens, NSImage) {
        let pngData = try ImageEncoding.pngData(from: cgImage)
        let saved = try store.saveScreenshot(
            pngData: pngData,
            width: cgImage.width,
            height: cgImage.height,
            titlePrefix: titlePrefix,
            captureSource: captureSource
        )
        let image = ImageEncoding.nsImage(from: cgImage)
        return (saved, image)
    }

    private func processOCR(
        cgImage: CGImage,
        saved: SavedLens,
        thumbnail: NSImage,
        delivery: OCRDelivery
    ) async {
        do {
            let document = try await ocrService.recognizeText(in: cgImage)
            let updated = try store.attachOCR(document, to: saved)
            model.setRecentLens(updated, thumbnail: thumbnail)
            onLensChanged()
            switch delivery {
            case .interactive:
                onOCRCompleted(document, updated)
            case .automatic:
                onAutomaticOCRCompleted(document, updated)
            }
        } catch {
            // OCR is analysis: its failure must never discard the screenshot captured above.
            if delivery == .interactive {
                onOCRFailed(error, saved)
            }
        }
    }

    private func scheduleAutomaticOCR(
        cgImage: CGImage,
        saved: SavedLens,
        thumbnail: NSImage
    ) {
        Task { @MainActor [weak self] in
            await self?.processOCR(
                cgImage: cgImage,
                saved: saved,
                thumbnail: thumbnail,
                delivery: .automatic
            )
        }
    }

    private func canBeginCapture() -> Bool {
        overlayWindows.isEmpty
            && !isPreparingCapture
            && !isFinishingCapture
            && !scrollingCapture.isActive
    }

    private func ensurePermission() -> Bool {
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return false
        }
        return true
    }

    private func dismissOverlays() {
        overlayGeneration &+= 1
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        // Captures tend to arrive in bursts, and this one may have changed the
        // window layout itself. Refresh so the next overlay starts warm.
        prewarmRegionSnapRects()
    }

    @discardableResult
    private func copyImageToClipboard(_ image: NSImage) -> Bool {
        ImageClipboardWriter.write(image)
    }

    private func windowUnderPointer() -> CaptureOverlayWindow? {
        let location = NSEvent.mouseLocation
        return overlayWindows.first { $0.frame.contains(location) }
    }

    private func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func showError(message: String) {
        // Capture failures happen while the user is mid-flow on other apps; a
        // modal alert (plus the activation it requires) interrupts exactly the
        // work they were doing, so surface the failure through the toast
        // channel instead.
        onCaptureFailed(message)
    }

    private func showError(_ error: Error) {
        showError(message: StorageRecoveryGuidance.detail(for: error))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
