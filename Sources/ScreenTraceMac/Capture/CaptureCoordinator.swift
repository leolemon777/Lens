import AppKit
import CoreGraphics
import ScreenTraceCore

@MainActor
final class CaptureCoordinator: CaptureOverlayViewDelegate {
    private enum CapturePurpose {
        case screenshot
        case ocr
    }

    private let store: TraceProjectStore
    private let model: AppModel
    private let quickAccess: QuickAccessWindowController
    private let onTraceChanged: () -> Void
    private let onOCRCompleted: (OCRDocument, SavedTrace) -> Void
    private let onOCRFailed: (Error, SavedTrace) -> Void
    private let captureService = ScreenCaptureService()
    private let ocrService = VisionOCRService()
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var windowTargets: [CGWindowID: WindowCaptureTarget] = [:]
    private var pendingPurpose: CapturePurpose = .screenshot
    private var isPreparingCapture = false
    private var isFinishingCapture = false

    init(
        store: TraceProjectStore,
        model: AppModel,
        quickAccess: QuickAccessWindowController,
        onTraceChanged: @escaping () -> Void,
        onOCRCompleted: @escaping (OCRDocument, SavedTrace) -> Void,
        onOCRFailed: @escaping (Error, SavedTrace) -> Void
    ) {
        self.store = store
        self.model = model
        self.quickAccess = quickAccess
        self.onTraceChanged = onTraceChanged
        self.onOCRCompleted = onOCRCompleted
        self.onOCRFailed = onOCRFailed
    }

    func beginRegionCapture() {
        beginRegionCapture(purpose: .screenshot)
    }

    func beginOCRCapture() {
        beginRegionCapture(purpose: .ocr)
    }

    private func beginRegionCapture(purpose: CapturePurpose) {
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = purpose
        showOverlays(mode: .region)
    }

    func beginWindowCapture() {
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = .screenshot
        isPreparingCapture = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPreparingCapture = false }
            do {
                let targets = try await captureService.availableWindowTargets(
                    excludingProcessID: ProcessInfo.processInfo.processIdentifier
                )
                windowTargets = Dictionary(
                    uniqueKeysWithValues: targets.map { ($0.candidate.id, $0) }
                )
                showOverlays(mode: .window(candidates: targets.map(\.candidate)))
            } catch {
                windowTargets.removeAll()
                showError(message: error.localizedDescription)
            }
        }
    }

    func beginDisplayCapture() {
        guard canBeginCapture(), ensurePermission() else { return }
        pendingPurpose = .screenshot
        guard let screen = screenUnderPointer(), let displayID = screen.displayID else {
            showError(message: "没有找到可以捕获的显示器。")
            return
        }

        let displayBounds = CGDisplayBounds(displayID)
        finishCapture(purpose: .screenshot) {
            try await self.captureService.capture(globalDisplayRect: displayBounds)
        }
    }

    private func showOverlays(mode: CaptureOverlayMode) {
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
            return
        }

        overlayWindows.forEach { $0.orderFrontRegardless() }
        if let pointerWindow = windowUnderPointer() ?? overlayWindows.first {
            pointerWindow.makeKey()
            pointerWindow.makeFirstResponder(pointerWindow.contentView)
        }
    }

    func captureOverlayDidCancel(_ view: CaptureOverlayView) {
        dismissOverlays()
        windowTargets.removeAll()
        pendingPurpose = .screenshot
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
        finishCapture(purpose: purpose) {
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
        finishCapture(purpose: .screenshot) {
            try await self.captureService.capture(window: target.window)
        }
    }

    private func finishCapture(
        purpose: CapturePurpose,
        operation: @escaping @MainActor () async throws -> CGImage
    ) {
        guard !isFinishingCapture else { return }
        isFinishingCapture = true
        dismissOverlays()
        windowTargets.removeAll()
        pendingPurpose = .screenshot

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFinishingCapture = false }
            do {
                // Allow the action center or selection overlay to leave the compositor first.
                try await Task.sleep(for: .milliseconds(90))
                let cgImage = try await operation()
                let (saved, image) = try saveCapturedImage(cgImage)
                model.setRecentTrace(saved, thumbnail: image)
                onTraceChanged()
                switch purpose {
                case .screenshot:
                    copyImageToClipboard(image)
                    quickAccess.show(trace: saved, image: image)
                case .ocr:
                    await processOCR(cgImage: cgImage, saved: saved, thumbnail: image)
                }
            } catch {
                showError(message: error.localizedDescription)
            }
        }
    }

    private func saveCapturedImage(_ cgImage: CGImage) throws -> (SavedTrace, NSImage) {
        let pngData = try ImageEncoding.pngData(from: cgImage)
        let saved = try store.saveScreenshot(
            pngData: pngData,
            width: cgImage.width,
            height: cgImage.height
        )
        let image = ImageEncoding.nsImage(from: cgImage)
        return (saved, image)
    }

    private func processOCR(
        cgImage: CGImage,
        saved: SavedTrace,
        thumbnail: NSImage
    ) async {
        do {
            let document = try await ocrService.recognizeText(in: cgImage)
            let updated = try store.attachOCR(document, to: saved)
            model.setRecentTrace(updated, thumbnail: thumbnail)
            onTraceChanged()
            let text = document.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                copyTextToClipboard(text)
            }
            onOCRCompleted(document, updated)
        } catch {
            // OCR is analysis: its failure must never discard the screenshot captured above.
            onOCRFailed(error, saved)
        }
    }

    private func canBeginCapture() -> Bool {
        overlayWindows.isEmpty && !isPreparingCapture && !isFinishingCapture
    }

    private func ensurePermission() -> Bool {
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return false
        }
        return true
    }

    private func dismissOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    private func copyImageToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏迹无法完成截图"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
